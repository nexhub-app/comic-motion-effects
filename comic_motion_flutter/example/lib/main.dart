// comic_motion_flutter 用法示例。
//
// 「准备产物」（终端里跑一次，核心包 CLI）：
//   dart run comic_motion_server:render -i input.png -o build/demo
//   dart run comic_motion_server:export-interaction -i input.png -o build/demo_pan
// 把导出目录拷到 example/assets/ 下（见 example/pubspec.yaml 注释），
// 再 flutter run。
//
// 无产物时本示例仍可运行：加载失败会显示错误占位并给出接线指引。
//
// 「端侧深度渲染」为机器本地演示：ONNX 模型与样本页从仓库 build/ 探针目录
// 读取（gitignored，本机放置），缺文件时优雅降级为 SnackBar 提示。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_depth_onnx/comic_motion_depth_onnx.dart';
import 'package:comic_motion_flutter/comic_motion_flutter.dart';
import 'package:comic_motion_flutter/reader.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

/// 与 example/pubspec.yaml 的 assets 注释对应的目录约定。
const String _kGifDir = 'assets/demo'; // 全量渲染产物目录（stem: demo）
const String _kPanDir = 'assets/demo_pan'; // 交互帧集目录（stem: demo_pan）

/// 端侧深度演示（机器本地，gitignored）：QDQ int8 MiDaS 模型 + 样本页。
const String _qdqModelPath =
    r'..\..\..\build\depth_probe\models\midas_v21_small_256_qdq.onnx';
const String _samplePagePath =
    r'..\..\..\build\depth_probe\pages\c01_p001.jpg';

/// 主体分割演示（机器本地，gitignored）：fp32 u2netp（4.6MB，Phase D）。
const String _segModelPath =
    r'..\..\..\build\depth_probe\models\u2netp.onnx';

/// CLIP 面板分类器演示（机器本地，gitignored）：ViT-B/32 fp32 图像塔 +
/// 预计算提示词嵌入（存在即启用，缺失降级纯启发式）。探针结论：该模型
/// 在漫画域置信边界 ~0.007（低于覆盖门槛 0.02）→ 安全无操作，仅为
/// 链路演示；生产需漫画域模型。
const String _clipModelPath =
    r'..\..\..\build\depth_probe\models\clip_vision.onnx';
