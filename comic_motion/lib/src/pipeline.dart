import 'dart:io' as io;
import 'dart:math' as math;

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

/// One-shot processing pipeline: decode -> depth -> layers -> frames -> encode.
class MotionPipeline {
  MotionPipeline(this.config, {int? parallel, this.memoryBudgetMb})
      : _parallel = parallel ??
            math.min(
                kDefaultParallel, math.max(1, io.Platform.numberOfProcessors));

  final EffectConfig config;

  /// 调用方内存预算（MB，可选）。执行期参数：不进 [EffectConfig]、不参与
  /// configHash。按保守启发式自动推导并行上限与工作分辨率：预算不足时先降
  /// 并行，仍不足再收缩工作分辨率（下限 320px），每次降级都写进
  /// [PipelineResult.warnings]。注意：工作分辨率变化会改变输出像素，因此
  /// 预算运行的产物与无预算运行不逐字节一致（同预算 + 同输入仍确定性复现）。
  final int? memoryBudgetMb;

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
  Future<PipelineResult> processFile(String inputPath, String outputDir) async {
    final sw = Stopwatch()..start();
    final src = ImageIO.decodeFile(inputPath);

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

    // Uniform output naming.
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    final jobDir =
        '$outputDir/${baseName}_${config.configHash.substring(0, 8)}';
    io.Directory(jobDir).createSync(recursive: true);

    var gifPath = '';
    var frameDir = '';
    final wantGif = config.outputFormat == OutputFormat.gif ||
        config.outputFormat == OutputFormat.both;
    final wantFrames = config.outputFormat == OutputFormat.frames ||
        config.outputFormat == OutputFormat.both;
    if (wantFrames) {
      frameDir = '$jobDir/frames';
      io.Directory(frameDir).createSync(recursive: true);
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
      for (final k in gif.wantsProbes ? [0, n ~/ 2, n - 1] : [0]) {
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
    void emit(FrameOutput out) {
      hold[out.index] = out;
      while (hold.containsKey(written)) {
        final o = hold.remove(written++)!;
        final body = o.gifBody;
        if (gif != null && body != null) gif.addEncodedBody(body);
      }
    }

    if (pendingCount == 0) {
      for (final out in presolved.values) {
        emit(out);
      }
    } else {
      final runner = await ParallelFrameRunner.start(spec, allowedParallel);
      if (runner == null) {
        fallback = allowedParallel > 1;
        final job = FrameJob(compositor,
            pngDir: spec.pngDir, encoder: gif?.newFrameEncoder());
        for (final out in presolved.values) {
          emit(out);
        }
        for (final i in allIndices) {
          if (!presolved.containsKey(i)) emit(job.run(i));
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
    if (gif != null) {
      gifPath = '$jobDir/anim.gif';
      io.File(gifPath).writeAsBytesSync(gif.finish());
    }

    // Persist the exact params next to outputs (reproducibility contract).
    final paramsFile = '$jobDir/params.json';
    io.File(paramsFile).writeAsStringSync(config.toJsonString());

    sw.stop();
    return PipelineResult(
      inputPath: inputPath,
      outputGif: gifPath,
      frameDir: frameDir,
      paramsFile: paramsFile,
      width: src.width,
      height: src.height,
      layerCount: layers.length,
      frameCount: n,
      elapsedMs: sw.elapsedMilliseconds,
      peakRssMb: _currentRssMb(),
      configJson: config.toJsonString(),
      configHash: config.configHash,
      parallel: parallel,
      parallelFallback: fallback || budgetCappedParallel,
      warnings: [...config.warnings, ...budgetWarnings],
    );
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
