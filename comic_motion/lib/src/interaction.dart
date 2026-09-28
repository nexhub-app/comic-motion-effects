/// 交互式视差帧集导出（第四轮 V1）。
///
/// 为什么需要：鸿蒙阅读「跟手视差」= 设备倾斜 / 手指偏移 → 分层实时偏移，
/// GIF 循环表达不了这种**由外部输入驱动**的位移。折中路径：预渲染 N 个
/// 视差相位的帧集，嵌入方按陀螺仪 / 触摸偏移量在 [-1, 1] 上选帧。
///
/// 语义契约：
/// - 视差层位移不再由时间相位驱动，而由归一化偏移 `phase ∈ [-1, 1]` 直接
///   指定（`dx = amplitude · phase · w · 层倍率`，垂直轴经 `verticalRatio`
///   缩放，与时间路径同一耦合系数）；
/// - 其余效果（粒子 / 呼吸 / 扫光……）全部冻结在 t=0 参考相位——交互帧
///   以 `renderFrame(0)` 语义渲染，帧与帧之间只有视差位移不同；
/// - `phase = 0` 的帧与「去掉 parallax 效果」的同一 config 在 t=0 的静帧
///   逐字节一致（测试锁定，见 test/interaction_test.dart）。
///
/// 输出形态（V4 伴生包与外部嵌入方消费）：
/// - 内存帧集 `List<InteractionFrameSet>`（每轴一组，phase 升序，含 PNG 字节）；
/// - 索引 JSON（`kind: interactive`）：phases / axis / 宽高 / configHash /
///   contentHash——嵌入方加载索引即可建帧查找表；
/// - 可选落盘目录 `<stem>_<contentHash8>_<configHash8>_interactive/`，
///   复用 [MotionCacheManager] 目录契约（其 `kind` 字段标为 `interactive`，
///   可被 purgeLRU / purgePrefix / purgeAll 正常清理）。
///
/// 与取消 / 超时 / keepPartial 体系（第二轮）兼容：检查点在导出入口与每帧
/// 渲染前后，粒度为帧边界；取消或超时默认清理本次写出的半成品目录并抛
/// [MotionCancelledException]（code `E_CANCELLED` / `E_TIMEOUT`）。
///
/// 确定性：渲染串行、无随机、无时钟输入——同输入 + 同 config 的帧集与
/// 索引 JSON 逐字节一致（执行期信息如 elapsedMs 不写入索引）。
library;

import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:typed_data';

import 'cancellation.dart';
import 'frame_compositor.dart';
import 'image_io.dart';
import 'image_model.dart';
import 'pipeline.dart';

/// 视差采样轴。
enum InteractionAxis { horizontal, vertical, both }

/// 一帧交互帧：归一化偏移 + PNG 字节。
class InteractionFrame {
  const InteractionFrame({
    required this.phaseX,
    required this.phaseY,
    required this.pngBytes,
  });

  /// 水平归一化偏移（[-1, 1]）。一维轴集合中非活跃轴恒为 0。
  final double phaseX;

  /// 垂直归一化偏移（[-1, 1]）。一维轴集合中非活跃轴恒为 0。
  final double phaseY;

  /// 该帧的 PNG 字节（与落盘 `frame_NNNN.png` 同源同编码）。
  final Uint8List pngBytes;
}

/// 单轴帧集：phase 升序的一维采样，帧序与 [phases] 一一对应。
class InteractionFrameSet {
  const InteractionFrameSet({
    required this.axis,
    required this.phases,
    required this.pngBytes,
  });

  /// 该集的活跃轴（horizontal 或 vertical；both 拆成两组各自成集）。
  final InteractionAxis axis;

  /// 归一化相位，升序，覆盖 [-1, 1]（含两端点）。
  final List<double> phases;

  /// 与 [phases] 平行的 PNG 帧字节列表。
  final List<Uint8List> pngBytes;

  /// phase → 帧下标（四舍五入到最近采样点）；越界钳制到端点。
  int indexForPhase(double phase) {
    final p = phase.clamp(-1.0, 1.0).toDouble();
    if (phases.length < 2) return 0;
    final step = 2.0 / (phases.length - 1);
    return ((p - phases.first) / step).round().clamp(0, phases.length - 1);
  }
}

