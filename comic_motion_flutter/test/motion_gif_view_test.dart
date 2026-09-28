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
}
