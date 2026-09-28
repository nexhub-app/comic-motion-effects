// MotionGifView widget 测试：占位过渡、减弱动态静帧、解码失败兜底、
// 入场帧前置播放、gifBytes 变更重置、W4 功耗感知三路径。
//
// 测试策略：
// - `crossfadeDuration: Duration.zero`（过渡即达）；W4 用例 `playing: true`。
// - 引擎编解码（`ui.instantiateImageCodec` / `getNextFrame`）是**真异步**，
//   在 testWidgets 的 FakeAsync 区内不会被 pumpAndSettle 驱动完成——一律先
//   经 [flushDecode] 以 `tester.runAsync` 冲刷真实时间，再 pump 交付帧。
// - 泵帧循环里每次 `getNextFrame` 同理，[pumpStep] = 真实冲刷 + fake 推进。
// - 占位/入场帧经 `Image.memory` 渲染（内部自带 RawImage）；GIF 帧是
//   widget 直属的裸 RawImage——用 [gifFrameRaws] 只找后者。
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
    ..setPixelRgb(1, 1, 1, 1, 1);
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
  int entranceDelayMs = 1,
}) =>
    MotionGifView(
      gifBytes: gif,
      firstFramePng: placeholder,
      entranceFrames: entrance,
      playing: playing,
      crossfadeDuration: Duration.zero,
      entranceDelayMs: entranceDelayMs,
    );

/// widget 直属的 GIF 帧 RawImage（排除 `Image.memory` 内部渲染的 RawImage）。
List<RawImage> gifFrameRaws(WidgetTester tester) {
  final out = <RawImage>[];
  // skipOffstage: false —— 视口暂停用例里 item 滚出可视区但仍在
  // cacheExtent 内，默认 finder 会把它当 offstage 过滤掉。
  for (final el in find.byType(RawImage, skipOffstage: false).evaluate()) {
    final hasImageAncestor = find
        .ancestor(of: find.byWidget(el.widget), matching: find.byType(Image))
        .evaluate()
        .isNotEmpty;
    if (!hasImageAncestor) out.add(el.widget as RawImage);
  }
  return out;
}

/// 冲刷真实时间：让引擎侧编解码回调在测试区外完成。
Future<void> flushDecode(WidgetTester tester) =>
    tester.runAsync(() =>
        Future<void>.delayed(const Duration(milliseconds: 60)));

/// 泵帧单步：真实冲刷（下一帧解码）+ fake 推进（帧延时计时器）。
Future<void> pumpStep(WidgetTester tester, Duration t) async {
  await flushDecode(tester);
  await tester.pump(t);
}

