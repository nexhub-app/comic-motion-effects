/// 入场转场帧序列导出（第四轮 V2）。
///
/// 对齐鸿蒙阅读「章节打开景深入场」：从模糊原图浮现到清晰原图的一次性
/// 序列——**播完停在末帧（清晰图），随后衔接正常循环动图**。首尾不无缝
/// 是设计使然，不属于循环动效（索引 JSON 明确 `loop: false,
/// holdOnLast: true`）。
///
/// 实现要点：
/// - 模糊为纯 Dart 可分离 box blur（多轮滑动窗口均值近似高斯，整数累加
///   确定性），作用于**分层前的原图**（入场是整页效果，不做分层位移）；
/// - 可选轻微缩放浮现（默认 1.02 → 1.0，中心锚定，双线性采样）；
/// - 不透明帧（对外 PNG 一律 RGB，v1.2 起的输出契约；alpha 渐入列入
///   roadmap，见 doc/roadmap.md）；
/// - 末帧短路：radius=0 且 zoom=1.0 时直接输出工作分辨率原图，保证
///   「末帧 = 清晰原图」逐字节成立。
///
/// 与 V1 交互帧集共享输出形态（帧 + 索引 JSON，`kind: entrance`）与落盘
/// 契约（`<stem>_<contentHash8>_<configHash8>_entrance/`，MotionCacheManager
/// 识别并可清理）。取消 / 超时 / keepPartial 兼容；串行渲染、无随机、
/// 无时钟输入，同输入同 config 逐字节复现。
library;

import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'cancellation.dart';
import 'effect_config.dart';
import 'image_io.dart';
import 'image_model.dart';
import 'pipeline.dart';

/// [MotionPipeline.exportEntranceFrames] / [exportEntranceFramesFile] 的结果。
class EntranceExportResult {
  const EntranceExportResult({
    required this.width,
    required this.height,
    required this.configHash,
    required this.contentHash,
    required this.frames,
    required this.delayMs,
    required this.indexJsonBytes,
    required this.elapsedMs,
    this.outputDir = '',
  });

  /// 工作分辨率（与全量渲染同源）。
  final int width;
  final int height;
  final String configHash;

  /// 输入内容指纹（`ImageIO.contentHash8` 口径，与产物目录命名一致）。
  final String contentHash;

  /// 帧序列 PNG 字节：下标 0 = 首帧（最模糊），末帧 = 清晰原图。
  final List<Uint8List> frames;

  /// 建议帧间隔（毫秒），写进索引 JSON，嵌入方按此播放。
  final int delayMs;

  /// 索引 JSON 字节（`kind: entrance`；磁盘模式与 `<...>/index.json`
  /// 同字节）。不含执行期信息，确定性输出。
  final Uint8List indexJsonBytes;

  final int elapsedMs;

  /// 磁盘模式的产物目录；内存模式为空串。
  final String outputDir;
}

extension EntranceExport on MotionPipeline {
  /// 入场转场帧序列导出（内存模式）：输入字节进、模糊→清晰的插值帧序列
  /// + 索引 JSON 出，不触碰文件系统。语义详见 `entrance.dart` 库注释。
  ///
  /// [frames] ≥ 2（默认 12）；[maxBlurRadiusPx] 为首帧 box blur 半径
  /// （多轮近似高斯），null 时按工作分辨率自动取 2%（钳制 [2, 24]）；
  /// [zoomReveal] 开启轻微缩放浮现（[zoomFrom] → 1.0，默认 1.02，须 ≥ 1）；
  /// [delayMs] 为建议帧间隔（默认 80，仅写进索引 JSON）。
  Future<EntranceExportResult> exportEntranceFrames({
    required Uint8List input,
    int frames = 12,
    int? maxBlurRadiusPx,
    bool zoomReveal = true,
    double zoomFrom = 1.02,
    int delayMs = 80,
    int? maxPixels,
  }) {
    final src =
        ImageIO.decode(input, maxPixels: maxPixels ?? ImageIO.defaultMaxPixels);
    return _runEntranceExport(
      this,
      src,
      contentHash: ImageIO.contentHash8(input),
      frames: frames,
      maxBlurRadiusPx: maxBlurRadiusPx,
      zoomReveal: zoomReveal,
      zoomFrom: zoomFrom,
      delayMs: delayMs,
      inputStem: 'image',
      outputDir: null,
    );
  }

  /// [exportEntranceFrames] 的文件入口：产出落盘到
  /// `<outputDir>/<stem>_<contentHash8>_<configHash8>_entrance/`
  /// （frame_NNNN.png + index.json），同时返回内存帧序列与索引字节。
  Future<EntranceExportResult> exportEntranceFramesFile(
    String inputPath,
    String outputDir, {
    int frames = 12,
    int? maxBlurRadiusPx,
    bool zoomReveal = true,
    double zoomFrom = 1.02,
    int delayMs = 80,
  }) {
    final bytes = ImageIO.readFileBytes(inputPath);
    final src = ImageIO.decode(bytes);
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    return _runEntranceExport(
      this,
      src,
      contentHash: ImageIO.contentHash8(bytes),
      frames: frames,
      maxBlurRadiusPx: maxBlurRadiusPx,
      zoomReveal: zoomReveal,
      zoomFrom: zoomFrom,
      delayMs: delayMs,
      inputStem: baseName,
      outputDir: outputDir,
    );
  }
}

