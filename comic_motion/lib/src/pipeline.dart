import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'cancellation.dart';
import 'effect_config.dart';
import 'frame_compositor.dart';
import 'gif_writer.dart';
import 'depth_splitter.dart';
import 'image_io.dart';
import 'image_model.dart';
import 'render/resampler.dart';
import 'worker_pool.dart';

/// 执行期默认并行度：worker 各持一份层栅格副本，收益在 6-8 后转平而内存线性涨，
/// 所以取 8 而不是核数。它不进 EffectConfig（不影响输出，写进配置会污染指纹）。
const int kDefaultParallel = 8;

/// Result of one processing job.
class PipelineResult {
  PipelineResult({
    required this.inputPath,
    required this.outputGif,
    required this.frameDir,
    required this.paramsFile,
    required this.width,
    required this.height,
    required this.layerCount,
    required this.frameCount,
    required this.elapsedMs,
    required this.peakRssMb,
    required this.configJson,
    required this.configHash,
    this.parallel = 1,
    this.parallelFallback = false,
    this.warnings = const [],
  });

  final String inputPath;
  final String outputGif; // '' when frames-only
  final String frameDir; // '' when gif-only
  final String paramsFile; // 参数回放文件（params.json）
  final int width;
  final int height;
  final int layerCount;
  final int frameCount;
  final int elapsedMs;
  final double peakRssMb;
  final String configJson;
  final String configHash;

  /// 实际生效的并行度（1 = 串行）。执行期属性，不参与 configHash。
  final int parallel;

  /// true = 请求过并行但被降级（spawn 失败 / 超内存预算 / 核数不足）。
  final bool parallelFallback;

  /// 配置回落提示（如未知 mood）。执行期属性，不参与 configHash。
  final List<String> warnings;

  Map<String, dynamic> toJson() => {
        'input': inputPath,
        'outputGif': outputGif,
        'frameDir': frameDir,
        'paramsFile': paramsFile,
        'width': width,
        'height': height,
        'layerCount': layerCount,
        'frameCount': frameCount,
        'elapsedMs': elapsedMs,
        'peakRssMb': double.parse(peakRssMb.toStringAsFixed(1)),
        'configHash': configHash,
        'parallel': parallel,
        'parallelFallback': parallelFallback,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
}

/// Result of an in-memory run: bytes in ([MotionPipeline.processBytes]),
/// bytes out. Meta fields mirror [PipelineResult]; there are no paths because
/// nothing touches the filesystem — the caller owns the returned bytes.
class MemoryPipelineResult {
  MemoryPipelineResult({
    required this.gifBytes,
    required this.paramsJsonBytes,
    required this.width,
    required this.height,
    required this.layerCount,
    required this.frameCount,
    required this.elapsedMs,
    required this.peakRssMb,
    required this.configJson,
    required this.configHash,
    this.parallel = 1,
    this.parallelFallback = false,
    this.warnings = const [],
  });

  /// Encoded GIF bytes. Null when the config requests frames-only output
  /// (`outputFormat: frames`) — memory mode never persists PNG frames.
  final Uint8List? gifBytes;

  /// Exact params.json equivalent (parameter replay payload).
  final Uint8List paramsJsonBytes;
  final int width;
  final int height;
  final int layerCount;
  final int frameCount;
  final int elapsedMs;
  final double peakRssMb;
  final String configJson;
  final String configHash;

  /// 实际生效的并行度（1 = 串行）。执行期属性，不参与 configHash。
  final int parallel;

  /// true = 请求过并行但被降级（spawn 失败 / 超内存预算 / 核数不足）。
  final bool parallelFallback;

  /// 配置回落提示（如未知 mood）。执行期属性，不参与 configHash。
  final List<String> warnings;
}

/// Shared interior of [MotionPipeline.processFile] and
/// [MotionPipeline.processBytes]: decode -> budget -> downscale -> depth ->
/// layers -> probe -> dispatch -> encode. There is exactly one render path;
/// the file/memory difference is only where the bytes end up.
class _CoreOutput {
  _CoreOutput({
    required this.gifBytes,
    required this.paramsJson,
    required this.gifPath,
    required this.frameDir,
    required this.paramsFile,
    required this.layerCount,
    required this.frameCount,
    required this.parallel,
    required this.parallelFallback,
    required this.warnings,
  });

  /// null = frames-only（无 GIF 产物）。
  final Uint8List? gifBytes;
  final String paramsJson;

  /// 磁盘模式的产物路径；内存模式一律为空串。
  final String gifPath;
  final String frameDir;
  final String paramsFile;

