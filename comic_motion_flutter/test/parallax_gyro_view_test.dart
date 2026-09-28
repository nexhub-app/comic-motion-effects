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

/// 注入一个相位并等待真实时钟越过 16ms 节流窗（widget 侧 DateTime.now
/// 防抖走真实时钟）。注意：testWidgets 的 FakeAsync 区内裸 `await
/// Future.delayed` 永不完成，必须经 `runAsync` 冲刷真实时间。
Future<void> inject(
  StreamController<Offset> ctrl,
  Offset phase,
  WidgetTester tester,
) async {
  ctrl.add(phase);
  await tester.runAsync(() =>
      Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
}

Uint8List _shownBytes(WidgetTester tester) {
  // skipOffstage: false —— 滚出视口但仍在 cacheExtent 内的元素会被
  // 默认 finder 当作 offstage 过滤掉，而断言对象恰是"静帧仍在树中"。
  final images =
      tester.widgetList<Image>(find.byType(Image, skipOffstage: false)).toList();
  expect(images, isNotEmpty);
  final provider = images.first.image as MemoryImage;
  return provider.bytes;
}

void main() {
  late StreamController<Offset> ctrl;

  setUp(() {
    // broadcast：抑制期（未订阅）注入事件直接丢弃，符合"断流"语义。
    ctrl = StreamController<Offset>.broadcast();
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
    const empty = InteractionFrameSet(
      axis: InteractionAxis.horizontal,
      phases: [],
      pngBytes: [],
    );
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: empty,
      tiltStream: ctrl.stream,
      semanticLabel: 'no frames',
    )));
    await tester.pump();

    expect(find.text('no frames'), findsOneWidget);
  });

  // ---- W4 功耗感知：生命周期 / 视口 / App 钩子三路径的静帧-恢复 ----
  // 静帧断言：抑制期间注入新相位不更新显示帧；恢复后注入立即生效。

  testWidgets('enableMotion 钩子 false 断流静帧、rebuild 恢复', (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    var allowed = false;
    Widget buildHost() => _host(ParallaxGyroView(
          frames: frames,
          tiltStream: ctrl.stream,
          smooth: false,
          enableMotion: () => allowed,
        ));
    await tester.pumpWidget(buildHost());
    await tester.pump();
    expect(_shownBytes(tester), same(frames.pngBytes[2]));

    await inject(ctrl, const Offset(-0.9, 0), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[2]),
        reason: '钩子 false：注入不更新（订阅已断）');

    allowed = true; // App rebuild 触发重估 → 重连订阅
    await tester.pumpWidget(buildHost());
    await inject(ctrl, const Offset(-0.9, 0), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[0]),
        reason: '恢复后注入应生效');
  });

  testWidgets('生命周期 paused 断流静帧、resumed 恢复', (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    await tester.pumpWidget(_host(ParallaxGyroView(
      frames: frames,
      tiltStream: ctrl.stream,
      smooth: false,
    )));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await inject(ctrl, const Offset(0.9, 0), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[2]),
        reason: '后台时注入不更新');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await inject(ctrl, const Offset(0.9, 0), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[4]),
        reason: '回到前台注入生效');
  });

  testWidgets('pauseWhenNotVisible：滚出视口断流、滚回重连', (tester) async {
    final frames = _set(InteractionAxis.horizontal);
    final controller = ScrollController();
    Widget buildHost() => Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(
            controller: controller,
            children: [
              SizedBox(
                height: 100,
                child: ParallaxGyroView(
                  frames: frames,
                  tiltStream: ctrl.stream,
                  smooth: false,
                  pauseWhenNotVisible: true,
                ),
              ),
              const SizedBox(height: 900),
            ],
          ),
        );
    await tester.pumpWidget(buildHost());
    await tester.pump();
    expect(_shownBytes(tester), same(frames.pngBytes[2]));

    // 滚出（item 0..100 在 offset=200 时屏外，与视口前缘空隙 100 <
    // cacheExtent(250)，元素保留；300 会超出缓存区把 item 整个回收）。
    controller.jumpTo(200);
    await tester.pump(const Duration(milliseconds: 50));
    await inject(ctrl, const Offset(0.9, 0), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[2]),
        reason: '滚出视口后注入不更新');

    // 滚回。
    controller.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 50));
    await inject(ctrl, const Offset(0.9, 0), tester);
    expect(_shownBytes(tester), same(frames.pngBytes[4]),
        reason: '滚回视口后注入生效');
  });
}
