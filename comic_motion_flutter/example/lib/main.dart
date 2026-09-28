// comic_motion_flutter 用法示例。
//
// 「准备产物」（终端里跑一次，核心包 CLI）：
//   dart run comic_motion_server:render -i input.png -o build/demo
//   dart run comic_motion_server:export-interaction -i input.png -o build/demo_pan
// 把导出目录拷到 example/assets/ 下（见 example/pubspec.yaml 注释），
// 再 flutter run。
//
// 无产物时本示例仍可运行：加载失败会显示错误占位并给出接线指引。
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_flutter/comic_motion_flutter.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

/// 与 example/pubspec.yaml 的 assets 注释对应的目录约定。
const String _kGifDir = 'assets/demo'; // 全量渲染产物目录（stem: demo）
const String _kPanDir = 'assets/demo_pan'; // 交互帧集目录（stem: demo_pan）

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
                ],
              );

    return Scaffold(
      appBar: AppBar(title: const Text('comic_motion_flutter example')),
      body: body,
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