/// [MotionPipeline.exportInteractionFrames] / [exportInteractionFramesFile]
/// 的结果。
class InteractionExportResult {
  const InteractionExportResult({
    required this.width,
    required this.height,
    required this.configHash,
    required this.contentHash,
    required this.sets,
    required this.indexJsonBytes,
    required this.elapsedMs,
    this.outputDir = '',
    this.warnings = const [],
  });

  /// 工作分辨率（与全量渲染同源）。
  final int width;
  final int height;
  final String configHash;

  /// 输入内容指纹（`ImageIO.contentHash8` 口径，与产物目录命名一致）。
  final String contentHash;

  /// 帧集列表：单轴 1 组，both 时 2 组（水平在前）。
  final List<InteractionFrameSet> sets;

  /// 索引 JSON 字节（`kind: interactive`；磁盘模式与 `<...>/index.json`
  /// 同字节）。不含执行期信息，确定性输出。
  final Uint8List indexJsonBytes;

  final int elapsedMs;

  /// 磁盘模式的产物目录；内存模式为空串。
  final String outputDir;

  /// 导出层告警（如 reducedMotion 下帧集退化为静帧）。
  final List<String> warnings;
}

extension InteractionExport on MotionPipeline {
  /// 交互式视差帧集导出（内存模式）：输入字节进、帧集 + 索引 JSON 出，
  /// 不触碰文件系统。语义详见 `interaction.dart` 库注释。
  ///
  /// [axis] 为 [InteractionAxis.both] 时输出两组一维帧集（水平、垂直各
  /// [steps] 帧，按一维消费；不做 steps² 网格——内存可控性优先）。
  /// [steps] ≥ 2，默认 16，均匀覆盖 [-1, 1] 含两端点。
  Future<InteractionExportResult> exportInteractionFrames({
    required Uint8List input,
    InteractionAxis axis = InteractionAxis.horizontal,
    int steps = 16,
    int? maxPixels,
  }) {
    final src =
        ImageIO.decode(input, maxPixels: maxPixels ?? ImageIO.defaultMaxPixels);
    return _runInteractionExport(
      this,
      src,
      contentHash: ImageIO.contentHash8(input),
      axis: axis,
      steps: steps,
      inputStem: 'image',
      outputDir: null,
    );
  }

  /// [exportInteractionFrames] 的文件入口：产出落盘到
  /// `<outputDir>/<stem>_<contentHash8>_<configHash8>_interactive/`
  /// （frame_NNNN.png + index.json），同时返回内存帧集与索引字节。
  Future<InteractionExportResult> exportInteractionFramesFile(
    String inputPath,
    String outputDir, {
    InteractionAxis axis = InteractionAxis.horizontal,
    int steps = 16,
  }) {
    final bytes = ImageIO.readFileBytes(inputPath);
    final src = ImageIO.decode(bytes);
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    return _runInteractionExport(
      this,
      src,
      contentHash: ImageIO.contentHash8(bytes),
      axis: axis,
      steps: steps,
      inputStem: baseName,
      outputDir: outputDir,
    );
  }
}