  final int layerCount;
  final int frameCount;
  final int parallel;
  final bool parallelFallback;
  final List<String> warnings;
}

/// One-shot processing pipeline: decode -> depth -> layers -> frames -> encode.
class MotionPipeline {
  MotionPipeline(
    this.config, {
    int? parallel,
    this.memoryBudgetMb,
    this.onProgress,
    this.cancelToken,
    this.timeout,
    this.keepPartial = false,
  }) : _parallel = parallel ??
            math.min(
                kDefaultParallel, math.max(1, io.Platform.numberOfProcessors));

  final EffectConfig config;

  /// 调用方内存预算（MB，可选）。执行期参数：不进 [EffectConfig]、不参与
  /// configHash。按保守启发式自动推导并行上限与工作分辨率：预算不足时先降
  /// 并行，仍不足再收缩工作分辨率（下限 320px），每次降级都写进
  /// [PipelineResult.warnings]。注意：工作分辨率变化会改变输出像素，因此
  /// 预算运行的产物与无预算运行不逐字节一致（同预算 + 同输入仍确定性复现）。
  final int? memoryBudgetMb;

  /// 进度回调（可选）：`framesDone / framesTotal`，计数含探针帧，按帧边界
  /// （每帧写入 GIF 的顺序位置）触发。取消或超时后不再回调。执行期参数，
  /// 不参与 configHash。
  final void Function(int framesDone, int framesTotal)? onProgress;

  /// 协作式取消令牌（可选）。检查点在帧调度层：派发前 / 每帧回包 / 探针帧
  /// 渲染前；不打断 worker 内部的单帧渲染（纯函数，跑完自然丢弃），取消
  /// 粒度为帧边界。默认清理本次运行写出的半成品并抛
  /// [MotionCancelledException]（code `E_CANCELLED`）；[keepPartial] 可保留。
  final MotionCancelToken? cancelToken;

  /// 超时（可选）：与取消共用同一检查点与清理路径，deadline 自渲染主干
  /// （解码之后）起算，在每个检查点比对；异常 code `E_TIMEOUT`。
  final Duration? timeout;

  /// 取消/超时后是否保留已产出的半成品。默认 false：删除本次运行写出的
  /// GIF / params.json / 帧 PNG（目录仅变空时移除，历史产物不误删）。
  final bool keepPartial;

  final int _parallel;

  /// 保守内存模型：base = VM + 解码缓冲 + 调色板/LUT；每个并行 worker 持有
  /// 一整套层栅格 + 基底 + 帧缓冲副本，按 (layerCount + 2) 份 RGBA 估算并
  /// 乘 1.5 安全系数（效果通路 scratch 未计全）。宁可提前降级，不可 OOM。
  static const double _baseMb = 128;
  static const int _minWorkingDim = 320;

  double _perWorkerMb(RgbaImage src, int dim) {
    final maxSide = src.width > src.height ? src.width : src.height;
    var px = src.pixelCount;
    if (maxSide > dim) {
      final scale = dim / maxSide;
      px = (src.width * scale).round() * (src.height * scale).round();
    }
    return px * 4 * (config.layerCount + 2) * 1.5 / (1024 * 1024);
  }

  /// 收缩 maxDimension 上限是否真的会改变工作栅格（源图本就小于上限时
  /// 不产生任何变化，也不该报降级告警）。
  bool _workingPixelsDiffer(RgbaImage src, int dim) {
    if (dim >= config.maxDimension) return false;
    final maxSide = src.width > src.height ? src.width : src.height;
    return maxSide > dim;
  }

  /// Process one image file into [outputDir] with uniform naming:
  /// `<input-stem>_<configHash>/anim.gif` and `frames/frame_NNNN.png`.
  ///
  /// 帧渲染与 GIF/PNG 编码可派发给 isolate 池并行执行；单帧是纯函数，
  /// 并行度只影响耗时与内存画像，输出字节与串行逐字节一致。
  ///
  /// 注意：解码、降采样、深度估算、分层与调色板探针在调用方 isolate 同步
  /// 执行（仅后续帧渲染派发 worker 池）。UI isolate 里直接调用会卡帧，
  /// 嵌入方请改用后台 isolate 包装（见 README「Embedding into a Flutter app」）。
  Future<PipelineResult> processFile(String inputPath, String outputDir) async {
    final sw = Stopwatch()..start();
    final src = ImageIO.decodeFile(inputPath);

    // Uniform output naming.
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    final jobDir =
        '$outputDir/${baseName}_${config.configHash.substring(0, 8)}';

    final core = await _runCore(src, jobDir: jobDir);
    sw.stop();
    return PipelineResult(
      inputPath: inputPath,
      outputGif: core.gifPath,
      frameDir: core.frameDir,
      paramsFile: core.paramsFile,
      width: src.width,
      height: src.height,
      layerCount: core.layerCount,
      frameCount: core.frameCount,
      elapsedMs: sw.elapsedMilliseconds,
      peakRssMb: _currentRssMb(),
      configJson: config.toJsonString(),
      configHash: config.configHash,
      parallel: core.parallel,
      parallelFallback: core.parallelFallback,
      warnings: core.warnings,
    );
  }

