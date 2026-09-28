// ParallaxGyroView widget 测试：tiltStream 注入驱动（mock，不碰传感器）、
// 直切/混合相位→帧映射、触摸拖动回退与回中、空帧集兜底。
//
// 节流说明：_applyPhase 以真实时钟（DateTime.now）做 16ms 防抖，测试注入
// 相邻事件间用真实 20ms 延时保证节流放行。
import 'dart:async';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_flutter/comic_motion_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pkg_img;

Uint8List _png(int r, int g, int b) {
  final img = pkg_img.Image(width: 8, height: 8, numChannels: 3)
    ..setPixelRgb(0, 0, r, g, b);
  return Uint8List.fromList(pkg_img.encodePng(img).toList());
}

/// 5 帧水平/垂直帧集，颜色递增作帧指纹。
InteractionFrameSet _set(InteractionAxis axis) {
  final bytes = <Uint8List>[
    for (var i = 0; i < 5; i++) _png(20 * (i + 1), 0, 0),
  ];
  return InteractionFrameSet(
    axis: axis,
    phases: const [-1.0, -0.5, 0.0, 0.5, 1.0],
    pngBytes: bytes,
  );
}

Widget _host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.expand(child: child),
    );

/// 注入一个相位并等待真实时钟越过 16ms 节流窗。
Future<void> inject(
  StreamController<Offset> ctrl,
  Offset phase,
  WidgetTester tester,
) async {
  ctrl.add(phase);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await tester.pump();
}

Uint8List _shownBytes(WidgetTester tester) {
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  expect(images, isNotEmpty);
  final provider = images.first.image as MemoryImage;
  return provider.bytes;
}

void main() {
  late StreamController<Offset> ctrl;

  setUp(() {
    ctrl = StreamController<Offset>();
  });
  tearDown(() async {
    await ctrl.close();
  });

  testWidgets('注入流直切：phase=0 显示第 2 帧，注入 0.6 切第 3 帧',
      (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: frames,
      tiltStream: ctrl.stream,
      smooth: false,
    )));
    await tester.pump();

    expect(_shownBytes(tester), same(frames.pngBytes[2]),
        reason: '初始 phase=0 → 最近采样点 0 → 帧索引 2');

    await inject(ctrl, const Offset(0.6, 0), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[3]),
        reason: 'phase=0.6 → 最近采样点 0.5 → 帧索引 3');
  });

  testWidgets('注入流直切：垂直轴取 phaseY 分量', (tester) async {
    final frames = _set(InteractionAxis.vertical);
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: frames,
      tiltStream: ctrl.stream,
      smooth: false,
    )));
    await tester.pump();

    await inject(ctrl, const Offset(0.9, -0.7), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[1]),
        reason: '垂直轴忽略 dx，phaseY=-0.7 → 最近 -0.5 → 帧索引 1');
  });

  testWidgets('smooth 混合：中间相位渲染相邻两帧各半透明 Stack', (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: frames,
      tiltStream: ctrl.stream,
      smooth: true,
    )));
    await tester.pump();

    await inject(ctrl, const Offset(0.25, 0), tester);
    // pos = (0.25+1)/0.5 = 2.5 → i0=2, i1=3, frac=0.5。
    final opacities =
        tester.widgetList<Opacity>(find.byType(Opacity)).toList();
    expect(opacities, hasLength(2), reason: '相邻两帧混合');
    expect(opacities[0].opacity, closeTo(0.5, 1e-9));
    expect(opacities[1].opacity, closeTo(0.5, 1e-9));
  });

  testWidgets('触摸拖动：相位跟手，松手回中', (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: frames,
      tiltStream: ctrl.stream,
      smooth: false,
    )));
    await tester.pump();

    // 视口 800 宽：dx=150 → phase += 150/(800/2) = 0.375。
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();
    expect(_shownBytes(tester), same(frames.pngBytes[3]),
        reason: 'phase≈0.375 → 最近采样点 0.5');

    await gesture.up();
    await tester.pump();
    expect(_shownBytes(tester), same(frames.pngBytes[2]),
        reason: 'returnToCenter 默认开启 → 松手回 phase=0');
  });

  testWidgets('touchFallback=false：手势不改变帧', (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: frames,
      tiltStream: ctrl.stream,
      smooth: false,
      touchFallback: false,
    )));
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(_shownBytes(tester), same(frames.pngBytes[2]),
        reason: '手势路径关闭 → 恒为初始帧');
  });

  testWidgets('returnToCenter=false：松手保持当前相位', (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: frames,
      tiltStream: ctrl.stream,
      smooth: false,
      returnToCenter: false,
    )));
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(_shownBytes(tester), same(frames.pngBytes[3]),
        reason: '未回中 → 保持拖动后的帧');
  });

  testWidgets('空帧集：兜底显示 semanticLabel', (tester) async {
    final empty = InteractionFrameSet(
      axis: InteractionAxis.horizontal,
      phases: const [],
      pngBytes: const [],
    );
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: empty,
      tiltStream: ctrl.stream,
      semanticLabel: 'no frames',
    )));
    await tester.pump();

    expect(find.text('no frames'), findsOneWidget);
  });
}