void main() {
  final gif = _gif();
  final red = _png(255, 0, 0);
  final green = _png(0, 255, 0);
  final blue = _png(0, 0, 255);

  testWidgets('GIF 解码完成后显示 RawImage，占位 crossfade 淡出', (tester) async {
    await tester.pumpWidget(_host(_view(gif: gif, placeholder: red)));
    await flushDecode(tester);
    // postFrameCallback 触发 _bootstrap；解码完成后 settle。
    await tester.pumpAndSettle();

    expect(gifFrameRaws(tester), isNotEmpty, reason: 'GIF 首帧应已解码显示');
    // 占位层整个从树中移除（crossfade 完成语义：showPlaceholder=false）。
    expect(find.byType(AnimatedOpacity), findsNothing);
  });

  testWidgets('减弱动态：不解码动画，保持占位静帧', (tester) async {
    await tester.pumpWidget(
      _host(
        _view(gif: gif, placeholder: red),
        disableAnimations: true,
      ),
    );
    await flushDecode(tester);
    await tester.pumpAndSettle();

    expect(gifFrameRaws(tester), isEmpty, reason: '减弱动态下不应解码动画');
    expect(find.byType(Image), findsWidgets, reason: '占位经 Image.memory 保留');
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1.0, reason: '占位保持可见');
  });

  testWidgets('解码失败：占位保留，不白屏', (tester) async {
    await tester.pumpWidget(
      _host(_view(gif: Uint8List(0), placeholder: red)),
    );
    await flushDecode(tester);
    await tester.pumpAndSettle();

    expect(gifFrameRaws(tester), isEmpty, reason: '解码失败不应有 GIF 帧');
    expect(find.byType(Image), findsWidgets, reason: '占位保留，不白屏');
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1.0, reason: '失败时占位层兜底可见');
  });

  testWidgets('入场帧前置播放：逐帧 → 末帧 → 切入 GIF 层', (tester) async {
    // 延时 100ms：给每帧留出可断言的时间窗（1ms 会单次 pump 烧完整个序列）。
    await tester.pumpWidget(
      _host(_view(
          gif: gif, placeholder: red, entrance: [green, blue],
          entranceDelayMs: 100)),
    );
    // postFrameCallback → _bootstrap → _playEntrance 首帧 setState。
    await tester.pump();
    expect(find.byKey(const ValueKey<int>(0)), findsOneWidget,
        reason: '入场第 0 帧（绿）应可见');

    // fake 时钟走过第一个 entranceDelayMs(100ms)。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey<int>(1)), findsOneWidget,
        reason: '入场第 1 帧（蓝）应可见');

    await tester.pump(const Duration(milliseconds: 100));
    await flushDecode(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<int>(1)), findsNothing,
        reason: '入场结束后入场层移除');
    expect(gifFrameRaws(tester), hasLength(1),
        reason: 'GIF 首帧接管（playing=false 亦显示首帧）');
  });

  testWidgets('gifBytes 变更：重置回占位态并重新引导', (tester) async {
    final gif2 = _gif();
    await tester.pumpWidget(_host(_view(gif: gif, placeholder: red)));
    await flushDecode(tester);
    await tester.pumpAndSettle();
    expect(gifFrameRaws(tester), hasLength(1));

    await tester.pumpWidget(
      _host(_view(gif: gif2, placeholder: red)),
    );
    await tester.pump();

    expect(gifFrameRaws(tester), isEmpty,
        reason: '字节变更应重置 _currentFrame');
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1.0, reason: '重置后占位回到不透明');
  });

  testWidgets('codec 资源随组件销毁释放（无异常即通过）', (tester) async {
    await tester.pumpWidget(_host(_view(gif: gif, placeholder: red)));
    await flushDecode(tester);
    await tester.pumpAndSettle();
    expect(gifFrameRaws(tester).first.image, isA<ui.Image>());
    await tester.pumpWidget(const SizedBox.shrink());
    // dispose 内 codec/image release；engine 断言交给 leak 追踪，此处冒烟。
  });

  // ---- W4 功耗感知：生命周期 / 视口 / App 钩子三路径的静帧-恢复 ----

  ui.Image? currentFrame(WidgetTester tester) {
    final raws = gifFrameRaws(tester);
    return raws.isEmpty ? null : raws.first.image;
  }

  /// 3 帧循环 GIF（image 包 GifEncoder 的 delay 单位是厘秒：2 = 20ms/帧），
  /// 泵帧推进可通过 RawImage 帧实例变化观察。
  Uint8List multiFrameGif() {
    final enc = pkg_img.GifEncoder(delay: 2);
    for (var i = 0; i < 3; i++) {
      enc.addFrame(pkg_img.Image(width: 4, height: 4, numChannels: 3)
        ..setPixelRgb(1, 1, 50 + 60 * i, 200 - 50 * i, 30));
    }
    return enc.finish()!;
  }

  testWidgets('生命周期 paused 静帧、resumed 恢复泵帧', (tester) async {
    final multi = multiFrameGif();
    await tester.pumpWidget(_host(MotionGifView(
        gifBytes: multi,
        playing: true,
        crossfadeDuration: Duration.zero)));
    await tester.pump(); // postFrame bootstrap
    await flushDecode(tester); // 引擎解码首帧
    await tester.pump(); // 首帧交付 + 启动泵帧

    final frozen = currentFrame(tester);
    expect(frozen, isNotNull);

    // paused：世代号失效 → 泵帧循环退出 → 长时间推进帧恒定。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await pumpStep(tester, const Duration(milliseconds: 200)); // 在途帧回包即退出
    await tester.pump(const Duration(milliseconds: 200));
    expect(currentFrame(tester), same(frozen),
        reason: 'paused 后泵帧应停止，帧保持不变');

    // resumed：恢复泵帧 → 帧推进（3 帧循环必然切换）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var advanced = false;
    for (var i = 0; i < 6 && !advanced; i++) {
      await pumpStep(tester, const Duration(milliseconds: 200));
      advanced = currentFrame(tester) != frozen;
    }
    expect(advanced, isTrue, reason: 'resumed 后泵帧应恢复推进');
  });

  testWidgets('enableMotion 钩子 false 静帧、rebuild 后恢复', (tester) async {
    final multi = multiFrameGif();
    var allowed = false;
    MotionGifView buildView() => MotionGifView(
          gifBytes: multi,
          playing: true,
          crossfadeDuration: Duration.zero,
          enableMotion: () => allowed,
        );
    await tester.pumpWidget(_host(buildView()));
    await tester.pump();
    await flushDecode(tester); // 解码首帧（钩子 false 不启动泵帧）
    await tester.pump();

    final frozen = currentFrame(tester);
    expect(frozen, isNotNull);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(currentFrame(tester), same(frozen),
        reason: '钩子 false 时不应启动泵帧');

    allowed = true; // App 策略恢复（rebuild 触发重估）
    await tester.pumpWidget(_host(buildView()));
    var advanced = false;
    for (var i = 0; i < 6 && !advanced; i++) {
      await pumpStep(tester, const Duration(milliseconds: 200));
      advanced = currentFrame(tester) != frozen;
    }
    expect(advanced, isTrue, reason: '钩子恢复后应开始泵帧');
  });

  testWidgets('pauseWhenNotVisible：滚出视口静帧、滚回恢复', (tester) async {
    final multi = multiFrameGif();
    // item 高 100：jumpTo(200) 时 item(0..100) 在屏(200..800)外，与视口
    // 前缘空隙 100 < 默认 cacheExtent(250) → 元素保留不被回收（jumpTo(300)
    // 会超缓存区把 item 整个销毁，断言对象都没了）。
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
    await flushDecode(tester); // 解码首帧 + 泵帧启动
    await tester.pump();

    final frozen = currentFrame(tester);
    expect(frozen, isNotNull);

    // 滚出视口（jumpTo 无惯性；ScrollNotification 触发视口自检）。
    controller.jumpTo(200);
    await pumpStep(tester, const Duration(milliseconds: 200)); // postFrame 自检 + 循环退出
    await tester.pump(const Duration(milliseconds: 200));
    expect(currentFrame(tester), same(frozen),
        reason: '滚出视口后泵帧应停止');

    // 滚回视口 → 恢复泵帧。
    controller.jumpTo(0);
    var advanced = false;
    for (var i = 0; i < 6 && !advanced; i++) {
      await pumpStep(tester, const Duration(milliseconds: 200));
      advanced = currentFrame(tester) != frozen;
    }
    expect(advanced, isTrue, reason: '滚回视口后泵帧应恢复');
  });
}