  /// In-memory twin of [processFile]: decode from [input] bytes, render
  /// through the exact same pipeline, return the encoded bytes. No temporary
  /// files, no paths. Same input + same config produces GIF bytes identical
  /// to [processFile] on disk (that equivalence is covered by tests).
  ///
  /// `outputFormat: frames` 在内存模式下不落 PNG 帧序列（无处可落），返回的
  /// [MemoryPipelineResult.gifBytes] 为 null；需要 GIF 时用 gif / both。
  ///
  /// 与 [processFile] 相同：解码与分层段同步执行，UI isolate 调用会卡帧，
  /// 需要后台化时用 isolate 包装（见 README）。
  Future<MemoryPipelineResult> processBytes(
      {required Uint8List input, int? maxPixels}) async {
    final sw = Stopwatch()..start();
    final src =
        ImageIO.decode(input, maxPixels: maxPixels ?? ImageIO.defaultMaxPixels);
    final core = await _runCore(src);
    sw.stop();
    return MemoryPipelineResult(
      gifBytes: core.gifBytes,
      paramsJsonBytes: Uint8List.fromList(convert.utf8.encode(core.paramsJson)),
      width: src.width,
      height: src.height,
      layerCount: core.layerCount,
      frameCount: core.frameCount,
      elapsedMs: sw.elapsedMilliseconds,
      peakRssMb: _currentRssMb(),
      configJson: config.toJsonString(),
      configHash: config.configHash,
      parallel: core.parallel,
      parallelFallback: core.parallelFallback,
      warnings: core.warnings,
    );
  }

  /// 共享渲染主干入口：取消/超时时清理半成品后原样重抛。渲染本体见
  /// [_runCoreInner]。
  Future<_CoreOutput> _runCore(RgbaImage src, {String? jobDir}) async {
    try {
      return await _runCoreInner(src, jobDir: jobDir);
    } on MotionCancelledException {
      if (jobDir != null && !keepPartial) _cleanupPartial(jobDir);
      rethrow;
    }
  }

