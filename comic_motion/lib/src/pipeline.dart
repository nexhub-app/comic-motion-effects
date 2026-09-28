import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'cancellation.dart';
import 'apng_writer.dart';
import 'panel_splitter.dart';
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
    required this.contentHash,
    this.firstFramePng,
    this.parallel = 1,
    this.parallelFallback = false,
    this.warnings = const [],
    this.outputApng = '',
  });

  final String inputPath;
  final String outputGif; // '' when frames-only / apng-only
  final String frameDir; // '' when gif-only / apng-only
  final String paramsFile; // 参数回放文件（params.json）

  /// APNG 产物路径（`outputFormat: apng` 磁盘模式非空；执行期产物，
  /// 不进 [toJson] 除非非空——既有格式 JSON 键序零变化）。
  final String outputApng;
  final int width;
  final int height;
  final int layerCount;
  final int frameCount;
  final int elapsedMs;
  final double peakRssMb;
  final String configJson;
  final String configHash;

  /// 输入内容指纹（`ImageIO.contentHash8`，输入字节的 FNV-1a 64 前 8 位）。
  /// 与 configHash 正交：不进 EffectConfig 序列化；产物目录命名
  /// `<stem>_<contentHash8>_<configHash8>` 的一部分，同名文件内容变化后
  /// 目录随之改变，旧缓存不再被命中。
  final String contentHash;

  /// 实际生效的并行度（1 = 串行）。执行期属性，不参与 configHash。
  final int parallel;

  /// true = 请求过并行但被降级（spawn 失败 / 超内存预算 / 核数不足）。
  final bool parallelFallback;

  /// 配置回落提示（如未知 mood）。执行期属性，不参与 configHash。
  final List<String> warnings;

  /// `includeFirstFrame: true` 时的首帧 PNG（Uint8List），未请求为 null。
  /// 与 GIF 首帧同源（同一渲染帧：GIF 里的副本经调色板量化），字节与
  /// `frames/frame_0000.png` 完全一致。执行期产物，不进 [toJson]。
  final Uint8List? firstFramePng;

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
        'contentHash': contentHash,
        'parallel': parallel,
        'parallelFallback': parallelFallback,
        if (warnings.isNotEmpty) 'warnings': warnings,
        if (outputApng.isNotEmpty) 'outputApng': outputApng,
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
    required this.contentHash,
    this.firstFramePng,
    this.parallel = 1,
    this.parallelFallback = false,
    this.warnings = const [],
    this.apngBytes,
  });

  /// Encoded GIF bytes. Null when the config requests frames-only output
  /// (`outputFormat: frames`) — memory mode never persists PNG frames.
  final Uint8List? gifBytes;

  /// APNG 容器字节（`outputFormat: apng` 时非 null，此时 [gifBytes] 为 null）。
  final Uint8List? apngBytes;

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

  /// 输入内容指纹（同 [PipelineResult.contentHash]；此处基于传入的
  /// [MotionPipeline.processBytes] input 字节）。
  final String contentHash;

  /// 实际生效的并行度（1 = 串行）。执行期属性，不参与 configHash。
  final int parallel;

  /// true = 请求过并行但被降级（spawn 失败 / 超内存预算 / 核数不足）。
  final bool parallelFallback;

  /// 配置回落提示（如未知 mood）。执行期属性，不参与 configHash。
  final List<String> warnings;

  /// `includeFirstFrame: true` 时的首帧 PNG，未请求为 null（语义同
  /// [PipelineResult.firstFramePng]）。
  final Uint8List? firstFramePng;
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
    required this.firstFramePng,
    required this.layerCount,
    required this.frameCount,
    required this.parallel,
    required this.parallelFallback,
    required this.warnings,
    this.apngBytes,
    this.apngPath = '',
  });

  /// null = frames-only（无 GIF 产物）。
  final Uint8List? gifBytes;

  /// APNG 产物（`outputFormat: apng` 时非 null；apngPath 仅磁盘模式非空）。
  final Uint8List? apngBytes;
  final String apngPath;

  final String paramsJson;

  /// 磁盘模式的产物路径；内存模式一律为空串。
  final String gifPath;
  final String frameDir;
  final String paramsFile;

  /// `includeFirstFrame: true` 时的首帧 PNG（复用探针帧，未请求为 null）。
  final Uint8List? firstFramePng;

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
    this.onFrame,
    this.cancelToken,
    this.timeout,
    this.keepPartial = false,
    DepthEstimator? depthEstimator,
  }) : _parallel = parallel ??
            math.min(
                kDefaultParallel, math.max(1, io.Platform.numberOfProcessors)),
        _depthEstimator = depthEstimator;

  /// 深度估算器注入（W6）：null = 内置启发式（[HeuristicDepthEstimator]，
  /// 与接口化前像素输出逐字节一致）。执行期依赖，不参与 configHash。
  final DepthEstimator? _depthEstimator;

  /// 当前生效的估算器（注入优先，缺省启发式）。
  DepthEstimator get effectiveDepthEstimator =>
      _depthEstimator ?? const HeuristicDepthEstimator();

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

  /// 帧流回调（可选，T4）：每帧回包、按帧号**有序**触发（帧号升序，一帧
  /// 恰好一次，含调色板探针帧）。回调运行在**执行管线的 isolate**上——
  /// 同步入口即在调用方 isolate（emit 帧回包点是同步执行段，回调里做重活
  /// 会直接拖慢渲染）；后台便捷入口（processFileInBackground 等）经
  /// SendPort 桥接，用户回调执行在调用方 isolate。与 [onProgress] 并存，
  /// 取消 / 超时后不再回调。PNG 字节与落盘 `frames/frame_NNNN.png` 同源
  /// 同字节。执行期参数，不参与 configHash；仅设置本回调时才会把每帧 PNG
  /// 编码并回传（默认零额外成本）。
  final void Function(int frameIndex, Uint8List pngBytes)? onFrame;

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
  /// `<input-stem>_<contentHash8>_<configHash8>/anim.gif` and
  /// `frames/frame_NNNN.png`. contentHash8 是输入文件字节的指纹（
  /// [ImageIO.contentHash8]）：同名文件内容变化后产物目录随之改变，
  /// 嵌入方「目录存在 → 跳过渲染」的缓存逻辑不会命中旧画面。
  ///
  /// 帧渲染与 GIF/PNG 编码可派发给 isolate 池并行执行；单帧是纯函数，
  /// 并行度只影响耗时与内存画像，输出字节与串行逐字节一致。
  ///
  /// 注意：解码、降采样、深度估算、分层与调色板探针在调用方 isolate 同步
  /// 执行（仅后续帧渲染派发 worker 池）。UI isolate 里直接调用会卡帧，
  /// 嵌入方请改用后台 isolate 包装（见 README「Embedding into a Flutter app」）。
  ///
  /// [includeFirstFrame] 为 true 时结果附带 [PipelineResult.firstFramePng]
  /// ——首帧本来就是调色板探针渲过的，直接复用同一份栅格，零额外渲染成本。
  Future<PipelineResult> processFile(String inputPath, String outputDir,
      {bool includeFirstFrame = false}) async {
    final sw = Stopwatch()..start();
    // 单次读盘：同一份字节既做内容指纹又做解码输入（守卫与 decodeFile 一致）。
    final bytes = ImageIO.readFileBytes(inputPath);
    final src = ImageIO.decode(bytes);

    // Uniform output naming.
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    final contentHash = ImageIO.contentHash8(bytes);
    final jobDir = '$outputDir/'
        '${baseName}_${contentHash}_${config.configHash.substring(0, 8)}';

    final core = await _runCore(src,
        jobDir: jobDir, includeFirstFrame: includeFirstFrame);
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
      contentHash: contentHash,
      firstFramePng: core.firstFramePng,
      parallel: core.parallel,
      parallelFallback: core.parallelFallback,
      warnings: core.warnings,
      outputApng: core.apngPath,
    );
  }

  /// 对已解码的 [RgbaImage] 走标准管线（与 [processFile] 共享同一渲染
  /// 主干，无第二套像素逻辑）。strip 模式逐片复用本入口；嵌入方自备解码
  /// 结果时也可直接使用。
  ///
  /// [baseName] 用于输出目录命名 `<baseName>_<contentHash8>_<configHash8>`
  /// ——contentHash8 取传入栅格 RGBA 字节的指纹（无原始文件字节可用，
  /// 与 [processFile] 的文件字节指纹口径不同但同样确定）；[inputLabel] 仅作
  /// 结果记录（ledger / 调试），不参与渲染。注意：像素总量预算在解码阶段
  /// 执行，本入口不做二次解码校验。
  Future<PipelineResult> processImage(
    RgbaImage source,
    String outputDir, {
    String baseName = 'image',
    String inputLabel = 'memory:image',
    bool includeFirstFrame = false,
  }) async {
    final sw = Stopwatch()..start();
    final contentHash = ImageIO.contentHash8(source.data);
    final jobDir = '$outputDir/'
        '${baseName}_${contentHash}_${config.configHash.substring(0, 8)}';
    final core = await _runCore(source,
        jobDir: jobDir, includeFirstFrame: includeFirstFrame);
    sw.stop();
    return PipelineResult(
      inputPath: inputLabel,
      outputGif: core.gifPath,
      frameDir: core.frameDir,
      paramsFile: core.paramsFile,
      width: source.width,
      height: source.height,
      layerCount: core.layerCount,
      frameCount: core.frameCount,
      elapsedMs: sw.elapsedMilliseconds,
      peakRssMb: _currentRssMb(),
      configJson: config.toJsonString(),
      configHash: config.configHash,
      contentHash: contentHash,
      firstFramePng: core.firstFramePng,
      parallel: core.parallel,
      parallelFallback: core.parallelFallback,
      warnings: core.warnings,
      outputApng: core.apngPath,
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
  ///
  /// [includeFirstFrame] 为 true 时结果附带首帧 PNG（复用探针帧；语义同
  /// [processFile]）。
  Future<MemoryPipelineResult> processBytes(
      {required Uint8List input,
      int? maxPixels,
      bool includeFirstFrame = false}) async {
    final sw = Stopwatch()..start();
    final src =
        ImageIO.decode(input, maxPixels: maxPixels ?? ImageIO.defaultMaxPixels);
    final core =
        await _runCore(src, includeFirstFrame: includeFirstFrame);
    sw.stop();
    return MemoryPipelineResult(
      gifBytes: core.gifBytes,
      apngBytes: core.apngBytes,
      paramsJsonBytes: Uint8List.fromList(convert.utf8.encode(core.paramsJson)),
      width: src.width,
      height: src.height,
      layerCount: core.layerCount,
      frameCount: core.frameCount,
      elapsedMs: sw.elapsedMilliseconds,
      peakRssMb: _currentRssMb(),
      configJson: config.toJsonString(),
      configHash: config.configHash,
      contentHash: ImageIO.contentHash8(input),
      firstFramePng: core.firstFramePng,
      parallel: core.parallel,
      parallelFallback: core.parallelFallback,
      warnings: core.warnings,
    );
  }

  /// 渲染 [input] 在 `t` 时刻的静帧（T2）：解码 → 降采样 → 分层一次完成，
  /// 只渲染一帧，**跳过 GIF 编码与调色板探针**，成本 ≈ 单帧渲染 + 一次 PNG
  /// 编码。与全量渲染共享同一前置段（[_downscaleAndSplit]），t=0 的静帧与
  /// GIF 首帧逐像素同源（GIF 里的副本经调色板量化）。
  ///
  /// [t] 单位为秒，负值按 0 处理；动效按周期纯函数取值，t 超出时长同样
  /// 合法（整循环无缝）。全量渲染的第 i 帧对应 `t = i / fps`。受
  /// [cancelToken] / [timeout] 管控（入口与渲染前各检查一次，粒度为整次
  /// 静帧）；不使用 worker 池，`parallel` / `memoryBudgetMb` 与静帧无关。
  Future<Uint8List> renderStillFrame(
      {required Uint8List input, double t = 0, int? maxPixels}) async {
    final src =
        ImageIO.decode(input, maxPixels: maxPixels ?? ImageIO.defaultMaxPixels);
    return _renderStill(src, t);
  }

  /// [renderStillFrame] 的文件入口：路径进、PNG `Uint8List` 出。
  Future<Uint8List> renderStillFrameFile(String inputPath, {double t = 0}) {
    return _renderStill(ImageIO.decode(ImageIO.readFileBytes(inputPath)), t);
  }

  Future<Uint8List> _renderStill(RgbaImage src, double t) async {
    final deadline = timeout == null ? null : (Stopwatch()..start());
    _checkStillCancel(deadline, 'entry');
    final (working, layers) = _downscaleAndSplit(src, config.maxDimension);
    _checkStillCancel(deadline, 'before render');
    final frame = FrameCompositor(layers, working, config)
        .renderFrame(math.max(0.0, t));
    return Uint8List.fromList(ImageIO.encodePngFrame(frame));
  }

  /// 静帧入口的取消/超时检查：语义与全量渲染一致（code `E_CANCELLED` /
  /// `E_TIMEOUT`），检查点为静帧入口与渲染前两处。
  void _checkStillCancel(Stopwatch? deadline, String stage) {
    if (deadline != null && timeout != null && deadline.elapsed > timeout!) {
      throw MotionCancelledException(
          'render timed out after ${timeout!.inMilliseconds}ms ($stage)',
          code: 'E_TIMEOUT');
    }
    final token = cancelToken;
    if (token != null && token.isCancelled) {
      throw MotionCancelledException('cancelled by caller',
          code: 'E_CANCELLED');
    }
  }

  /// 共享渲染主干入口：取消/超时时清理半成品后原样重抛。渲染本体见
  /// [_runCoreInner]。
  Future<_CoreOutput> _runCore(RgbaImage src,
      {String? jobDir, bool includeFirstFrame = false}) async {
    try {
      return await _runCoreInner(src,
          jobDir: jobDir, includeFirstFrame: includeFirstFrame);
    } on MotionCancelledException {
      if (jobDir != null && !keepPartial) _cleanupPartial(jobDir);
      rethrow;
    }
  }

  /// 渲染主干本体。[jobDir] 为 null 时进入内存模式：不建目录、不写任何文件，
  /// GIF 字节与 params JSON 原样返回。[includeFirstFrame] 为 true 时随结果
  /// 返回首帧 PNG（复用调色板探针帧，见 [_CoreOutput.firstFramePng]）。
  ///
  /// 取消/超时检查点（帧调度层）：主干入口、每块探针渲染前、worker 池启动
  /// 前、每帧回包（emit）处。单帧渲染内部不可打断。
  Future<_CoreOutput> _runCoreInner(RgbaImage src,
      {String? jobDir, bool includeFirstFrame = false}) async {
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
    final (working, layers) = _downscaleAndSplit(src, effectiveMaxDim);

    // Frames: stream-render -> quantize -> LZW -> discard (O(one frame) RAM).
    final compositor = FrameCompositor(layers, working, config);

    var gifPath = '';
    var frameDir = '';
    final wantGif = config.outputFormat == OutputFormat.gif ||
        config.outputFormat == OutputFormat.both;
    // APNG（第四轮 V3，opt-in 新路径）：全画布真彩色帧容器，复用 worker 的
    // PNG 回传通路（wantPngBytes），默认 outputFormat 行为零变化。
    final wantApng = config.outputFormat == OutputFormat.apng;
    // APNG exact 延迟（W3 opt-in）：encoding.apngDelay = 'exact' 时 fcTL 写
    // 精确分数 1/fps；默认 cs 口径输出与 v1.3 逐字节一致。
    final apng = wantApng
        ? StreamingApngBuilder(working.width, working.height,
            fps: config.fps,
            exactDelay: config.encoding.apngDelay == 'exact')
        : null;
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
    // rect 帧间差分（T5，opt-in）：worker 回传量化索引图，差分 + LZW 在主
    // isolate 按帧序做（差分状态在构建器内）。none 模式路径零改动。
    // APNG rect 差分（W3）：同一 opt-in 开关下的另一容器路径——worker 回传
    // 整帧 RGBA，主 isolate 逐字节差分出变化矩形，区域帧进 APNG 容器。
    final rectMode = gif != null && config.encoding.diffMode == 'rect';
    final apngRect =
        wantApng && !wantGif && config.encoding.diffMode == 'rect';
    // 调色板探针必须在派工之前定板（worker 只共享板，不建板）。
    // legacy = v1.2 的「首帧建板」；standard+ = 首/中/末三帧，避免只在中间帧
    // 出现的动效亮色挤不进 256 色。renderFrame 是 t 的纯函数，乱序预渲染安全。
    final presolved = <int, FrameOutput>{};
    RgbaImage? firstFrameRgba;
    if (gif != null) {
      final probes = <int, RgbaImage>{};
      checkCancel(); // 探针帧渲染前检查
      for (final k in gif.wantsProbes ? [0, n ~/ 2, n - 1] : [0]) {
        checkCancel();
        final frame =
            probes.putIfAbsent(k, () => compositor.renderFrame(k / config.fps));
        if (wantFrames) ImageIO.writePngFrame(frameDir, k, frame);
      }
      // 首帧封面：直接复用探针帧 0 的同一份栅格，零额外渲染成本（T2）。
      if (includeFirstFrame) firstFrameRgba = probes[0];
      gif.primePalette(probes.values.toList());
      final enc = gif.newFrameEncoder();
      final frameCb = onFrame;
      probes.forEach((k, frame) {
        presolved[k] = FrameOutput(
          k,
          rectMode ? null : enc.encodeFrameBody(frame),
          pngBytes: frameCb == null
              ? null
              : Uint8List.fromList(ImageIO.encodePngFrame(frame)),
          indexed: rectMode ? enc.quantizeIndices(frame) : null,
        );
      });
      probes.clear();
    } else if (includeFirstFrame) {
      // frames-only / apng 路径没有探针段：主 isolate 预渲染第 0 帧充当
      // 封面帧并记入 presolved（派工跳过该帧），与 GIF 路径一样只渲染一次。
      checkCancel(); // 探针帧渲染前检查
      firstFrameRgba = compositor.renderFrame(0);
      if (wantFrames) ImageIO.writePngFrame(frameDir, 0, firstFrameRgba);
      // apng 模式需要帧 PNG 字节进容器（onFrame 回调同样复用）。
      // apng rect 模式首帧仍走全画布 PNG 字节进容器，rgba 供差分状态初始化。
      final pngNeeded = wantApng || onFrame != null;
      presolved[0] = FrameOutput(
        0,
        null,
        pngBytes:
            pngNeeded ? Uint8List.fromList(ImageIO.encodePngFrame(firstFrameRgba)) : null,
        rgba: apngRect ? Uint8List.fromList(firstFrameRgba.data) : null,
      );
    }
    final firstFramePng = includeFirstFrame
        ? Uint8List.fromList(ImageIO.encodePngFrame(firstFrameRgba!))
        : null;

    final spec = FrameJobSpec.fromLayers(
      base: working,
      layers: layers,
      config: config,
      pngDir: wantFrames ? frameDir : null,
      gif: gif == null ? null : GifEncoderSpec.from(gif),
      // apng 容器需要每帧 PNG 字节回传（worker 侧编码一次，复用帧流通路）；
      // apng rect 模式容器改走 rgba 差分区域帧，全帧 PNG 只在 onFrame 需要时回传。
      wantPngBytes: onFrame != null || (wantApng && !apngRect),
      rectMode: rectMode,
      wantRgba: apngRect,
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

    // apng rect 差分状态：按序消费时保留上一帧 RGBA（O(单帧) 内存）。
    Uint8List? apngPrev;

    void emit(FrameOutput out) {
      checkCancel(); // 每帧回包处检查（含串行、worker、探针三条路径）
      hold[out.index] = out;
      final frameCb = onFrame;
      while (hold.containsKey(written)) {
        final o = hold.remove(written++)!;
        final indexed = o.indexed;
        if (gif != null && indexed != null) {
          gif.addIndexedFrame(indexed);
        } else {
          final body = o.gifBody;
          if (gif != null && body != null) gif.addEncodedBody(body);
        }
        // APNG 容器按帧序吞帧。rect 模式（W3）：主 isolate 持有上一帧
        // RGBA 做逐字节差分 → 区域帧进容器（首帧全画布 PNG 字节直进）；
        // 普通模式按帧序吞 PNG 字节（worker/串行/预解三路同源同字节）。
        if (apng != null) {
          if (apngRect) {
            final rgba = o.rgba;
            final prev = apngPrev;
            if (rgba != null) {
              if (prev == null) {
                final pb0 = o.pngBytes;
                if (pb0 != null) {
                  apng.addEncodedPngFrame(pb0);
                } else {
                  apng.addFrame(
                      RgbaImage.fromBytes(
                          width: working.width,
                          height: working.height,
                          data: rgba),
                  );
                }
              } else {
                final region =
                    _diffRect(prev, rgba, working.width, working.height);
                apng.addRectFrame(
                    RgbaImage.fromBytes(
                        width: working.width,
                        height: working.height,
                        data: rgba),
                    region: region);
              }
              apngPrev = rgba;
            }
          } else {
            final pb = o.pngBytes;
            if (pb != null) {
              apng.addEncodedPngFrame(pb);
            }
          }
        }
        // 帧流回调：按帧号有序（drain 顺序即帧序），取消后不再触发。
        final cbBytes = o.pngBytes;
        if (frameCb != null &&
            cbBytes != null &&
            !cancelled &&
            !(token?.isCancelled ?? false)) {
          frameCb(o.index, cbBytes);
        }
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
            pngDir: spec.pngDir,
            encoder: gif?.newFrameEncoder(),
            wantPngBytes: spec.wantPngBytes,
            rectMode: spec.rectMode,
            wantRgba: spec.wantRgba);
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
    Uint8List? apngBytes;
    var apngPath = '';
    if (apng != null) {
      final bytes = apng.finish();
      if (jobDir != null) {
        apngPath = '$jobDir/anim.apng';
        io.File(apngPath).writeAsBytesSync(bytes);
      }
      apngBytes = Uint8List.fromList(bytes);
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
      apngBytes: apngBytes,
      apngPath: apngPath,
      paramsJson: paramsJson,
      gifPath: gifPath,
      frameDir: frameDir,
      paramsFile: paramsFile,
      firstFramePng: firstFramePng,
      layerCount: layers.length,
      frameCount: n,
      parallel: parallel,
      parallelFallback: fallback || budgetCappedParallel,
      warnings: [...config.warnings, ...budgetWarnings],
    );
  }

  /// 取消/超时的默认清理：删除本次运行写出的 GIF / params.json / 帧 PNG；
  /// 目录仅在变空时移除。jobDir 内嵌 contentHash8 + configHash8——能落到
  /// 同一目录的必然是同内容 + 同 stem + 同配置，历史产物可复现再生，
  /// 删除不构成损失。
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

  /// 共同前置段（静帧与全量渲染共享）：降采样 + 深度估算 + 分层。两条路径
  /// 用同一实现，保证 t=0 静帧与 GIF 首帧逐像素同源。目标尺寸两档算法一致，
  /// 只有滤波器不同：legacy 沿 v1.2 双线性，standard+ 走面积平均（细线稿
  /// 不再产生锯齿与摩尔纹）；legacy 档保持 v1.2 的最近邻掩码（不羽化、不外扩）。
  ///
  /// panelAware（W5，仅 autoLayers 路径）：先横向白带分格检测；多格图逐格
  /// 独立估算深度与分层（层写回全图坐标并携带格边界裁剪，合成时跨格串色
  /// 根除）；单格/无白带图自动回退整页分层（与 panelAware 关闭逐字节等价）。
  (RgbaImage, List<LayerImage>) _downscaleAndSplit(
      RgbaImage src, int effectiveMaxDim) {
    final working = config.quality.tier.atLeastStandard
        ? boxDownscale(src, effectiveMaxDim)
        : _downscaleTo(src, effectiveMaxDim);
    if (config.panelAware && config.depthMode == DepthMode.autoLayers) {
      final panels = const PanelSplitter().split(working);
      if (panels.length >= 2) {
        return (working, _splitPerPanel(working, panels));
      }
    }
    final depth = effectiveDepthEstimator.estimate(working);
    final splitter = LayerSplitter(
      layerCount: config.layerCount,
      tier: config.quality.tier,
      edgeStretchPx: config.quality.edgeStretchPx,
    );
    return (working, splitter.split(working, depth));
  }

  /// W5 分格感知：逐格裁剪子图 → 独立 DepthEstimator + LayerSplitter →
  /// 层内容写回全图尺寸透明画布（格区域），携带格内 rank 与格边界裁剪。
  /// 层序列 = 格序 × 格内 rank 序（合成器按 rank 归一视差倍率，跨格一致）。
  List<LayerImage> _splitPerPanel(
      RgbaImage working, List<PixelRect> panels) {
    final layers = <LayerImage>[];
    for (final panel in panels) {
      // 裁剪子图（逐行拷贝）。
      final sub = RgbaImage(width: panel.width, height: panel.height);
      for (var y = 0; y < panel.height; y++) {
        final srcBase = ((panel.y + y) * working.width + panel.x) * 4;
        sub.data.setRange(y * panel.width * 4, (y + 1) * panel.width * 4,
            working.data, srcBase);
      }
      final depth = effectiveDepthEstimator.estimate(sub);
      final splitter = LayerSplitter(
        layerCount: config.layerCount,
        tier: config.quality.tier,
        edgeStretchPx: config.quality.edgeStretchPx,
      );
      for (final l in splitter.split(sub, depth)) {
        // 写回全图坐标：透明画布 + 子图区域内容（格边界由 clip 在合成期
        // 裁剪——层内容本就只落在格内，clip 兜住视差位移后的越界绘制）。
        final full = RgbaImage(width: working.width, height: working.height);
        for (var y = 0; y < panel.height; y++) {
          final dstBase = ((panel.y + y) * working.width + panel.x) * 4;
          full.data.setRange(dstBase, dstBase + panel.width * 4,
              l.image.data, y * panel.width * 4);
        }
        layers.add(LayerImage(full, l.depthRank, clip: panel));
      }
    }
    return layers;
  }

  /// 导出类入口（交互帧集 / 入场帧序列，见 `interaction.dart`）与渲染管线
  /// 共享的前置段：同一条降采样 + 深度 + 分层主干，保证导出帧与既有产物
  /// 同源（工作分辨率、分层口径完全一致）。
  (RgbaImage, List<LayerImage>) downscaleAndSplitForExport(RgbaImage src) =>
      _downscaleAndSplit(src, config.maxDimension);

  /// 导出类入口专用的降采样段（入场帧序列用：入场是整页效果，不做分层，
  /// 跳过深度估算与切层的开销）。降采样算法口径与 [_downscaleAndSplit]
  /// 完全一致（legacy 双线性 / standard+ 面积平均）。
  RgbaImage downscaleForExport(RgbaImage src) =>
      config.quality.tier.atLeastStandard
          ? boxDownscale(src, config.maxDimension)
          : _downscaleTo(src, config.maxDimension);

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

/// APNG rect 差分（W3）：两帧 RGBA 逐字节比较，返回变化的包围矩形
/// （相对全画布，含右下边界）；无变化返回 0 尺寸矩形。引擎帧渲染是
/// 确定性纯函数，无压缩噪声，逐字节比较安全。O(宽×高) 每帧。
PixelRect _diffRect(Uint8List prev, Uint8List cur, int width, int height) {
  var minX = width, minY = height, maxX = -1, maxY = -1;
  for (var y = 0; y < height; y++) {
    final rowBase = y * width * 4;
    for (var x = 0; x < width; x++) {
      final b = rowBase + x * 4;
      if (prev[b] != cur[b] ||
          prev[b + 1] != cur[b + 1] ||
          prev[b + 2] != cur[b + 2] ||
          prev[b + 3] != cur[b + 3]) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return const PixelRect(0, 0, 0, 0);
  return PixelRect(minX, minY, maxX - minX + 1, maxY - minY + 1);
}