/// 导出主干：与 pipeline / 交互帧集同构的取消/超时包装 + 串行渲染循环。
Future<EntranceExportResult> _runEntranceExport(
  MotionPipeline pipeline,
  RgbaImage src, {
  required String contentHash,
  required int frames,
  required int? maxBlurRadiusPx,
  required bool zoomReveal,
  required double zoomFrom,
  required int delayMs,
  required String inputStem,
  required String? outputDir,
}) async {
  final sw = Stopwatch()..start();
  final cfg = pipeline.config;
  if (frames < 2) {
    throw ArgumentError('frames must be >= 2 (blurry first + sharp last), '
        'got $frames');
  }
  if (zoomFrom < 1.0) {
    throw ArgumentError('zoomFrom must be >= 1.0, got $zoomFrom');
  }
  if (delayMs < 1) {
    throw ArgumentError('delayMs must be >= 1, got $delayMs');
  }
  final jobDir = outputDir == null
      ? null
      : '$outputDir/'
          '${inputStem}_${contentHash}_${cfg.configHash.substring(0, 8)}'
          '_entrance';
  // 超时 deadline 自导出主干（解码之后）起算，与 pipeline 同风格。
  final deadline = pipeline.timeout == null ? null : (Stopwatch()..start());
  try {
    // 派发前检查：已取消则零渲染、零文件。
    _checkEntranceCancel(pipeline, deadline, 'entry');

    // 入场是整页效果：只做降采样，不做深度估算 / 分层。
    final working = pipeline.downscaleForExport(src);
    final radius = maxBlurRadiusPx ??
        (math.max(working.width, working.height) * 0.02)
            .round()
            .clamp(2, 24)
            .toInt();
    final zoom = zoomReveal ? zoomFrom : 1.0;

    if (jobDir != null) io.Directory(jobDir).createSync(recursive: true);

    final outFrames = <Uint8List>[];
    for (var i = 0; i < frames; i++) {
      _checkEntranceCancel(pipeline, deadline, 'before frame render');
      final u = frames > 1 ? i / (frames - 1) : 1.0;
      // ease-out：起手模糊最强，随推进平滑清晰化。
      final r = (radius * (1.0 - u) * (1.0 - u)).round();
      final s = zoom - (zoom - 1.0) * u;
      final frame = _entranceFrame(working, r, s);
      final pngBytes = Uint8List.fromList(ImageIO.encodePngFrame(frame));
      if (jobDir != null) {
        io.File(ImageIO.pngPathFor(jobDir, i)).writeAsBytesSync(pngBytes);
      }
      outFrames.add(pngBytes);
      _checkEntranceCancel(pipeline, deadline, 'after frame render');
    }

    // 索引 JSON：嵌入方加载即用；不含执行期信息（确定性输出）。
    final index = <String, dynamic>{
      'kind': 'entrance',
      'version': 1,
      'width': working.width,
      'height': working.height,
      'configHash': cfg.configHash,
      'contentHash': contentHash,
      // 播放语义：一次性序列，播完停在末帧（清晰图），随后衔接正常循环动图。
      'loop': false,
      'holdOnLast': true,
      'delayMs': delayMs,
      'zoomReveal': zoomReveal,
      'zoomFrom': zoom,
      'maxBlurRadiusPx': radius,
      'frames': [
        for (var i = 0; i < outFrames.length; i++)
          'frame_${i.toString().padLeft(4, '0')}.png',
      ],
    };
    final indexJsonBytes =
        Uint8List.fromList(convert.utf8.encode(convert.jsonEncode(index)));
    if (jobDir != null) {
      io.File('$jobDir/index.json').writeAsBytesSync(indexJsonBytes);
    }

    sw.stop();
    return EntranceExportResult(
      width: working.width,
      height: working.height,
      configHash: cfg.configHash,
      contentHash: contentHash,
      frames: List<Uint8List>.unmodifiable(outFrames),
      delayMs: delayMs,
      indexJsonBytes: indexJsonBytes,
      elapsedMs: sw.elapsedMilliseconds,
      outputDir: jobDir ?? '',
    );
  } on MotionCancelledException {
    if (jobDir != null && !pipeline.keepPartial) {
      _cleanupEntranceDir(jobDir);
    }
    rethrow;
  }
}

/// 渲染第 u 帧：radius=0 且 zoom=1 时短路输出原图（末帧 = 清晰原图的
/// 逐字节保证）；否则先缩放浮现再叠 box blur。
RgbaImage _entranceFrame(RgbaImage working, int radius, double zoom) {
  if (radius <= 0 && zoom == 1.0) {
    return working.clone();
  }
  final scaled = zoom == 1.0 ? working : _zoomCenter(working, zoom);
  return radius <= 0 ? scaled : _boxBlur(scaled, radius, 3);
}

