// W7 example：程序化生成 3 张占位分层纹理（模拟核心包 exportLayers 产物：
// 远→近三层，近层带透明区域以便观察视差/呼吸），slider 实时驱动视差，
// 开关切呼吸/扫光/暗角。运行 `flutter run` 于本目录。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:comic_motion_shaders/comic_motion_shaders.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final layers = <ui.Image>[
    await _layer(const Color(0xFF243447), full: true), // 远：全画布底
    await _layer(const Color(0xFF4F7CAC), full: false), // 中：留出边缘
    await _layer(const Color(0xFFE07A5F), full: false), // 近：更小主体
  ];
  runApp(_DemoApp(layers: layers));
}

/// 生成一张画布 900x1300 的占位层纹理；full=false 时主体居中留出透明边缘
/// （模拟 W6 分层导出的 alpha 结构）。
Future<ui.Image> _layer(Color color, {required bool full}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  if (full) {
    canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 900, 1300), ui.Paint()..color = color);
    // 底图叠一点纹理感（随机浅色块）
    final rnd = math.Random(7);
    final light = ui.Paint()..color = color.withAlpha(40);
    for (var i = 0; i < 24; i++) {
      canvas.drawCircle(
          ui.Offset(rnd.nextDouble() * 900, rnd.nextDouble() * 1300),
          40 + rnd.nextDouble() * 90,
          light);
    }
  } else {
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
          const ui.Rect.fromLTWH(180, 320, 540, 660),
          const ui.Radius.elliptical(60, 60)),
      ui.Paint()..color = color,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(900, 1300);
  picture.dispose();
  return image;
}

class _DemoApp extends StatefulWidget {
  const _DemoApp({required this.layers});

  final List<ui.Image> layers;

  @override
  State<_DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<_DemoApp> {
  double _parallax = 0.02;
  bool _breathing = true;
  bool _sweep = true;
  bool _vignette = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'comic_motion_shaders example',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('RealtimeMotionView demo')),
        body: Column(
          children: [
            Expanded(
              child: Center(
                child: RealtimeMotionView(
                  layers: widget.layers,
                  parallaxShift: Offset(_parallax, _parallax * 0.6),
                  breathing: _breathing,
                  zoom: 0.02,
                  sweep: _sweep,
                  sweepPeriod: const Duration(seconds: 9),
                  vignette: _vignette,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('parallax: ${_parallax.toStringAsFixed(3)}'),
                  Slider(
                    value: _parallax,
                    min: 0,
                    max: 0.06,
                    onChanged: (v) => setState(() => _parallax = v),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('breathing'),
                        selected: _breathing,
                        onSelected: (v) => setState(() => _breathing = v),
                      ),
                      FilterChip(
                        label: const Text('sweep'),
                        selected: _sweep,
                        onSelected: (v) => setState(() => _sweep = v),
                      ),
                      FilterChip(
                        label: const Text('vignette'),
                        selected: _vignette,
                        onSelected: (v) => setState(() => _vignette = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
