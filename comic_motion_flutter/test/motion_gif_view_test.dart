// MotionGifView widget 测试：占位过渡、减弱动态静帧、解码失败兜底、
// 入场帧前置播放、gifBytes 变更重置。
//
// 测试策略：全部用 `playing: false`（单帧解码后不启动泵帧循环，pumpAndSettle
// 可安全 settle）与 `crossfadeDuration: Duration.zero`（过渡即达，无需逐帧
// pump 动画）。入场帧序列用真实短延时推进（DateTime/timer 真实时钟）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:comic_motion_flutter/comic_motion_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pkg_img;

Uint8List _png(int r, int g, int b) {
  final img = pkg_img.Image(width: 4, height: 4, numChannels: 3)
    ..setPixelRgb(0, 0, r, g, b);
  return Uint8List.fromList(pkg_img.encodePng(img).toList());
}

Uint8List _gif() {
  final img = pkg_img.Image(width: 4, height: 4, numChannels: 3)
    ..setPixelRgb(1, 1, 1);
  return Uint8List.fromList(pkg_img.encodeGif(img).toList());
}

Widget _host(Widget child, {bool disableAnimations = false}) =>
    MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 100, height: 100, child: child),
      ),
    );

MotionGifView _view({
  required Uint8List gif,
  Uint8List? placeholder,
  List<Uint8List>? entrance,
  bool playing = false,
}) =>
    MotionGifView(
      gifBytes: gif,
      firstFramePng: placeholder,
      entranceFrames: entrance,
      playing: playing,
      crossfadeDuration: Duration.zero,
      entranceDelayMs: 1,
    );

