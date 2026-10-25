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
import 'motion_gate.dart';
import 'motion_pack.dart';
import 'motion_program.dart';
import 'render/camera.dart';
import 'image_io.dart';
import 'image_model.dart';
import 'anchor_sidecar.dart';
import 'part_motion.dart';
import 'render/resampler.dart';
import 'saliency_anchors.dart';
import 'scene_motion.dart';
import 'scene_sidecar.dart';
import 'subject_segmenter.dart';
import 'text_sharp.dart';
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
    this.partMotionDigest,
    this.anchorsDigest,
    this.sceneDigest,
    this.staticPassthrough = false,
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

  /// 侧车 `part_motion.json` 的文本指纹（Plan B Task 6）。null = 本次未给部件。
  /// 与 [contentHash] 同类的**运行期**指纹：它改变像素但不进 configHash，
  /// 所以台账/产物目录必须单独记它一笔，否则「同图同配置、只换侧车」的两次
  /// 渲染会被当成同一缓存。执行期属性，不参与 configHash。
  final String? partMotionDigest;

  /// 侧车 `anchors.json` 的文本指纹（X3）。语义同 [partMotionDigest]：
  /// 运行期指纹，改变落位但不进 configHash。null = 未给侧车。
  final String? anchorsDigest;

  /// 侧车 `scene.json` 的文本指纹（v1.9 动效画面判断）。语义同
  /// [anchorsDigest]：运行期指纹，改变视差幅度但不进 configHash。
  /// null = 未给侧车。
  final String? sceneDigest;

  /// `includeFirstFrame: true` 时的首帧 PNG（Uint8List），未请求为 null。
  /// 与 GIF 首帧同源（同一渲染帧：GIF 里的副本经调色板量化），字节与
  /// `frames/frame_0000.png` 完全一致。执行期产物，不进 [toJson]。
  final Uint8List? firstFramePng;

  /// 静态原图直通（[MotionPipeline.staticPassthrough]）：true = 本次内容
  /// 判静，未写任何产物（outputGif/frameDir/paramsFile 皆为空串），调用方
  /// 直接使用原始输入即可。执行期属性，不参与 configHash。
  final bool staticPassthrough;

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
        if (partMotionDigest != null) 'partMotionDigest': partMotionDigest,
        if (anchorsDigest != null) 'anchorsDigest': anchorsDigest,
        if (sceneDigest != null) 'sceneDigest': sceneDigest,
        if (staticPassthrough) 'staticPassthrough': true,
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
    this.partMotionDigest,
    this.anchorsDigest,
    this.sceneDigest,
    this.staticPassthroughBytes,
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

  /// 侧车 `part_motion.json` 文本指纹（语义同 [PipelineResult.partMotionDigest]）。
  final String? partMotionDigest;

  /// 侧车 `anchors.json` 文本指纹（X3，语义同 [PipelineResult.anchorsDigest]）。
  final String? anchorsDigest;

  /// 侧车 `scene.json` 文本指纹（v1.9，语义同 [PipelineResult.sceneDigest]）。
  final String? sceneDigest;

  /// `includeFirstFrame: true` 时的首帧 PNG，未请求为 null（语义同
  /// [PipelineResult.firstFramePng]）。
  final Uint8List? firstFramePng;

  /// 静态原图直通（[MotionPipeline.staticPassthrough]）：内容判静时非
  /// null——**原始输入字节原样返回，未做任何修改**（无降采样/重编码/容器
  /// 封装）；此时 [gifBytes]/[apngBytes] 为 null、frameCount == 1。
  final Uint8List? staticPassthroughBytes;
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
    this.staticPassthrough = false,
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

  /// 静态原图直通（见 [MotionPipeline.staticPassthrough]）：无任何产物。
  final bool staticPassthrough;
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
    this.staticPassthrough = true,
    DepthEstimator? depthEstimator,
    SubjectSegmenter? subjectSegmenter,
    String? partMotion,
    SaliencyEstimator? saliencyEstimator,
    MotionGate? motionGate,
    String? anchors,
    PanelMotionJudge? panelMotionJudge,
    PanelStrategyJudge? panelStrategyJudge,
    String? scene,
  }) : _parallel = parallel ??
            math.min(
                kDefaultParallel, math.max(1, io.Platform.numberOfProcessors)),
        _depthEstimator = depthEstimator,
        _subjectSegmenter = subjectSegmenter,
        _saliencyEstimator = saliencyEstimator,
        _motionGate = motionGate,
        _panelMotionJudge = panelMotionJudge,
        _panelStrategyJudge = panelStrategyJudge,
        partMotion = partMotion,
        anchors = anchors,
        scene = scene,
        _partParse = partMotion == null
            ? const PartMotionParse(null, [])
            : PartMotionParser.parse(partMotion),
        _anchorsParse = anchors == null
            ? const AnchorsParse(null, [])
            : AnchorsSpecParser.parse(anchors),
        _sceneParse = scene == null
            ? const SceneMotionParse(null, [])
            : SceneMotionParser.parse(scene);

  /// 深度估算器注入（W6）：null = 内置启发式（[HeuristicDepthEstimator]，
  /// 与接口化前像素输出逐字节一致）。执行期依赖，不参与 configHash。
  final DepthEstimator? _depthEstimator;

  /// 当前生效的估算器（注入优先，缺省启发式）。
  DepthEstimator get effectiveDepthEstimator =>
      _depthEstimator ?? const HeuristicDepthEstimator();

  /// 主体分割器注入（Phase D）：null = 不分割（既有路径逐字节零变化）。
  /// 执行期依赖，不参与 configHash。注入后逐格（多格页）/整页（单格页）
  /// 分割主体并 [clampSubjectDepth] 钳制深度——人物整体落入单一深度带，
  /// 根除骑跨深度带的割裂感。分割器契约「永不抛」（失败返回空掩码 ⇒
  /// 不钳制，渲染回落既有行为）。见 [SubjectSegmenter]。
  final SubjectSegmenter? _subjectSegmenter;

  /// 当前生效的主体分割器（注入优先，缺省 null = 通道关闭）。
  SubjectSegmenter? get effectiveSubjectSegmenter => _subjectSegmenter;

  /// 三期 AI 侧车的 `part_motion.json` **原文**（Plan B Task 6）。运行期输入，
  /// 与 [depthEstimator] 同级：它改变像素，但**不进** [EffectConfig]、不参与
  /// configHash（否则每次换侧车都打破哈希基线）。null = 不启用，既有路径逐
  /// 字节零变化。
  ///
  /// 不在 EffectConfig 里表达「部件来自哪里」，是因为部件与**这一张图**绑定
  /// （多边形是归一化坐标，换图就没意义），而配置是可跨图复用的。
  ///
  /// 构造期即解析（[PartMotionParser] 永不抛：坏 JSON ⇒ 空部件 + warning）。
  /// 注意：`processStrip`（条漫切片）与 [BatchRunner] 不携带本参数——切片后
  /// 归一化坐标指向的是切片而非整页，套用会错位；批处理里一份侧车也不可能
  /// 对应整目录的图。两者都不接这条通道。
  final String? partMotion;
  final PartMotionParse _partParse;

  /// 本次生效的部件（未实现的 kind 由渲染侧再过滤；空表 = 一个像素都不动）。
  List<PartMotion> get effectiveParts => _partParse.spec?.parts ?? const [];

  /// 侧车解析告警。冒泡路径：[PipelineResult.warnings] → 台账 → HTTP 回显 → CLI。
  List<String> get partWarnings => _partParse.warnings;

  /// 侧车文本指纹（8 位十六进制，与 [ImageIO.contentHash8] 同算法、同口径）。
  ///
  /// 必须单独存在：部件是运行期输入（不进 configHash），但它改变像素——
  /// 「同图、同配置、只换 part_motion.json」的两次渲染若共用产物目录名，
  /// 嵌入方的「目录存在即跳过」缓存就会命中旧画面。[processFile] /
  /// [processImage] 在非空时把它追加到目录名末尾正是为此。
  String? get partMotionDigest => partMotion == null
      ? null
      : ImageIO.contentHash8(convert.utf8.encode(partMotion!));

  /// 产物目录后缀：未给侧车时是空串（既有命名逐字节不变），给了就是
  /// `_<digest>`。见 [partMotionDigest] 的缓存撞名论证。
  String get partsDirTag => partMotionDigest == null ? '' : '_$partMotionDigest';

  /// 显著性估算器注入（X3）：null = 内置启发式（[SaliencyAnalyzer]，与接口
  /// 化前像素输出逐字节一致）。执行期依赖，不参与 configHash。
  final SaliencyEstimator? _saliencyEstimator;

  /// 动效门槛注入（v1.8）：null = 永远动画（既有路径逐字节零变化）。
  /// 执行期依赖，不参与 configHash。深度平坦页输出单帧静态图（与
  /// reducedMotion 同形态）。见 [MotionGate]。
  final MotionGate? _motionGate;

  /// 格级动效画面判断注入（v1.9）：null = 不判断（该通道整体关闭，既有
  /// 路径逐字节零变化）。执行期依赖，不参与 configHash。与 [scene] 侧车
  /// 的优先级：侧车命中的格用侧车幅度，未命中格回落本判断器；两者皆缺省
  /// 时通道关闭。见 [PanelMotionJudge]。
  final PanelMotionJudge? _panelMotionJudge;

  /// 画面自适应策略判断注入（Phase E）：null = 不判断（回落 panelMotionJudge/
  /// scene 侧车/默认档）。执行期依赖，不参与 configHash。优先级低于
  /// scene 侧车命中格、高于 [PanelMotionJudge]（可表达 tempo/subjectBoost）。
  /// 见 [PanelStrategyJudge]。
  final PanelStrategyJudge? _panelStrategyJudge;

  /// 当前生效的策略判断器。
  PanelStrategyJudge? get effectivePanelStrategyJudge => _panelStrategyJudge;

  /// `anchors.json` 侧车**原文**（X3）：外部 AI 显著性/焦点识别的页级数据。
  /// 运行期输入，与 [partMotion] 同级：改变落位与焦点，但不进 EffectConfig、
  /// 不参与 configHash。null = 不启用，既有路径逐字节零变化。
  ///
  /// 优先级：本侧车 > saliencyEstimator 注入 > 内置启发式——侧车是逐页
  /// 数据，比可复用的估算器更具体。侧车与**这一张图**绑定（归一化坐标换图
  /// 即失效），因此 [BatchRunner] 与 `processStrip` 与部件侧车同一理由**不
  /// 接**这条通道。
  final String? anchors;
  final AnchorsParse _anchorsParse;

  /// 本次生效的 anchors 侧车（未给或解析失败为 null）。
  AnchorsSpec? get effectiveAnchors => _anchorsParse.spec;

  /// 侧车解析告警。冒泡路径与 [partWarnings] 相同。
  List<String> get anchorsWarnings => _anchorsParse.warnings;

  /// 侧车文本指纹（8 位十六进制，与 [ImageIO.contentHash8] 同算法）。
  /// 语义同 [partMotionDigest]：运行期输入改变像素但不进 configHash，
  /// 产物目录必须单独记一笔，否则「同图同配置、只换侧车」会命中旧缓存。
  String? get anchorsDigest => anchors == null
      ? null
      : ImageIO.contentHash8(convert.utf8.encode(anchors!));

  /// 产物目录后缀（X3）：未给侧车时是空串（既有命名逐字节不变）。
  String get anchorsDirTag => anchorsDigest == null ? '' : '_${anchorsDigest}';

  /// `scene.json` 侧车**原文**（v1.9 动效画面判断）：外部 AI/宿主的逐格
  /// 幅度裁决。运行期输入，与 [anchors] 同级：改变视差幅度，但不进
  /// [EffectConfig]、不参与 configHash。null = 不启用，既有路径逐字节零
  /// 变化。与 [panelMotionJudge] 的优先级：侧车按像素空间 IoU 匹配检测格，
  /// 命中格以侧车为准，未命中格回落判断器（无判断器则满幅）。
  ///
  /// 侧车与**这一张图**绑定（归一化坐标换图即失效），因此 [BatchRunner] 与
  /// `processStrip` 与 anchors 侧车同一理由**不接**这条通道。
  final String? scene;
  final SceneMotionParse _sceneParse;

  /// 本次生效的 scene 侧车（未给或解析失败为 null）。
  SceneMotionSpec? get effectiveScene => _sceneParse.spec;

  /// 侧车解析告警。冒泡路径与 [partWarnings] 相同。
  List<String> get sceneWarnings => _sceneParse.warnings;

  /// 侧车文本指纹（8 位十六进制，与 [ImageIO.contentHash8] 同算法）。
  /// 语义同 [anchorsDigest]：运行期输入改变像素但不进 configHash，
  /// 产物目录必须单独记一笔，否则「同图同配置、只换侧车」会命中旧缓存。
  String? get sceneDigest => scene == null
      ? null
      : ImageIO.contentHash8(convert.utf8.encode(scene!));

  /// 产物目录后缀：未给侧车时是空串（既有命名逐字节不变）。
  String get sceneDirTag => sceneDigest == null ? '' : '_${sceneDigest}';

  /// 主体分割缓存隔离后缀（Phase D）：未注入分割器时是空串（既有命名
  /// 逐字节不变）；注入时为 `_s_<cacheTag>`（cacheTag 经 [0-9A-Za-z_-]
  /// 白名单清洗，其余字符替换 `_`）。分割改变层结构（改变像素）但不进
  /// configHash——与 [sceneDirTag] 同一缓存撞名论证：嵌入方「目录存在
  /// 即跳过」的缓存不能命中换了分割模型的旧画面。
  String get subjectDirTag {
    final seg = _subjectSegmenter;
    if (seg == null) return '';
    final raw = seg.cacheTag;
    if (raw.isEmpty) return '_s';
    final sb = StringBuffer();
    for (final ch in raw.runes) {
      final ok = (ch >= 0x30 && ch <= 0x39) ||
          (ch >= 0x41 && ch <= 0x5A) ||
          (ch >= 0x61 && ch <= 0x7A) ||
          ch == 0x2D ||
          ch == 0x5F;
      sb.write(ok ? String.fromCharCode(ch) : '_');
    }
    return '_s_$sb';
  }

  /// 格级动效画面判断（v1.9，注入见 ctor）。缺省 null + 侧车也缺省 = 通道
  /// 关闭。判断结果不落任何字段——逐次渲染现算（纯函数，同输入同输出）。
  PanelMotionJudge? get effectivePanelMotionJudge => _panelMotionJudge;

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

  /// 静态页原图直通（用户裁决 2026-10-24）：内容判静（motion gate / 全格
  /// 判静）时**不做任何像素修改，直接返回原始输入**——内存模式
  /// [MemoryPipelineResult.staticPassthroughBytes] 携带原字节、gifBytes 为
  /// null；磁盘模式不写任何产物。跳过探针/帧渲染/容器编码（省全部渲染时
  /// 间）。reducedMotion（配置强制单帧）不走直通——那是显式配置产物。
  /// false = 恢复旧的「1 帧重编码 GIF」形态。执行期参数，不进 configHash。
  final bool staticPassthrough;

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
        '${baseName}_${contentHash}_${config.configHash.substring(0, 8)}'
        '${partsDirTag}${anchorsDirTag}${sceneDirTag}${subjectDirTag}';

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
      partMotionDigest: partMotionDigest,
      anchorsDigest: anchorsDigest,
      sceneDigest: sceneDigest,
      staticPassthrough: core.staticPassthrough,
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
        '${baseName}_${contentHash}_${config.configHash.substring(0, 8)}'
        '${partsDirTag}${anchorsDirTag}${sceneDirTag}${subjectDirTag}';
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
      partMotionDigest: partMotionDigest,
      anchorsDigest: anchorsDigest,
      sceneDigest: sceneDigest,
      staticPassthrough: core.staticPassthrough,
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
      partMotionDigest: partMotionDigest,
      anchorsDigest: anchorsDigest,
      sceneDigest: sceneDigest,
      staticPassthroughBytes: core.staticPassthrough ? input : null,
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
    final (working, layers, anchors, _, panels, subjects) =
        _downscaleAndSplit(src, config.maxDimension);
    _checkStillCancel(deadline, 'before render');
    // 画面自适应（Phase E）：静帧与全量渲染同源，格级策略在此同样生效。
    final subjectLayers = _subjectLayerFlagsFor(subjects, layers, panels);
    final (scales, tempos) =
        _layerStrategyFor(working, panels, layers, subjects, subjectLayers);
    // text sharp（v1.10）：静帧与全量渲染同一掩码口径。
    final textSnapMask =
        config.quality.textSharp && config.quality.tier.atLeastStandard
            ? detectTextSnapMask(working)
            : null;
    final frame = FrameCompositor(
            layers,
            _inpaintBase(working, subjects, panels),
            config,
            anchors: anchors,
            parts: effectiveParts,
            layerMotionScales: scales,
            layerTempoScales: tempos,
            textSnapMask: textSnapMask,
            layerPhaseOffsets: (subjectLayers != null &&
                    subjectLayers.any((f) => f))
                ? [
                    for (var li = 0; li < layers.length; li++)
                      subjectLayers[li] ? -math.pi : 0.0,
                  ]
                : null)
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
    final (working, layers, anchors, depths, panels, subjects) =
        _downscaleAndSplit(src, effectiveMaxDim);
    // D6 底图主体带补绘：主体让出的条带显示延续的背景而非原位幽灵像
    // （双边缘根除）。分割器未注入/无主体时原样返回 working（零成本）。
    final compositorBase = _inpaintBase(working, subjects, panels);

    // 动效门槛（v1.8）：深度平坦 → 输出与 reducedMotion 同形态的单帧静态图。
    // 实现 = 把帧数钳到 1：探针段只剩帧 0、派工 pendingCount 自然归零、
    // 进度/回调按 1 帧走，既有单帧机制零新路径。hold 对单帧无意义，跳过。
    final gateWarnings = <String>[];
    var n = config.frameCount;
    var motionSuppressed = false;
    final gate = _motionGate;
    if (gate != null && n > 1) {
      checkCancel(); // 门槛评估前检查（深度已就绪）
      if (!gate.shouldAnimate(working, depths)) {
        n = 1;
        motionSuppressed = true;
        gateWarnings
            .add('motion gate: depth too flat, rendered static frame');
      }
    }

    // 画面自适应（Phase E）+ 格级判断（v1.9）：策略裁决（scene 侧车 >
    // strategyJudge > panelMotionJudge）→ 逐层幅度乘数（scale × 主体层
    // subjectBoost）与节奏乘数（同格统一）。全部层判静时整页退化为单帧
    // （与 motion gate 同形态）。通道关闭时 lms == null，零变化。
    List<double>? layerMotionScales;
    List<double>? layerTempoScales;
    List<bool>? subjectLayers;
    List<double>? layerPhaseOffsets;
    if (!motionSuppressed && n > 1) {
      checkCancel(); // 判断评估前检查
      subjectLayers = _subjectLayerFlagsFor(subjects, layers, panels);
      if (subjectLayers != null && subjectLayers.any((f) => f)) {
        // D6 主体层相位跟随：主体层 −π → 与相邻背景带同相（随动+领跑）。
        layerPhaseOffsets = [
          for (var li = 0; li < layers.length; li++)
            subjectLayers[li] ? -math.pi : 0.0,
        ];
      }
      final (scales, tempos) =
          _layerStrategyFor(working, panels, layers, subjects, subjectLayers);
      if (scales != null) {
        if (scales.every((s) => s <= 1e-6)) {
          n = 1;
          motionSuppressed = true;
          gateWarnings.add(
              'scene gate: all panels judged static, rendered static frame');
        } else {
          layerMotionScales = scales;
          layerTempoScales = tempos;
        }
      }
    }

    // 静态原图直通（用户裁决 2026-10-24）：内容判静 → 不做任何像素修改，
    // 直接返回原始输入。跳过 depthSpreadScale/探针/帧渲染/容器编码（渲染
    // 段零成本）；frameCount 报 1（语义「一张静图」）。reducedMotion 不在
    // 此列（配置强制单帧是显式选择，保持 1 帧重编码形态）。
    if (motionSuppressed && staticPassthrough) {
      return _CoreOutput(
        gifBytes: null,
        paramsJson: config.toJsonString(),
        gifPath: '',
        frameDir: '',
        paramsFile: '',
        firstFramePng: null,
        layerCount: layers.length,
        frameCount: 1,
        parallel: 1,
        parallelFallback: false,
        warnings: [
          ...config.warnings,
          ...partWarnings,
          ...anchorsWarnings,
          ...sceneWarnings,
          ...budgetWarnings,
          ...gateWarnings,
        ],
        staticPassthrough: true,
      );
    }

    // 文字保真（text sharp v1.10）：`quality.textSharp` 开启（standard+ 档，
    // legacy 冻结不接）时对工作分辨率底图检测文字笔画区域（位打包掩码）。
    // 掩码命中像素在层贴图时整数取整采样——视差/呼吸的分数位移不再对文字
    // 做插值（半像素混合是文字发虚的直接根源）。同时启用静息归零波形
    // （[restSnapWave]）：t=0 静息帧/hold 帧位移精确 0，首帧 = 原画。null =
    // 无文字样区域或通道关闭（零成本、零变化）。放在静态直通之后——判静页
    // 不渲染，不付检测成本。
    Uint8List? textSnapMask;
    if (config.quality.textSharp && config.quality.tier.atLeastStandard) {
      textSnapMask = detectTextSnapMask(working);
    }

    // Frames: stream-render -> quantize -> LZW -> discard (O(one frame) RAM).
    // 深度自适应幅度（v1.9）：仅恒值场（ML/区域一致深度）生效——内置
    // 启发式深度是 min-max 归一化的平滑场（constantValued 恒为 false），
    // scale 恒为 1.0，默认路径逐字节不变。多格取最浅格：跨格幅度一致性
    // 由 _mult 归一负责，整体幅度以最保守格为准，宁可少动不可串格。
    var depthSpreadScale = 1.0;
    if (!motionSuppressed &&
        depths.isNotEmpty &&
        depths.first.constantValued) {
      final s = depths.map(depthSpread).reduce(math.min);
      depthSpreadScale = (s / kDepthSpreadRef).clamp(0.0, 1.0);
    }
    final compositor = FrameCompositor(layers, compositorBase, config,
        anchors: anchors,
        parts: effectiveParts,
        depthSpreadScale: depthSpreadScale,
        layerMotionScales: layerMotionScales,
        layerPhaseOffsets: layerPhaseOffsets,
        layerTempoScales: layerTempoScales,
        textSnapMask: textSnapMask);

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

    // rect 帧间差分（T5，opt-in）：worker 回传量化索引图，差分 + LZW 在主
    // isolate 按帧序做（差分状态在构建器内）。none 模式路径零改动。
    // APNG rect 差分（W3）：同一 opt-in 开关下的另一容器路径——worker 回传
    // 整帧 RGBA，主 isolate 逐字节差分出变化矩形，区域帧进 APNG 容器。
    final rectMode = gif != null && config.encoding.diffMode == 'rect';
    final apngRect =
        wantApng && !wantGif && config.encoding.diffMode == 'rect';
    // 调色板探针必须在派工之前定板（worker 只共享板，不建板）。
    // legacy = v1.2 的「首帧建板」；standard+ = 六帧均匀探针（v1.4 R27，
    // 原首/中/末三帧），避免只在中间帧出现的动效亮色挤不进 256 色。
    // renderFrame 是 t 的纯函数，乱序预渲染安全；探针下标由纯函数
    // paletteProbeIndices 给出、经插入序 Map 去重 ⇒ primePalette 入参确定。
    final presolved = <int, FrameOutput>{};
    RgbaImage? firstFrameRgba;
    // v1.6 静息保持（EffectConfig.holdSec > 0）：t=0 静息帧，容器收尾时
    // 以 holdSec 延迟追加（复用探针/预渲染的同一份栅格，零额外渲染成本）。
    RgbaImage? restFrame;
    if (gif != null) {
      final probes = <int, RgbaImage>{};
      checkCancel(); // 探针帧渲染前检查
      for (final k in gif.wantsProbes ? paletteProbeIndices(n) : const [0]) {
        checkCancel();
        final frame =
            probes.putIfAbsent(k, () => compositor.renderFrame(k / config.fps));
        if (wantFrames) ImageIO.writePngFrame(frameDir, k, frame);
      }
      // 首帧封面：直接复用探针帧 0 的同一份栅格，零额外渲染成本（T2）。
      if (includeFirstFrame) firstFrameRgba = probes[0];
      // 探针帧 0 即 t=0 静息帧（paletteProbeIndices 恒含 0），同一份栅格。
      if (config.holdSec > 0) restFrame = probes[0];
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
    } else if (includeFirstFrame || config.holdSec > 0) {
      // frames-only / apng 路径没有探针段：主 isolate 预渲染第 0 帧充当
      // 封面帧（includeFirstFrame）或静息保持帧（holdSec）并记入 presolved
      // （派工跳过该帧），与 GIF 路径一样只渲染一次。
      checkCancel(); // 探针帧渲染前检查
      firstFrameRgba = compositor.renderFrame(0);
      if (config.holdSec > 0) restFrame = firstFrameRgba;
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
      base: compositorBase,
      layers: layers,
      config: config,
      pngDir: wantFrames ? frameDir : null,
      gif: gif == null ? null : GifEncoderSpec.from(gif),
      // apng 容器需要每帧 PNG 字节回传（worker 侧编码一次，复用帧流通路）；
      // apng rect 模式容器改走 rgba 差分区域帧，全帧 PNG 只在 onFrame 需要时回传。
      wantPngBytes: onFrame != null || (wantApng && !apngRect),
      rectMode: rectMode,
      wantRgba: apngRect,
      anchors: anchors,
      parts: effectiveParts,
      layerMotionScales: layerMotionScales,
      layerPhaseOffsets: layerPhaseOffsets,
      layerTempoScales: layerTempoScales,
      textSnapMask: textSnapMask,
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
    // v1.6 静息保持（EffectConfig.holdSec）：全部动效帧出完后追加一帧 t=0
    // 静息帧，GIF GCE / APNG fcTL 延迟 = holdCs（厘秒，16 位上限 655.35s）。
    // 静息帧即首帧（rest 红线：与原画一致），保持段零动效、零撕裂；循环点
    // = 静息 → 动效起点（t=0 亦静息），无缝契约不破。rect 模式与动效帧同路
    // 差分：GIF 走 addHoldFrame（内部量化 + 差分矩形），APNG 与上一帧
    // RGBA 逐字节差分出区域帧——保持段体积最小化。帧数/进度/回调只统计
    // 动效帧，hold 不派工、不进 onFrame。reducedMotion 契约是「输出单帧
    // 静态图」，静息帧即其唯一帧，hold 追加跳过（两开关叠加以它为准）。
    if (config.holdSec > 0 &&
        !config.reducedMotion &&
        !motionSuppressed &&
        (gif != null || apng != null)) {
      final holdCs = (config.holdSec * 100).round().clamp(2, 65535);
      final rest = restFrame!;
      if (gif != null) {
        gif.addHoldFrame(rest, holdCs: holdCs);
      }
      if (apng != null) {
        if (apngRect) {
          final prev = apngPrev;
          if (prev == null) {
            apng.addFrame(rest, delayCs: holdCs);
          } else {
            apng.addRectFrame(rest,
                region: _diffRect(prev, rest.data, working.width, working.height),
                delayCs: holdCs);
          }
        } else {
          apng.addFrame(rest, delayCs: holdCs);
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
      warnings: [
      ...config.warnings,
      ...partWarnings,
      ...anchorsWarnings,
      ...sceneWarnings,
      ...budgetWarnings,
      ...gateWarnings,
    ],
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
  /// panelAware（W5，仅 autoLayers 路径）：白带分格检测（v1.5 X4 起为横向
  /// 行带 + 行带内纵向细分的两级检测）；多格图逐格
  /// 独立估算深度与分层（层写回全图坐标并携带格边界裁剪，合成时跨格串色
  /// 根除）；单格/无白带图自动回退整页分层（与 panelAware 关闭逐字节等价）。
  ///
  /// Task 1.5（plumb-only）→ 现况（Task 3.7 清单 #12 纠正）：contentAware 为
  /// true 时对底图跑一次 [SaliencyAnalyzer]（panelAware 检出多格时按格分析），
  /// 第三个返回值携带 [AnchorMap]；否则返回 null。
  /// **旧注释「额外产出一个当前无人消费的 map，故产物逐字节不变」自 3.6b/3.6c
  /// 起是主动失真**：默认配置（不写 contentAware 键 ⇒ true，R30/R36）下渲染
  /// 路径与两条导出路径都在读这张 map（`frame_compositor` 的落位、
  /// `interaction.dart:206` 的 R37 接线），产物字节随之改变。map 本身仍然是
  /// 可选产物（contentAware=false ⇒ null），但它已不是「无人消费」。
  ///
  /// 清单 #14（用户裁决＝「文档化为主干成本，不加旋钮」）：第三个返回值有
  /// 一条**故意丢弃** `.$3` 的臂——[downscaleAndSplitForExport]，其唯一生产
  /// 消费者是 `layer_export.dart:110`（图层导出不用 anchor）。它因此照常
  /// 付一次 saliency 扫描的代价。保留这个成本的理由：渲染与导出必须共用
  /// **同一条**降采样 + 深度 + 分层主干，否则 t=0 静帧、GIF 首帧与导出层图
  /// 不再同源（这正是本函数文档开头那条契约）；而「只为省一次扫描」新增的
  /// 开关是一个不改任何画面行为的序列化概念——旋钮成本高于扫描成本。
  /// 需要 anchor 的导出路径请直接走
  /// [downscaleSplitAnchorsForExport]（R37），不要经这条丢弃臂。
  /// 第六返回值 = 逐格主体掩码（Phase D，序与 [panels] 一致；分割器未注入
  /// 时空表 `const []`）。钳制已在分层前完成：主体域深度统一为域内中位数
  /// 并晋升恒值语义（人物整体单带、硬 membership、跳羽化），掩码本体随
  /// 元组带出供后续消费者（画面策略判断、探针）复用，避免重复推理。
  (RgbaImage, List<LayerImage>, AnchorMap?, List<DepthMap>, List<PixelRect>,
      List<SubjectMask>) _downscaleAndSplit(RgbaImage src, int effectiveMaxDim) {
    final working = config.quality.tier.atLeastStandard
        ? boxDownscale(src, effectiveMaxDim)
        : _downscaleTo(src, effectiveMaxDim);
    if (config.panelAware && config.depthMode == DepthMode.autoLayers) {
      final panels = const PanelSplitter().split(working);
      if (panels.length >= 2) {
        final (layers, depths, subjects) = _splitPerPanel(working, panels);
        return (
          working,
          layers,
          _analyzeAnchors(working, panels),
          depths,
          panels,
          subjects
        );
      }
    }
    final depth = effectiveDepthEstimator.estimate(working);
    final (mask, medians) = _segmentAndClamp(working, depth);
    final splitter = LayerSplitter(
      layerCount: config.layerCount,
      tier: config.quality.tier,
      edgeStretchPx: config.quality.edgeStretchPx,
    );
    return (
      working,
      splitter.split(working, depth,
          subjectMask: mask,
          subjectMedians: medians,
          subjectStretchPx: subjectBandPx(working.width)),
      _analyzeAnchors(working, null),
      [depth],
      // 单格路径：整页视作一个格（判断器对全页评估一次；v1.9 前调用方
      // 不消费第五元，语义不变）。
      [PixelRect(0, 0, working.width, working.height)],
      [mask]
    );
  }

  /// 主体边界带宽度（D5/D6 共用）：覆盖最大位移露出量所需的外扩/补绘
  /// 带宽 = ceil(amplitude·工作宽·1.3) + 4px 余量（1.3 盖相邻层反相的
  /// 相对位移翻倍），上限 48px。分割器未注入返回 0（通道关闭零成本）。
  int subjectBandPx(int workingWidth) {
    if (_subjectSegmenter == null) return 0;
    final bandPx =
        (config.parallax.amplitude * workingWidth * 1.3).ceil() + 4;
    return bandPx.clamp(0, 48);
  }

  /// 主体分割 + 深度钳制（Phase D）：未注入分割器返回空掩码（零成本、
  /// 既有行为）；注入时分割（契约「永不抛」）并钳制——返回逐 blob 中位
  /// 数表供 [LayerSplitter] 主体带覆盖使用，人物整体落入单一深度带。
  (SubjectMask, List<double?>) _segmentAndClamp(RgbaImage sub, DepthMap depth) {
    final seg = _subjectSegmenter;
    if (seg == null) {
      return (SubjectMask.empty(sub.width, sub.height), const []);
    }
    final mask = seg.segment(sub);
    final medians = clampSubjectDepth(depth, mask);
    return (mask, medians);
  }

  /// D6 底图主体带补绘：有主体时返回以背景延续色填充主体边界带的底图
  /// 副本（消双边缘）；无分割器/无主体原样返回 [working]（零成本）。
  RgbaImage _inpaintBase(
      RgbaImage working, List<SubjectMask> subjects, List<PixelRect> panels) {
    if (_subjectSegmenter == null) return working;
    return inpaintSubjectBands(
        working, subjects, panels, subjectBandPx(working.width));
  }

  /// 主体层检测（D6 相位跟随 / E1 主体增强共用）：blob 中心区域采样点在
  /// 该层 alpha>0 且 depthRank>0 → 该层含主体。无分割器/无主体层返回
  /// null（通道关闭）。
  List<bool>? _subjectLayerFlagsFor(List<SubjectMask> subjects,
      List<LayerImage> layers, List<PixelRect> panels) {
    if (_subjectSegmenter == null) return null;
    final flags = List<bool>.filled(layers.length, false);
    var any = false;
    for (var pi = 0; pi < subjects.length && pi < panels.length; pi++) {
      final mask = subjects[pi];
      if (!mask.hasSubjects) continue;
      final panel = panels[pi];
      for (final blob in mask.blobs) {
        // blob 中心十字采样：任一点落在某层即认定该层含主体。
        const fr = [
          (0.5, 0.5),
          (0.35, 0.5),
          (0.65, 0.5),
          (0.5, 0.35),
          (0.5, 0.65)
        ];
        for (final (fx, fy) in fr) {
          final mx = (blob.rect.x + blob.rect.width * fx)
              .round()
              .clamp(0, mask.width - 1);
          final my = (blob.rect.y + blob.rect.height * fy)
              .round()
              .clamp(0, mask.height - 1);
          if (mask.labelAt(mx, my) == 0) continue;
          final cx = panel.x +
              (mx * panel.width / mask.width).floor().clamp(0, panel.width - 1);
          final cy = panel.y +
              (my * panel.height / mask.height)
                  .floor()
                  .clamp(0, panel.height - 1);
          for (var li = 0; li < layers.length; li++) {
            if (layers[li].depthRank <= 0) continue;
            final clip = layers[li].clip;
            final belongs = clip == null
                ? panels.length == 1
                : (clip.x == panel.x &&
                    clip.y == panel.y &&
                    clip.width == panel.width &&
                    clip.height == panel.height);
            if (!belongs) continue;
            final img = layers[li].image;
            if (img.data[(cy * img.width + cx) * 4 + 3] > 0 && !flags[li]) {
              flags[li] = true;
              any = true;
            }
          }
        }
      }
    }
    return any ? flags : null;
  }

  /// 画面自适应/格级判断（v1.9 + Phase E）：逐格策略裁决。优先级：
  /// scene 侧车（命中格，含加性 tempo/subjectBoost）> [PanelStrategyJudge]
  /// 注入 > [PanelMotionJudge] 注入（适配为 scale-only）> 默认档。
  /// 三者皆缺省返回 null（通道关闭，零变化）。
  List<PanelMotionStrategy>? _panelStrategiesFor(RgbaImage working,
      List<PixelRect> panels, List<SubjectMask> subjects) {
    final spec = _sceneParse.spec;
    final strategyJudge = _panelStrategyJudge;
    final judge = _panelMotionJudge;
    if (spec == null && strategyJudge == null && judge == null) return null;
    final judgeScales =
        judge == null ? null : judge.panelScales(working, panels);
    final judgeStrategies = strategyJudge == null
        ? null
        : strategyJudge.panelStrategies(working, panels, subjects);
    return [
      for (var i = 0; i < panels.length; i++)
        _strategyForPanel(
            i,
            panels[i],
            working.width,
            working.height,
            spec,
            judgeStrategies,
            judgeScales?[i]),
    ];
  }

  PanelMotionStrategy _strategyForPanel(
      int index,
      PixelRect panel,
      int canvasW,
      int canvasH,
      SceneMotionSpec? spec,
      List<PanelMotionStrategy>? judgeStrategies,
      double? judgeScale) {
    final hit = spec?.panelFor(panel, canvasW, canvasH);
    if (hit != null) {
      return PanelMotionStrategy(
          scale: hit.scale, tempo: hit.tempo, subjectBoost: hit.subjectBoost);
    }
    if (judgeStrategies != null && index < judgeStrategies.length) {
      // 侧车未命中格回落策略判断器（序与 panels 对齐）。
      return judgeStrategies[index];
    }
    if (judgeScale != null) {
      return PanelMotionStrategy(scale: judgeScale);
    }
    return PanelMotionStrategy.neutral;
  }

  /// Phase E 策略 → 逐层 (幅度乘数, 节奏乘数)；null = 通道关闭。
  /// 幅度 = 格 scale ×（主体层 ? subjectBoost : 1）；节奏同格统一（防层间
  /// 相位漂移）；全 1 tempo 收敛为 null（通道零变化）。
  (List<double>?, List<double>?) _layerStrategyFor(
      RgbaImage working,
      List<PixelRect> panels,
      List<LayerImage> layers,
      List<SubjectMask> subjects,
      List<bool>? subjectLayers) {
    final strategies = _panelStrategiesFor(working, panels, subjects);
    if (strategies == null) return (null, null);
    final scales = <double>[];
    final tempos = <double>[];
    for (var li = 0; li < layers.length; li++) {
      final pi = _panelIndexForLayer(layers[li].clip, panels);
      final st = pi >= 0 && pi < strategies.length
          ? strategies[pi]
          : PanelMotionStrategy.neutral;
      final boosted = subjectLayers != null && subjectLayers[li]
          ? st.scale * st.subjectBoost
          : st.scale;
      scales.add(boosted.clamp(0.0, 2.0));
      tempos.add(st.tempo);
    }
    return (scales, tempos.every((t) => t == 1.0) ? null : tempos);
  }

  int _panelIndexForLayer(PixelRect? clip, List<PixelRect> panels) {
    if (clip == null) {
      return panels.length == 1 ? 0 : -1;
    }
    for (var i = 0; i < panels.length; i++) {
      final p = panels[i];
      if (p.x == clip.x &&
          p.y == clip.y &&
          p.width == clip.width &&
          p.height == clip.height) {
        return i;
      }
    }
    return -1;
  }

  /// contentAware 关闭 → null，零成本、零行为变化（3.6b/R30 后默认**开启**，
  /// 此分支仅剩显式 `contentAware: false` 回滚）；开启时按 [panels]
  /// （工作分辨率画布像素格，null = 整页）分析底图。
  AnchorMap? _analyzeAnchors(RgbaImage working, List<PixelRect>? panels) {
    if (!config.contentAware) return null;
    // X3 优先级：anchors 侧车 > 估算器注入 > 内置启发式。侧车是整页口径
    // （归一化坐标），panels 被忽略。
    final spec = _anchorsParse.spec;
    if (spec != null) {
      return spec.toAnchorMap(working.width, working.height);
    }
    return effectiveSaliencyEstimator.analyze(working, panels: panels);
  }

  /// 当前生效的显著性估算器（注入优先，缺省内置启发式；默认路径与接口化
  /// 前逐字节一致）。
  SaliencyEstimator get effectiveSaliencyEstimator =>
      _saliencyEstimator ?? const SaliencyAnalyzer();

  /// W5 分格感知：逐格裁剪子图 → 独立 DepthEstimator + LayerSplitter →
  /// 层内容写回全图尺寸透明画布（格区域），携带格内 rank 与格边界裁剪。
  /// 层序列 = 格序 × 格内 rank 序（合成器按 rank 归一视差倍率，跨格一致）。
  /// 第二返回值 = 逐格深度图（序与层生成的格序一致；v1.8 动效门槛消费）。
  /// 第三返回值 = 逐格主体掩码（Phase D，序与 panels 一致；未注入分割器
  /// 时为逐格空掩码）。
  (List<LayerImage>, List<DepthMap>, List<SubjectMask>) _splitPerPanel(
      RgbaImage working, List<PixelRect> panels) {
    final layers = <LayerImage>[];
    final depths = <DepthMap>[];
    final subjects = <SubjectMask>[];
    final bandPx = subjectBandPx(working.width);
    for (final panel in panels) {
      // 裁剪子图（逐行拷贝）。
      final sub = RgbaImage(width: panel.width, height: panel.height);
      for (var y = 0; y < panel.height; y++) {
        final srcBase = ((panel.y + y) * working.width + panel.x) * 4;
        sub.data.setRange(y * panel.width * 4, (y + 1) * panel.width * 4,
            working.data, srcBase);
      }
      final depth = effectiveDepthEstimator.estimate(sub);
      final (mask, medians) = _segmentAndClamp(sub, depth);
      subjects.add(mask);
      depths.add(depth);
      final splitter = LayerSplitter(
        layerCount: config.layerCount,
        tier: config.quality.tier,
        edgeStretchPx: config.quality.edgeStretchPx,
      );
      for (final l in splitter.split(sub, depth,
          subjectMask: mask,
          subjectMedians: medians,
          subjectStretchPx: bandPx)) {
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
    return (layers, depths, subjects);
  }

  /// 导出类入口（交互帧集 / 入场帧序列，见 `interaction.dart`）与渲染管线
  /// 共享的前置段：同一条降采样 + 深度 + 分层主干，保证导出帧与既有产物
  /// 同源（工作分辨率、分层口径完全一致）。本签名不含 [AnchorMap]；
  /// 需要在主 isolate 自建 `FrameCompositor` 的导出路径请改用
  /// [downscaleSplitAnchorsForExport]（R37）。
  (RgbaImage, List<LayerImage>) downscaleAndSplitForExport(RgbaImage src) {
    final (working, layers, _) = downscaleSplitAnchorsForExport(src);
    return (working, layers);
  }

  /// 与 [downscaleAndSplitForExport] 同一条降采样 + 分层主干，但**保留**
  /// `_downscaleAndSplit` 派生的 [AnchorMap]：任何要在主 isolate 自建
  /// `FrameCompositor` 的导出路径必须走这里，否则 contentAware 默认开启后
  /// 同一 config 在渲染路径与导出路径会落位不一致（R37）。
  (RgbaImage, List<LayerImage>, AnchorMap?) downscaleSplitAnchorsForExport(
      RgbaImage src) {
    final (working, layers, anchors, _, _, _) =
        _downscaleAndSplit(src, config.maxDimension);
    return (working, layers, anchors);
  }

  /// 导出类入口专用的降采样段（入场帧序列用：入场是整页效果，不做分层，
  /// 跳过深度估算与切层的开销）。降采样算法口径与 [_downscaleAndSplit]
  /// 完全一致（legacy 双线性 / standard+ 面积平均）。
  RgbaImage downscaleForExport(RgbaImage src) =>
      config.quality.tier.atLeastStandard
          ? boxDownscale(src, config.maxDimension)
          : _downscaleTo(src, config.maxDimension);

  /// MotionPack 分析入口（重构方案 M2，`motion_pack.dart` 消费）：与渲染
  /// 主干同一条降采样 + 深度 + 分层路径（导出与渲染同源契约），一次性带出
  /// pack 全部原料——工作栅格、层、锚点、逐格深度、格矩形、主体掩码、
  /// 逐格诊断（内置启发式判定路径）与**已裁决**策略（scene 侧车 > 注入
  /// 判断器 > 内置启发式，优先级与渲染一致）。纯分析，不渲染、不落盘。
  PackAnalysis analyzeForPack(RgbaImage src) {
    final (working, layers, anchors, depths, panels, subjects) =
        _downscaleAndSplit(src, config.maxDimension);
    final subjectLayers = _subjectLayerFlagsFor(subjects, layers, panels);
    final resolved = _panelStrategiesFor(working, panels, subjects) ??
        [
          for (var i = 0; i < panels.length; i++) PanelMotionStrategy.neutral,
        ];
    // pack v1 诊断固定走内置启发式（分域分布定值路径）；外部判断器只经
    // [resolved] 的策略优先级生效（其 cls 语义随 tier3 分类器另接）。
    const heuristicJudge = HeuristicSceneStrategyJudge();
    final diagnoses = heuristicJudge.diagnose(working, panels, subjects);
    return PackAnalysis(
      working: working,
      layers: layers,
      anchors: anchors,
      depths: depths,
      panels: panels,
      subjects: subjects,
      diagnoses: diagnoses,
      strategies: resolved,
      subjectLayers: subjectLayers,
    );
  }

  /// pack 程序消费的静帧（§7.2 导出路径形态）：与 [_renderStill] 同一条
  /// 主干 + 逐格镜头 pass（`render/camera.dart`）。t=0 静息帧与无镜头静帧
  /// **逐字节一致**（首帧对拍契约——镜头程序在 t=0 恒等跳过，测试锁定）。
  Uint8List renderPackStillFrame({required Uint8List input, double t = 0}) {
    final src = ImageIO.decode(input);
    final analysis = analyzeForPack(src);
    final programs = buildPackPrograms(analysis);
    final working = analysis.working;
    final subjectLayers = analysis.subjectLayers;
    final (scales, tempos) = _layerStrategyFor(
        working, analysis.panels, analysis.layers, analysis.subjects,
        subjectLayers);
    final textSnapMask =
        config.quality.textSharp && config.quality.tier.atLeastStandard
            ? detectTextSnapMask(working)
            : null;
    final regions = <CameraRegion>[];
    for (var i = 0; i < analysis.panels.length && i < programs.length; i++) {
      if (programs[i].camera.type != CameraType.none) {
        regions.add(CameraRegion(rect: analysis.panels[i], program: programs[i]));
      }
    }
    final frame = FrameCompositor(
            analysis.layers,
            _inpaintBase(working, analysis.subjects, analysis.panels),
            config,
            anchors: analysis.anchors,
            parts: effectiveParts,
            layerMotionScales: scales,
            layerTempoScales: tempos,
            textSnapMask: textSnapMask,
            layerPhaseOffsets:
                (subjectLayers != null && subjectLayers.any((f) => f))
                    ? [
                        for (var li = 0; li < analysis.layers.length; li++)
                          subjectLayers[li] ? -math.pi : 0.0,
                      ]
                    : null,
            cameraRegions: regions.isEmpty ? null : regions)
        .renderFrame(math.max(0.0, t));
    return Uint8List.fromList(ImageIO.encodePngFrame(frame));
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

/// MotionPack 分析包（`analyzeForPack` 产物）：渲染主干一次走完后的全部
/// pack 原料。诊断/策略/掩码与 panels 对齐；depths 与分层格序一致
/// （单格路径恰一个元素）。
class PackAnalysis {
  PackAnalysis({
    required this.working,
    required this.layers,
    required this.anchors,
    required this.depths,
    required this.panels,
    required this.subjects,
    required this.diagnoses,
    required this.strategies,
    required this.subjectLayers,
  });

  /// 工作分辨率栅格（pack 的 sourceDigest 与栅格指纹同源）。
  final RgbaImage working;
  final List<LayerImage> layers;
  final AnchorMap? anchors;
  final List<DepthMap> depths;
  final List<PixelRect> panels;
  final List<SubjectMask> subjects;

  /// 逐格诊断（内置启发式判定路径；序与 [panels] 一致）。
  final List<PanelDiagnosis> diagnoses;

  /// 已裁决策略（scene 侧车 > 注入判断器 > 内置启发式；序与 [panels] 一致）。
  final List<PanelMotionStrategy> strategies;

  /// 主体层标记（null = 分割器未注入/无主体层）。
  final List<bool>? subjectLayers;
}