  /// 渲染主干本体。[jobDir] 为 null 时进入内存模式：不建目录、不写任何文件，
  /// GIF 字节与 params JSON 原样返回。
  ///
  /// 取消/超时检查点（帧调度层）：主干入口、每块探针渲染前、worker 池启动
  /// 前、每帧回包（emit）处。单帧渲染内部不可打断。
  Future<_CoreOutput> _runCoreInner(RgbaImage src, {String? jobDir}) async {
    final token = cancelToken;
    final deadline = timeout == null ? null : (Stopwatch()..start());
    var cancelled = false;
    var cancelCode = 'E_CANCELLED';
    var cancelMsg = 'cancelled by caller';

    void triggerCancel(String code, String msg) {
      if (cancelled) return;
      cancelled = true;
      cancelCode = code;
      cancelMsg = msg;
    }

    // 超时用 deadline 比对而非 Timer：状态只在检查点被读取，两者生效时机
    // 相同（帧边界），且无定时器泄漏风险。
    void checkCancel() {
      if (!cancelled) {
        final dl = deadline;
        if (dl != null && dl.elapsed > timeout!) {
          triggerCancel('E_TIMEOUT',
              'render timed out after ${timeout!.inMilliseconds}ms');
        } else if (token != null && token.isCancelled) {
          triggerCancel('E_CANCELLED', 'cancelled by caller');
        }
      }
      if (cancelled) {
        throw MotionCancelledException(cancelMsg, code: cancelCode);
      }
    }

    // 派发前检查：已取消则零渲染直接失败。
    checkCancel();
    // Memory budget: derive the working-resolution cap and the parallel cap
    // before touching the pixel path. 无预算时零改动（legacy 逐字节路径不受
    // 任何影响）。
    final budgetWarnings = <String>[];
    var budgetCappedParallel = false;
    var effectiveMaxDim = config.maxDimension;
    var allowedParallel = _parallel;
    final budget = memoryBudgetMb?.toDouble();
    if (budget != null) {
      var dim = config.maxDimension;
      while (dim > _minWorkingDim &&
          _baseMb + 2 * _perWorkerMb(src, dim) > budget) {
        final next = math.max(_minWorkingDim, (dim * 0.7).floor());
        if (next == dim) break;
        dim = next;
      }
      if (_workingPixelsDiffer(src, dim)) {
        effectiveMaxDim = dim;
        budgetWarnings.add(
            'memory budget ${memoryBudgetMb}MB: working resolution capped at '
            '${effectiveMaxDim}px (config maxDimension ${config.maxDimension}px)');
      }
      final perWorker = _perWorkerMb(src, effectiveMaxDim);
      if (_baseMb + 2 * perWorker > budget) {
        allowedParallel = 1;
        budgetWarnings.add(
            'memory budget ${memoryBudgetMb}MB too small for the estimated '
            'footprint; degraded to parallel=1');
      } else {
        // (p + 1) 份：p 个 worker 各一份 + 主 isolate 一份。
        final pMax = ((budget - _baseMb) / perWorker).floor() - 1;
        if (pMax < 1) {
          allowedParallel = 1;
        } else if (pMax < _parallel) {
          allowedParallel = pMax;
        }
      }
      if (allowedParallel < _parallel) {
        budgetCappedParallel = true;
        budgetWarnings.add(
            'memory budget ${memoryBudgetMb}MB: parallel capped at '
            '$allowedParallel (requested $_parallel)');
      }
    }

    // Working resolution guard: downscale very large inputs for speed.
    // 目标尺寸两档算法一致，只有滤波器不同：legacy 沿 v1.2 双线性，
    // standard+ 走面积平均（细线稿不再产生锯齿与摩尔纹）。
    final working = config.quality.tier.atLeastStandard
        ? boxDownscale(src, effectiveMaxDim)
        : _downscaleTo(src, effectiveMaxDim);

    // Depth + layers. legacy 档保持 v1.2 的最近邻掩码（不羽化、不外扩）。
    final depth = DepthEstimator(workScale: 0.5).estimate(working);
    final splitter = LayerSplitter(
      layerCount: config.layerCount,
      tier: config.quality.tier,
      edgeStretchPx: config.quality.edgeStretchPx,
    );
    final layers = splitter.split(working, depth);

    // Frames: stream-render -> quantize -> LZW -> discard (O(one frame) RAM).
    final compositor = FrameCompositor(layers, working, config);

    var gifPath = '';
    var frameDir = '';
    final wantGif = config.outputFormat == OutputFormat.gif ||
        config.outputFormat == OutputFormat.both;
    // PNG 帧序列只属于磁盘模式；内存模式没有可落盘处（wantFrames 恒 false）。
    final wantFrames = jobDir != null &&
        (config.outputFormat == OutputFormat.frames ||
            config.outputFormat == OutputFormat.both);
    if (jobDir != null) {
      io.Directory(jobDir).createSync(recursive: true);
      if (wantFrames) {
        frameDir = '$jobDir/frames';
        io.Directory(frameDir).createSync(recursive: true);
      }
    }
    final gif = wantGif
        ? StreamingGifBuilder.fromConfig(config, working.width, working.height)
        : null;

    final n = config.frameCount;
    // 调色板探针必须在派工之前定板（worker 只共享板，不建板）。
    // legacy = v1.2 的「首帧建板」；standard+ = 首/中/末三帧，避免只在中间帧
    // 出现的动效亮色挤不进 256 色。renderFrame 是 t 的纯函数，乱序预渲染安全。
    final presolved = <int, FrameOutput>{};
    if (gif != null) {
      final probes = <int, RgbaImage>{};
      checkCancel(); // 探针帧渲染前检查
      for (final k in gif.wantsProbes ? [0, n ~/ 2, n - 1] : [0]) {
        checkCancel();
        final frame =
            probes.putIfAbsent(k, () => compositor.renderFrame(k / config.fps));
        if (wantFrames) ImageIO.writePngFrame(frameDir, k, frame);
      }
      gif.primePalette(probes.values.toList());
      final enc = gif.newFrameEncoder();
      probes.forEach((k, frame) =>
          presolved[k] = FrameOutput(k, enc.encodeFrameBody(frame)));
      probes.clear();
    }

    final spec = FrameJobSpec.fromLayers(
      base: working,
      layers: layers,
      config: config,
      pngDir: wantFrames ? frameDir : null,
      gif: gif == null ? null : GifEncoderSpec.from(gif),
    );
    final allIndices = [for (var i = 0; i < n; i++) i];
    final pendingCount = n - presolved.length;

    var parallel = 1;
    var fallback = false;
    // 严格按帧号递增追加片段；乱序到达的先压在 hold 里，内存 O(窗口)。
    var written = 0;
    final hold = <int, FrameOutput>{};
    final progressCb = onProgress;
    void reportProgress() {
      // 取消/超时后不再回调。
      if (progressCb == null || cancelled || (token?.isCancelled ?? false)) {
        return;
      }
      progressCb(written, n);
    }

    void emit(FrameOutput out) {
      checkCancel(); // 每帧回包处检查（含串行、worker、探针三条路径）
      hold[out.index] = out;
      while (hold.containsKey(written)) {
        final o = hold.remove(written++)!;
        final body = o.gifBody;
        if (gif != null && body != null) gif.addEncodedBody(body);
      }
      reportProgress();
    }

    if (pendingCount == 0) {
      for (final out in presolved.values) {
        emit(out);
      }
    } else {
      checkCancel(); // worker 池启动（派发）前检查
      final runner = await ParallelFrameRunner.start(spec, allowedParallel);
      if (runner == null) {
        fallback = allowedParallel > 1;
        final job = FrameJob(compositor,
            pngDir: spec.pngDir, encoder: gif?.newFrameEncoder());
        for (final out in presolved.values) {
          emit(out);
        }
        for (final i in allIndices) {
          if (!presolved.containsKey(i)) {
            checkCancel(); // 先检查再渲染，取消后不浪费单帧
            emit(job.run(i));
          }
        }
      } else {
        try {
          parallel = runner.workerCount;
          // 传全部帧号：探针帧在 run 内部按序直出、不派工，
          // 否则首帧（=探针 0）永远不会进 GIF。
          await runner.run(allIndices, presolved, (i, out) => emit(out));
        } finally {
          await runner.dispose();
        }
      }
    }
    Uint8List? gifBytes;
    if (gif != null) {
      final bytes = gif.finish();
      if (jobDir != null) {
        gifPath = '$jobDir/anim.gif';
        io.File(gifPath).writeAsBytesSync(bytes);
      }
      gifBytes = Uint8List.fromList(bytes);
    }

    // Persist the exact params next to outputs (reproducibility contract).
    final paramsJson = config.toJsonString();
    var paramsFile = '';
    if (jobDir != null) {
      paramsFile = '$jobDir/params.json';
      io.File(paramsFile).writeAsStringSync(paramsJson);
    }

    return _CoreOutput(
      gifBytes: gifBytes,
      paramsJson: paramsJson,
      gifPath: gifPath,
      frameDir: frameDir,
      paramsFile: paramsFile,
      layerCount: layers.length,
      frameCount: n,
      parallel: parallel,
      parallelFallback: fallback || budgetCappedParallel,
      warnings: [...config.warnings, ...budgetWarnings],
    );
  }