void main() {
  final gif = _gif();
  final red = _png(255, 0, 0);
  final green = _png(0, 255, 0);
  final blue = _png(0, 0, 255);

  testWidgets('GIF 解码完成后显示 RawImage，占位 crossfade 淡出', (tester) async {
    await tester.pumpWidget(_host(_view(gif: gif, placeholder: red)));
    // postFrameCallback 触发 _bootstrap；解码完成后 settle。
    await tester.pumpAndSettle();

    final raws = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
    expect(raws, isNotEmpty, reason: 'GIF 首帧应已解码显示');
    // 占位层仍在树中（AnimatedOpacity 包裹）但已透明。
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 0.0);
  });

  testWidgets('减弱动态：不解码动画，保持占位静帧', (tester) async {
    await tester.pumpWidget(
      _host(
        _view(gif: gif, placeholder: red),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RawImage), findsNothing,
        reason: '减弱动态下不应解码动画');
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1.0, reason: '占位保持可见');
  });

  testWidgets('解码失败：占位保留，不白屏', (tester) async {
    await tester.pumpWidget(
      _host(_view(gif: Uint8List(0), placeholder: red)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RawImage), findsNothing);
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1.0, reason: '失败时占位层兜底可见');
  });

  testWidgets('入场帧前置播放：逐帧 → 末帧 → 切入 GIF 层', (tester) async {
    await tester.pumpWidget(
      _host(_view(gif: gif, placeholder: red, entrance: [green, blue])),
    );
    // postFrameCallback → _bootstrap → _playEntrance 首帧 setState。
    await tester.pump();
    expect(find.byKey(const ValueKey<int>(0)), findsOneWidget,
        reason: '入场第 0 帧（绿）应可见');

    // 真实时钟走过 entranceDelayMs(1ms) + 余量。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.byKey(const ValueKey<int>(1)), findsOneWidget,
        reason: '入场第 1 帧（蓝）应可见');

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<int>(1)), findsNothing,
        reason: '入场结束后入场层移除');
    expect(find.byType(RawImage), findsOneWidget,
        reason: 'GIF 首帧接管（playing=false 亦显示首帧）');
  });

  testWidgets('gifBytes 变更：重置回占位态并重新引导', (tester) async {
    final gif2 = _gif();
    await tester.pumpWidget(_host(_view(gif: gif, placeholder: red)));
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);

    await tester.pumpWidget(
      _host(_view(gif: gif2, placeholder: red)),
    );
    await tester.pump();

    expect(find.byType(RawImage), findsNothing,
        reason: '字节变更应重置 _currentFrame');
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1.0, reason: '重置后占位回到不透明');
  });

  testWidgets('codec 资源随组件销毁释放（无异常即通过）', (tester) async {
    await tester.pumpWidget(_host(_view(gif: gif, placeholder: red)));
    await tester.pumpAndSettle();
    final raws = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
    expect(raws.first.image, isA<ui.Image>());
    await tester.pumpWidget(const SizedBox.shrink());
    // dispose 内 codec/image release；engine 断言交给 leak 追踪，此处冒烟。
  });

  // ---- W4 功耗感知：生命周期 / 视口 / App 钩子三路径的静帧-恢复 ----

  ui.Image? _currentFrame(WidgetTester tester) {
    final raws = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
    return raws.isEmpty ? null : raws.first.image;
  }

  /// 3 帧循环 GIF（每帧 16ms），泵帧推进可通过 RawImage 帧实例变化观察。
  Uint8List _multiFrameGif() {
    final enc = pkg_img.GifEncoder(delay: 16);
    for (var i = 0; i < 3; i++) {
      enc.addFrame(pkg_img.Image(width: 4, height: 4, numChannels: 3)
        ..setPixelRgb(50 + 60 * i, 200 - 50 * i, 30));
    }
    return enc.finish()!;
  }

  testWidgets('生命周期 paused 静帧、resumed 恢复泵帧', (tester) async {
    final multi = _multiFrameGif();
    await tester.pumpWidget(_host(
        MotionGifView(gifBytes: multi, playing: true, crossfadeDuration: Duration.zero)));
    await tester.pump(); // postFrame bootstrap
    await tester.pump(const Duration(milliseconds: 50)); // 解码首帧 + 启动泵帧

    // paused：世代号失效 → 泵帧循环退出 → 长时间推进帧恒定。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 400));
    final frozen = _currentFrame(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_currentFrame(tester), same(frozen),
        reason: 'paused 后泵帧应停止，帧保持不变');

    // resumed：恢复泵帧 → 帧推进（3 帧循环必然切换）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var advanced = false;
    for (var i = 0; i < 6 && !advanced; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      advanced = _currentFrame(tester) != frozen;
    }
    expect(advanced, isTrue, reason: 'resumed 后泵帧应恢复推进');
  });

  testWidgets('enableMotion 钩子 false 静帧、rebuild 后恢复', (tester) async {
    final multi = _multiFrameGif();
    var allowed = false;
    MotionGifView buildView() => MotionGifView(
          gifBytes: multi,
          playing: true,
          crossfadeDuration: Duration.zero,
          enableMotion: () => allowed,
        );
    await tester.pumpWidget(_host(buildView()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // 解码首帧（不启动泵帧）

    final frozen = _currentFrame(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_currentFrame(tester), same(frozen),
        reason: '钩子 false 时不应启动泵帧');

    allowed = true; // App 策略恢复（rebuild 触发重估）
    await tester.pumpWidget(_host(buildView()));
    var advanced = false;
    for (var i = 0; i < 6 && !advanced; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      advanced = _currentFrame(tester) != frozen;
    }
    expect(advanced, isTrue, reason: '钩子恢复后应开始泵帧');
  });

  testWidgets('pauseWhenNotVisible：滚出视口静帧、滚回恢复', (tester) async {
    final multi = _multiFrameGif();
    // item 高 100：offset=300 时 item 矩形(0..100) 在屏(300..900)外，
    // 但仍在默认 cacheExtent(250) 内 → renderobject 保留不被回收。
    final controller = ScrollController();
    Widget wrap(Widget child) => Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(
            controller: controller,
            children: [
              SizedBox(height: 100, child: child),
              const SizedBox(height: 900),
            ],
          ),
        );
    MotionGifView buildView() => MotionGifView(
          gifBytes: multi,
          playing: true,
          crossfadeDuration: Duration.zero,
          pauseWhenNotVisible: true,
          width: 200,
          height: 100,
        );
    await tester.pumpWidget(wrap(buildView()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // 解码首帧 + 泵帧启动

    // 滚出视口（jumpTo 无惯性；ScrollNotification 触发视口自检）。
    controller.jumpTo(300);
    await tester.pump(const Duration(milliseconds: 400)); // postFrame 自检 + 循环退出
    final frozen = _currentFrame(tester);
    expect(frozen, isNotNull);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_currentFrame(tester), same(frozen),
        reason: '滚出视口后泵帧应停止');

    // 滚回视口 → 恢复泵帧。
    controller.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 200));
    var advanced = false;
    for (var i = 0; i < 6 && !advanced; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      advanced = _currentFrame(tester) != frozen;
    }
    expect(advanced, isTrue, reason: '滚回视口后泵帧应恢复');
  });
}