/// 导出主干：与 pipeline 渲染主干同构的取消/超时包装 + 串行渲染循环。
Future<InteractionExportResult> _runInteractionExport(
  MotionPipeline pipeline,
  RgbaImage src, {
  required String contentHash,
  required InteractionAxis axis,
  required int steps,
  required String inputStem,
  required String? outputDir,
}) async {
  final sw = Stopwatch()..start();
  final cfg = pipeline.config;
  if (steps < 2) {
    throw ArgumentError('steps must be >= 2 (covering -1 and 1), got $steps');
  }
  final jobDir = outputDir == null
      ? null
      : '$outputDir/'
          '${inputStem}_${contentHash}_${cfg.configHash.substring(0, 8)}'
          '_interactive';
  // 超时 deadline 自导出主干（解码之后）起算，与 pipeline 同风格。
  final deadline = pipeline.timeout == null ? null : (Stopwatch()..start());
  try {
    // 派发前检查：已取消则零渲染、零文件。
    _checkInteractionCancel(pipeline, deadline, 'entry');
    final (working, layers) = pipeline.downscaleAndSplitForExport(src);
    final compositor = FrameCompositor(layers, working, cfg);

    // 均匀采样 [-1, 1]，含两端点：phases[i] = -1 + 2i/(steps-1)。
    final phases = <double>[
      for (var i = 0; i < steps; i++) -1.0 + 2.0 * i / (steps - 1),
    ];

    final warnings = <String>[];
    if (cfg.reducedMotion) {
      warnings.add(
          'reducedMotion: interaction frames are static (single still image '
          'across all phases)');
    }

    if (jobDir != null) io.Directory(jobDir).createSync(recursive: true);

    final axes = switch (axis) {
      InteractionAxis.horizontal => [InteractionAxis.horizontal],
      InteractionAxis.vertical => [InteractionAxis.vertical],
      InteractionAxis.both => [
          InteractionAxis.horizontal,
          InteractionAxis.vertical,
        ],
    };

    final sets = <InteractionFrameSet>[];
    var globalFrame = 0; // 落盘帧名跨集合连续编号，避免两轴互相覆盖
    for (final ax in axes) {
      final pngs = <Uint8List>[];
      for (var i = 0; i < phases.length; i++) {
        _checkInteractionCancel(pipeline, deadline, 'before frame render');
        final ph = phases[i];
        compositor.parallaxOverride = ParallaxOverride(
          phaseX: ax == InteractionAxis.horizontal ? ph : 0.0,
          phaseY: ax == InteractionAxis.vertical ? ph : 0.0,
        );
        // t=0 参考相位：视差以外的一切效果冻结在起点。
        final frame = compositor.renderFrame(0);
        final png = Uint8List.fromList(ImageIO.encodePngFrame(frame));
        if (jobDir != null) {
          io.File(ImageIO.pngPathFor(jobDir, globalFrame))
              .writeAsBytesSync(png);
        }
        pngs.add(png);
        globalFrame++;
        _checkInteractionCancel(pipeline, deadline, 'after frame render');
      }
      sets.add(InteractionFrameSet(
        axis: ax,
        phases: List<double>.unmodifiable(phases),
        pngBytes: List<Uint8List>.unmodifiable(pngs),
      ));
    }
    compositor.parallaxOverride = null; // 复位，防复用合成器时串状态

    // 索引 JSON：嵌入方加载即用；不含执行期信息（确定性输出）。
    final setEntries = <Map<String, dynamic>>[];
    var fileCursor = 0;
    for (final s in sets) {
      final files = <String>[
        for (var i = 0; i < s.pngBytes.length; i++)
          'frame_${(fileCursor + i).toString().padLeft(4, '0')}.png',
      ];
      setEntries.add({
        'axis': s.axis.name,
        'phases': s.phases,
        'frames': files,
      });
      fileCursor += s.pngBytes.length;
    }
    final index = <String, dynamic>{
      'kind': 'interactive',
      'version': 1,
      'width': working.width,
      'height': working.height,
      'configHash': cfg.configHash,
      'contentHash': contentHash,
      'reducedMotion': cfg.reducedMotion,
      'sets': setEntries,
    };
    final indexJsonBytes =
        Uint8List.fromList(convert.utf8.encode(convert.jsonEncode(index)));
    if (jobDir != null) {
      io.File('$jobDir/index.json').writeAsBytesSync(indexJsonBytes);
    }

    sw.stop();
    return InteractionExportResult(
      width: working.width,
      height: working.height,
      configHash: cfg.configHash,
      contentHash: contentHash,
      sets: List<InteractionFrameSet>.unmodifiable(sets),
      indexJsonBytes: indexJsonBytes,
      elapsedMs: sw.elapsedMilliseconds,
      outputDir: jobDir ?? '',
      warnings: warnings,
    );
  } on MotionCancelledException {
    if (jobDir != null && !pipeline.keepPartial) {
      _cleanupInteractionDir(jobDir);
    }
    rethrow;
  }
}

/// 导出入口的取消/超时检查：语义与静帧一致（code `E_CANCELLED` /
/// `E_TIMEOUT`），检查点为导出入口与每帧渲染前后。
void _checkInteractionCancel(
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
/// 时移除（与 pipeline 清理同语义：能落到同一目录的必然是同内容 + 同 stem
/// + 同配置，历史产物可复现再生，删除不构成损失）。
void _cleanupInteractionDir(String jobDir) {
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