const String _clipPromptsPath =
    r'..\..\..\build\depth_probe\models\clip_prompt_embeddings.json';

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'comic_motion_flutter example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ExamplePage(),
    );
  }
}

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  Uint8List? _gif;
  Uint8List? _firstFrame;
  List<Uint8List>? _entrance;
  InteractionFrameSet? _panFrames;
  String? _error;
  bool _playing = true;
  PageMotionMode _motionMode = PageMotionMode.always;
  bool _depthBusy = false;
  MemoryPipelineResult? _depthResult;
  bool _sceneBusy = false;
  MemoryPipelineResult? _sceneResult;
  bool _segBusy = false;
  MemoryPipelineResult? _segResult;
  bool _fullBusy = false;
  MemoryPipelineResult? _fullResult;

  @override
  void initState() {
    super.initState();
    // DefaultAssetBundle 需要 context，延后到首帧之后。
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final gif = await _asset('$_kGifDir/anim.gif');
      final first = await _asset('$_kGifDir/first_frame.png');
      // 入场帧序列（可选）：V2 导出的 anim.entrance/frame_NNNN.png。
      final entrance = <Uint8List>[];
      for (var i = 0; i < 8; i++) {
        final name = 'frame_${i.toString().padLeft(4, '0')}.png';
        try {
          entrance.add(await _asset('$_kGifDir/anim.entrance/$name'));
        } on FlutterError {
          break; // 没有入场产物就跳过该能力演示。
        }
      }
      final pan = await _loadHorizontalPanSet();
      if (!mounted) return;
      setState(() {
        _gif = gif;
        _firstFrame = first;
        _entrance = entrance.isEmpty ? null : entrance;
        _panFrames = pan;
      });
    } on FlutterError catch (e) {
      if (!mounted) return;
      setState(() => _error = '未找到演示产物（见 example/README）\n$e');
    }
  }

  Future<Uint8List> _asset(String path) async {
    final data = await DefaultAssetBundle.of(context).load(path);
    return data.buffer.asUint8List();
  }

  /// 端侧深度渲染（ONNX + 动效门槛）：整条链路在后台 isolate——工厂在
  /// 管线 isolate 内创建会话与估算器（原生句柄不得跨 isolate 传递）。
  /// 深度平坦页会被 [DepthSpreadGate] 压成单帧静态图（带 warning）。
  Future<void> _renderOnDeviceDepth() async {
    if (!File(_qdqModelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少 QDQ 模型：build/depth_probe/models/'
              'midas_v21_small_256_qdq.onnx（gitignored，本机放置）')));
      return;
    }
    if (!File(_samplePagePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少样本页：build/depth_probe/pages/c01_p001.jpg'
              '（gitignored，本机放置）')));
      return;
    }
    setState(() => _depthBusy = true);
    try {
      final result = await processBytesInBackground(
        input: File(_samplePagePath).readAsBytesSync(),
        config: EffectConfig.fromJson(const <String, dynamic>{
          'effects': <String>['parallax'],
          'fps': 12,
          'durationSec': 3.0,
          'maxDimension': 720,
          'layerCount': 3,
          'panelAware': false,
          'outputFormat': 'gif',
          'seed': 7,
          'holdSec': 4.0,
        }),
        depthEstimatorFactory: () => RegionCoherentDepthEstimator(
            inner: OnnxDepthEstimator(
                OrtSessionAdapter.fromFile(_qdqModelPath)),
            detailMinArea: 64),
        motionGateFactory: () => const DepthSpreadGate(),
      );
      if (!mounted) return;
      setState(() => _depthResult = result);
    } finally {
      if (mounted) setState(() => _depthBusy = false);
    }
  }

  /// 动效画面判断渲染（v1.9）：panelAware 分格后逐格裁决——文字主导的
  /// 对话格压成静止（层幅度 0），动作格保持满幅；全格判静时整页单帧。
  /// 判断器为内置纯 Dart 启发式（无模型依赖）；外部 AI 逐格裁决走
  /// MotionPipeline(scene:) 侧车，命中格覆盖启发式。
  Future<void> _renderSceneJudged() async {
    if (!File(_samplePagePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少样本页：build/depth_probe/pages/c01_p001.jpg'
              '（gitignored，本机放置）')));
      return;
    }
    setState(() => _sceneBusy = true);
    try {
      final result = await processBytesInBackground(
        input: File(_samplePagePath).readAsBytesSync(),
        config: EffectConfig.fromJson(const <String, dynamic>{
          'effects': <String>['parallax'],
          'fps': 12,
          'durationSec': 3.0,
          'maxDimension': 720,
          'layerCount': 3,
          'panelAware': true,
          'outputFormat': 'gif',
          'seed': 7,
          'holdSec': 4.0,
        }),
        panelMotionJudgeFactory: () => const HeuristicPanelMotionJudge(),
      );
      if (!mounted) return;
      setState(() => _sceneResult = result);
    } finally {
      if (mounted) setState(() => _sceneBusy = false);
    }
  }

  /// 主体分割渲染（Phase D 人物完整性）：u2netp 逐格分割主体 → 深度钳制
  /// （主体域统一中位数深度）→ 人物整体落入单一深度带，视差不再把人物
  /// 沿深度带切开。分割器失败自动降级为空掩码（不钳制、照常渲染）。
  Future<void> _renderSubjectSeg() async {
    if (!File(_segModelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少 u2netp 模型：build/depth_probe/models/'
              'u2netp.onnx（gitignored，本机放置）')));
      return;
    }
    if (!File(_samplePagePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少样本页：build/depth_probe/pages/c01_p001.jpg'
              '（gitignored，本机放置）')));
      return;
    }
    setState(() => _segBusy = true);
    try {
      final result = await processBytesInBackground(
        input: File(_samplePagePath).readAsBytesSync(),
        config: EffectConfig.fromJson(const <String, dynamic>{
          'effects': <String>['parallax'],
          'fps': 12,
          'durationSec': 3.0,
          'maxDimension': 720,
          'layerCount': 3,
          'panelAware': true,
          'outputFormat': 'gif',
          'seed': 7,
          'holdSec': 4.0,
        }),
        subjectSegmenterFactory: () => OnnxSubjectSegmenter(
            OrtSessionAdapter.fromFile(_segModelPath)),
      );
      if (!mounted) return;
      setState(() => _segResult = result);
    } finally {
      if (mounted) setState(() => _segBusy = false);
    }
  }

  /// 画面自适应渲染（Phase E 全栈）：分割钳制（人物不割裂）+ 张力分档
  /// （文字格静止、动作格加速、特写格主体领跑、平静格低幅）+ 深度门槛
  /// （平坦页单帧）。全部端侧推理，任意漫画离线可用。
  Future<void> _renderSceneAdaptive() async {
    if (!File(_segModelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少 u2netp 模型：build/depth_probe/models/'
              'u2netp.onnx（gitignored，本机放置）')));
      return;
    }
    if (!File(_samplePagePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少样本页：build/depth_probe/pages/c01_p001.jpg'
              '（gitignored，本机放置）')));
      return;
    }
    setState(() => _fullBusy = true);
    try {
      // CLIP 分类器在场则启用（置信覆盖启发式；缺失降级纯启发式）。
      final hasClip = File(_clipModelPath).existsSync() &&
          File(_clipPromptsPath).existsSync();
      final result = await processBytesInBackground(
        input: File(_samplePagePath).readAsBytesSync(),
        config: EffectConfig.fromJson(const <String, dynamic>{
          'effects': <String>['parallax'],
          'fps': 12,
          'durationSec': 3.0,
          'maxDimension': 720,
          'layerCount': 3,
          'panelAware': true,
          'outputFormat': 'gif',
          'seed': 7,
          'holdSec': 4.0,
        }),
        depthEstimatorFactory: () => const RegionCoherentDepthEstimator(
            inner: HeuristicDepthEstimator(), detailMinArea: 64),
        subjectSegmenterFactory: () => OnnxSubjectSegmenter(
            OrtSessionAdapter.fromFile(_segModelPath)),
        panelStrategyJudgeFactory: hasClip
            ? () => ClassifierPanelStrategyJudge(
                classifier: OnnxClipPanelClassifier(
                    OrtSessionAdapter.fromFile(_clipModelPath),
                    _clipPrompts()))
            : () => const HeuristicSceneStrategyJudge(),
        motionGateFactory: () => const DepthSpreadGate(),
      );
      if (!mounted) return;
      setState(() => _fullResult = result);
    } finally {
      if (mounted) setState(() => _fullBusy = false);
    }
  }

  /// CLIP 提示词嵌入（与 PanelClass 顺序对齐：action/atmosphere/closeup/
  /// narrative）。在工厂闭包内读取（管线 isolate 内执行）。
  static List<List<double>> _clipPrompts() {
    final doc = jsonDecode(File(_clipPromptsPath).readAsStringSync())
        as Map<String, dynamic>;
    final emb = doc['embeddings'] as Map<String, dynamic>;
    return [
      for (final c in ['action', 'atmosphere', 'closeup', 'narrative'])
        (emb[c] as List).map((e) => (e as num).toDouble()).toList(),
    ];
  }

  /// both 产物拆轴：资产没有磁盘路径，走内存 index.json 加载，取水平组
  /// （垂直组同理 firstWhere axis == vertical，各自喂一个 ParallaxGyroView）。
  Future<InteractionFrameSet> _loadHorizontalPanSet() async {
    final index = await _asset('$_kPanDir/index.json');
    final sets = await loadInteractionSetsFromIndexJson(
      index,
      loadFrame: (file) async => _asset('$_kPanDir/$file'),
    );
    return sets.firstWhere((s) => s.axis == InteractionAxis.horizontal);
  }

  @override
  Widget build(BuildContext context) {
    final body = _error != null
        ? _ErrorHint(message: _error!)
        : _gif == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const _SectionTitle('PageCurlView：仿真卷页翻页（拖拽 / 点击）'),
                  SizedBox(
                    height: 380,
                    child: PageCurlView(
                      pageCount: 8,
                      onPageTurnStart: (from, to) =>
                          debugPrint('page turn $from -> $to'),
                      frontBuilder: (context, i) => _CurlDemoPage(page: i),
                      backBuilder: (context, i) => _CurlDemoPage(page: i),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '左右拖拽或点击半屏翻页；松手回弹过冲，idle 呼吸微动。',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  const _SectionTitle('MotionGifView：占位过渡 + 入场帧'),
                  AspectRatio(
                    aspectRatio: 1,
                    child: MotionGifView(
                      gifBytes: _gif!,
                      firstFramePng: _firstFrame,
                      entranceFrames: _entrance,
                      playing: _playing,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: _playing ? '暂停' : '播放',
                        isSelected: _playing,
                        onPressed: () => setState(() => _playing = !_playing),
                        icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                      ),
                      IconButton(
                        tooltip: '重播（重建字节序列触发重置）',
                        onPressed: () => setState(() {}),
                        icon: const Icon(Icons.replay),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const _SectionTitle('InteractivePageLayer：点按聚焦 + 撕开揭示'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('动效模式：'),
                      ChoiceChip(
                        label: const Text('持续 (always)'),
                        selected:
                            _motionMode == PageMotionMode.always,
                        onSelected: (_) => setState(
                            () => _motionMode = PageMotionMode.always),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('触发式 (onDemand)'),
                        selected:
                            _motionMode == PageMotionMode.onDemand,
                        onSelected: (_) => setState(
                            () => _motionMode = PageMotionMode.onDemand),
                      ),
                    ],
                  ),
                  AspectRatio(
                    aspectRatio: 1,
                    child: InteractivePageLayer(
                      interactive: true,
                      fit: BoxFit.cover,
                      motionMode: _motionMode,
                      gifBytes: _gif!,
                      firstFramePng: _firstFrame,
                      child: _firstFrame == null
                          ? const ColoredBox(color: Colors.black12)
                          : Image.memory(_firstFrame!, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '点按页面聚焦并撕开揭示动效，再点收回；'
                    '系统减弱动态时只保留首帧与聚焦轮廓。'
                    'onDemand：聚焦入场只播一轮呼吸光晕，之后静息为常亮轮廓，'
                    '再点同格收回、重新点入即重播。',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  if (_panFrames != null) ...[
                    const _SectionTitle(
                        'ParallaxGyroView：陀螺仪 / 触摸拖动视差'),
                    AspectRatio(
                      aspectRatio: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black26),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ParallaxGyroView(
                          frames: _panFrames!,
                          // 真机默认走陀螺仪（省略 tiltStream 即可）；
                          // 桌面端用触摸拖动回退，无需任何额外代码。
                          semanticLabel: '视差预览',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '拖动图片查看视差；真机倾斜设备走陀螺仪（15° 满偏）。',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const _SectionTitle('端侧深度渲染（ONNX MiDaS + 动效门槛）'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed:
                            _depthBusy ? null : _renderOnDeviceDepth,
                        icon: const Icon(Icons.bubble_chart),
                        label: const Text('端侧深度渲染（ONNX+门槛）'),
                      ),
                    ],
                  ),
                  if (_depthBusy)
                    const Center(child: CircularProgressIndicator()),
                  if (_depthResult != null) ...[
                    const SizedBox(height: 8),
                    AspectRatio(
                      aspectRatio: 1,
                      child: MotionGifView(
                        gifBytes: _depthResult!.gifBytes!,
                        playing: _playing,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'frameCount=${_depthResult!.frameCount}'
                      '${_depthResult!.warnings.isEmpty ? '' : '  warnings=${_depthResult!.warnings.join('；')}'}',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    '整页 MiDaS 深度 + 区域一致包装在后台 isolate 推理；'
                    '深度平坦页输出单帧静态图（motion gate 告警）。',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  const _SectionTitle('动效画面判断（格级：该动的动、该静的静）'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed:
                            _sceneBusy ? null : _renderSceneJudged,
                        icon: const Icon(Icons.auto_awesome_motion),
                        label: const Text('画面判断渲染（格级启发式）'),
                      ),
                    ],
                  ),
                  if (_sceneBusy)
                    const Center(child: CircularProgressIndicator()),
                  if (_sceneResult != null) ...[
                    const SizedBox(height: 8),
                    AspectRatio(
                      aspectRatio: 1,
                      child: MotionGifView(
                        gifBytes: _sceneResult!.gifBytes!,
                        playing: _playing,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'frameCount=${_sceneResult!.frameCount}'
                      '${_sceneResult!.warnings.isEmpty ? '' : '  warnings=${_sceneResult!.warnings.join('；')}'}',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'panelAware 分格后逐格裁决：文字主导的对话格层幅度归零'
                    '（视差不割裂人物），动作格保持满幅；全格判静输出单帧'
                    '（scene gate 告警）。外部 AI 侧车 scene.json 可逐格覆盖。',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  const _SectionTitle('主体分割渲染（u2netp：人物完整性）'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _segBusy ? null : _renderSubjectSeg,
                        icon: const Icon(Icons.person_outline),
                        label: const Text('主体分割渲染（人物不割裂）'),
                      ),
                    ],
                  ),
                  if (_segBusy)
                    const Center(child: CircularProgressIndicator()),
                  if (_segResult != null) ...[
                    const SizedBox(height: 8),
                    AspectRatio(
                      aspectRatio: 1,
                      child: MotionGifView(
                        gifBytes: _segResult!.gifBytes!,
                        playing: _playing,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'frameCount=${_segResult!.frameCount}'
                      '${_segResult!.warnings.isEmpty ? '' : '  warnings=${_segResult!.warnings.join('；')}'}',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'panelAware 分格后逐格 u2netp 分割主体，主体域深度统一为'
                    '域内中位数（人物整体单层随动、硬边轮廓）；分割失败降级'
                    '空掩码照常渲染。与未注入对比看人物边缘是否还撕裂。',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  const _SectionTitle('画面自适应渲染（全栈：分割+分档+门槛）'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _fullBusy ? null : _renderSceneAdaptive,
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('画面自适应渲染（端侧全栈）'),
                      ),
                    ],
                  ),
                  if (_fullBusy)
                    const Center(child: CircularProgressIndicator()),
                  if (_fullResult != null) ...[
                    const SizedBox(height: 8),
                    if (_fullResult!.staticPassthroughBytes != null) ...[
                      // 静态页原图直通：原始字节零修改，直接展示原图。
                      AspectRatio(
                        aspectRatio: 1,
                        child: Image.memory(
                            _fullResult!.staticPassthroughBytes!,
                            fit: BoxFit.cover),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '静态页：原图直通（零修改返回，未做任何渲染）',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ] else ...[
                      AspectRatio(
                        aspectRatio: 1,
                        child: MotionGifView(
                          gifBytes: _fullResult!.gifBytes!,
                          playing: _playing,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'frameCount=${_fullResult!.frameCount}'
                        '${_fullResult!.warnings.isEmpty ? '' : '  warnings=${_fullResult!.warnings.join('；')}'}',
                        style: const TextStyle(color: Colors.black54),
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    '按画面内容自动分档（默认静止，只有氛围与张力才动）：文字格'
                    '静止、动作格加速（tempo 1.5）、特写格主体领跑（boost 1.2 +'
                    ' 慢推）、氛围格呼吸（0.6 幅度）、叙事/细节格静止、深度平坦'
                    '页单帧；动画格走区域一致深度（同色平涂整体随动）。对标华为'
                    '阅读 AI 动态漫画——但任意漫画离线可用，无需预制白名单。',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              );

    return Scaffold(
      appBar: AppBar(title: const Text('comic_motion_flutter example')),
      body: body,
    );
  }
}

/// 翻页演示页：纸面 + 页眉页脚 + 占位正文行（纯 widget，无资产依赖）。
class _CurlDemoPage extends StatelessWidget {
  const _CurlDemoPage({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(20),
      color: const Color(0xFFF7F5F0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('第 ${page + 1} 页',
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w600, height: 1.4)),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  for (var i = 0;
                      i < (constraints.maxHeight / 26).floor();
                      i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: FractionallySizedBox(
                        widthFactor: i.isEven ? 1.0 : 0.86,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 8,
                          color: const Color(0x3326241F),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text('PageCurlView demo · $page/7',
                style: const TextStyle(fontSize: 11, color: Colors.black38)),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _ErrorHint extends StatelessWidget {
  const _ErrorHint({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text(
                '先用核心包 CLI 导出产物拷入 example/assets/，再重跑本示例。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