  /// 取消/超时的默认清理：删除本次运行写出的 GIF / params.json / 帧 PNG；
  /// 目录仅在变空时移除。jobDir 内嵌 hash8——能落到同一目录的必然是同
  /// stem + 同配置，历史产物可复现再生，删除不构成损失。
  static void _cleanupPartial(String jobDir) {
    void silentDeleteFile(String p) {
      try {
        final f = io.File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    silentDeleteFile('$jobDir/anim.gif');
    silentDeleteFile('$jobDir/params.json');
    try {
      final d = io.Directory('$jobDir/frames');
      if (d.existsSync()) {
        for (final e in d.listSync()) {
          if (e is io.File) e.deleteSync();
        }
        d.deleteSync();
      }
    } catch (_) {}
    try {
      io.Directory(jobDir).deleteSync(); // 非空则失败，忽略
    } catch (_) {}
  }

  RgbaImage _downscaleTo(RgbaImage src, int maxDim) {
    final maxSide = src.width > src.height ? src.width : src.height;
    if (maxSide <= maxDim) return src;
    final ratio = maxDim / maxSide;
    final nw = (src.width * ratio).round().clamp(1, maxDim);
    final nh = (src.height * ratio).round().clamp(1, maxDim);
    final out = RgbaImage(width: nw, height: nh);
    final sx = src.width / nw, sy = src.height / nh;
    final tmp = List<int>.filled(4, 0);
    for (var y = 0; y < nh; y++) {
      for (var x = 0; x < nw; x++) {
        src.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, tmp);
        out.setPixel(x, y, tmp[0], tmp[1], tmp[2], tmp[3]);
      }
    }
    return out;
  }

  static double _currentRssMb() {
    // dart:io ProcessInfo works across desktop platforms.
    try {
      return io.ProcessInfo.maxRss / (1024 * 1024);
    } catch (_) {
      return -1; // unsupported platform marker
    }
  }
}