/// 中心锚定的轻微缩放（zoom ≥ 1，双线性采样；zoom=1 时调用方已短路）。
RgbaImage _zoomCenter(RgbaImage src, double zoom) {
  final w = src.width, h = src.height;
  final out = RgbaImage(width: w, height: h);
  final cx = w / 2.0, cy = h / 2.0;
  final tmp = List<int>.filled(4, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final sx = (x + 0.5 - cx) / zoom + cx - 0.5;
      final sy = (y + 0.5 - cy) / zoom + cy - 0.5;
      src.sampleBilinear(sx, sy, tmp);
      out.setPixel(x, y, tmp[0], tmp[1], tmp[2], tmp[3]);
    }
  }
  return out;
}

/// 可分离 box blur：[passes] 轮（水平 + 垂直各一次）滑动窗口均值近似
/// 高斯。整数累加 + 有界取整，无随机、无浮点漂移，逐字节确定性。
RgbaImage _boxBlur(RgbaImage src, int radius, int passes) {
  var cur = src;
  for (var p = 0; p < passes; p++) {
    cur = _boxBlurAxis(_boxBlurAxis(cur, radius, horizontal: true), radius,
        horizontal: false);
  }
  return cur;
}

RgbaImage _boxBlurAxis(RgbaImage src, int radius, {required bool horizontal}) {
  final w = src.width, h = src.height;
  final out = RgbaImage(width: w, height: h);
  final d = src.data, o = out.data;
  final count = 2 * radius + 1;
  final half = radius; // (count - 1) / 2，四舍五入偏置
  if (horizontal) {
    for (var y = 0; y < h; y++) {
      final row = y * w;
      // 滑动窗口和（RGB 三通道独立；alpha 恒 255 不处理）。
      var sr = 0, sg = 0, sb = 0;
      for (var k = -radius; k <= radius; k++) {
        final x = k.clamp(0, w - 1);
        final p = (row + x) * 4;
        sr += d[p];
        sg += d[p + 1];
        sb += d[p + 2];
      }
      for (var x = 0; x < w; x++) {
        final p = (row + x) * 4;
        o[p] = (sr + half) ~/ count;
        o[p + 1] = (sg + half) ~/ count;
        o[p + 2] = (sb + half) ~/ count;
        o[p + 3] = 255;
        // 窗口右移一格：加入 x+radius+1，移出 x-radius（越界钳制）。
        final xIn = (x + radius + 1).clamp(0, w - 1);
        final xOut = (x - radius).clamp(0, w - 1);
        final pIn = (row + xIn) * 4;
        final pOut = (row + xOut) * 4;
        sr += d[pIn] - d[pOut];
        sg += d[pIn + 1] - d[pOut + 1];
        sb += d[pIn + 2] - d[pOut + 2];
      }
    }
  } else {
    for (var x = 0; x < w; x++) {
      var sr = 0, sg = 0, sb = 0;
      for (var k = -radius; k <= radius; k++) {
        final y = k.clamp(0, h - 1);
        final p = (y * w + x) * 4;
        sr += d[p];
        sg += d[p + 1];
        sb += d[p + 2];
      }
      for (var y = 0; y < h; y++) {
        final p = (y * w + x) * 4;
        o[p] = (sr + half) ~/ count;
        o[p + 1] = (sg + half) ~/ count;
        o[p + 2] = (sb + half) ~/ count;
        o[p + 3] = 255;
        final yIn = (y + radius + 1).clamp(0, h - 1);
        final yOut = (y - radius).clamp(0, h - 1);
        final pIn = (yIn * w + x) * 4;
        final pOut = (yOut * w + x) * 4;
        sr += d[pIn] - d[pOut];
        sg += d[pIn + 1] - d[pOut + 1];
        sb += d[pIn + 2] - d[pOut + 2];
      }
    }
  }
  return out;
}

/// 导出入口的取消/超时检查：语义与静帧一致（code `E_CANCELLED` /
/// `E_TIMEOUT`），检查点为导出入口与每帧渲染前后。
void _checkEntranceCancel(
    MotionPipeline pipeline, Stopwatch? deadline, String stage) {
  final timeout = pipeline.timeout;
  if (deadline != null && timeout != null && deadline.elapsed > timeout) {
    throw MotionCancelledException(
        'render timed out after ${timeout.inMilliseconds}ms ($stage)',
        code: 'E_TIMEOUT');
  }
  final token = pipeline.cancelToken;
  if (token != null && token.isCancelled) {
    throw MotionCancelledException('cancelled by caller', code: 'E_CANCELLED');
  }
}

/// 取消/超时的默认清理：删除本次写出的帧 PNG / index.json；目录仅在变空
/// 时移除（与 pipeline 清理同语义）。
void _cleanupEntranceDir(String jobDir) {
  void silentDeleteFile(String p) {
    try {
      final f = io.File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  silentDeleteFile('$jobDir/index.json');
  try {
    final d = io.Directory(jobDir);
    if (d.existsSync()) {
      for (final e in d.listSync()) {
        if (e is io.File) e.deleteSync();
      }
      d.deleteSync(); // 非空则失败，忽略
    }
  } catch (_) {}
}
