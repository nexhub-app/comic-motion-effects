import 'dart:async';
import 'dart:typed_data';

import 'package:comic_motion_flutter/comic_motion_flutter.dart';
import 'package:comic_motion_flutter/reader.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pkg_img;

Uint8List _png() {
  final img = pkg_img.Image(width: 4, height: 4, numChannels: 3)
    ..setPixelRgb(0, 0, 200, 120, 80);
  return Uint8List.fromList(pkg_img.encodePng(img).toList());
}

Uint8List _gif() {
  final enc = pkg_img.GifEncoder(delay: 2);
  for (var i = 0; i < 2; i++) {
    enc.addFrame(pkg_img.Image(width: 4, height: 4, numChannels: 3)
      ..setPixelRgb(1, 1, 30 + 60 * i, 30, 30));
  }
  return enc.finish()!;
}

Widget _host(Widget child, {bool disableAnimations = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(width: 200, height: 100, child: child),
        ),
      ),
    );

Future<void> _flushDecode(WidgetTester tester) => tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)));

InteractivePageLayer _layer({
  GlobalKey<InteractivePageLayerState>? key,
  bool reduced = false,
  bool interactive = false,
  Widget? child,
  void Function(String?)? onFocusChanged,
}) =>
    InteractivePageLayer(
      key: key,
      gifBytes: _gifBytes,
      firstFramePng: _pngBytes,
      respectReducedMotion: reduced,
      interactive: interactive,
      onFocusChanged: onFocusChanged,
      child: child,
    );

final Uint8List _gifBytes = _gif();
final Uint8List _pngBytes = _png();

const PanelManifest _manifest = PanelManifest(
  version: 1,
  panels: <PanelSpec>[
    PanelSpec(id: 'a', rect: Rect.fromLTRB(0, 0, 0.5, 0.5)),
    PanelSpec(id: 'b', rect: Rect.fromLTRB(0.5, 0.5, 1, 1)),
  ],
);

InteractivePageLayer _panelLayer({
  GlobalKey<InteractivePageLayerState>? key,
  Map<String, Uint8List> panelClips = const <String, Uint8List>{},
  bool hoverToFocus = false,
  Stream<Offset>? gazeStream,
}) =>
    InteractivePageLayer(
      key: key,
      manifest: _manifest,
      imageSize: const Size(100, 200),
      gifBytes: _gifBytes,
      firstFramePng: _pngBytes,
      panelClips: panelClips,
      hoverToFocus: hoverToFocus,
      gazeStream: gazeStream,
    );

class _Counting extends StatelessWidget {
  const _Counting({required this.onBuild});

  final void Function() onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox.expand();
  }
}

void main() {
  testWidgets('T0 点按聚焦出现裁剪层，再点收回', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    final focuses = <String?>[];
    await tester.pumpWidget(_host(_layer(key: key, onFocusChanged: focuses.add)));
    await _flushDecode(tester);
    await tester.pump();

    expect(find.byKey(InteractivePageLayer.clipKey), findsNothing);

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    expect(
      key.currentState!.handleTap(box.localToGlobal(const Offset(50, 50))),
      isTrue,
    );
    await tester.pump();
    await _flushDecode(tester);
    await tester.pump();

    expect(find.byKey(InteractivePageLayer.clipKey), findsOneWidget);
    expect(find.byKey(InteractivePageLayer.dimKey), findsOneWidget);
    expect(find.byKey(InteractivePageLayer.overlayKey), findsOneWidget);
    expect(focuses, <String?>[InteractivePageLayer.pagePanelId]);

    await tester.pump(const Duration(milliseconds: 450));
    expect(key.currentState!.focusedId, InteractivePageLayer.pagePanelId);

    expect(
      key.currentState!.handleTap(box.localToGlobal(const Offset(50, 50))),
      isTrue,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(key.currentState!.focusedId, isNull);
    expect(find.byKey(InteractivePageLayer.clipKey), findsNothing);
    expect(focuses, <String?>[
      InteractivePageLayer.pagePanelId,
      null,
    ]);
  });

  testWidgets('未聚焦时点按页面外返回 false', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    await tester.pumpWidget(_host(_layer(key: key)));
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    expect(
      key.currentState!.handleTap(box.localToGlobal(const Offset(-20, 50))),
      isFalse,
    );
    expect(key.currentState!.focusedId, isNull);
  });

  testWidgets('动画推进不重建静态 child', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    int childBuilds = 0;
    await tester.pumpWidget(_host(_layer(
      key: key,
      child: _Counting(onBuild: () => childBuilds++),
    )));
    await tester.pump();
    expect(childBuilds, 1);

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    key.currentState!.handleTap(box.localToGlobal(const Offset(50, 50)));
    await tester.pump();
    final afterFocus = childBuilds;

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(childBuilds, afterFocus, reason: '动画 tick 只重绘覆盖层');
  });

  testWidgets('减弱动态：不构造 GIF，保留聚焦轮廓与静帧', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    await tester.pumpWidget(
      _host(_layer(key: key, reduced: true), disableAnimations: true),
    );
    await _flushDecode(tester);
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    key.currentState!.handleTap(box.localToGlobal(const Offset(50, 50)));
    await tester.pump();

    expect(find.byType(MotionGifView), findsNothing, reason: '不构造 GIF 解码');
    expect(find.byKey(InteractivePageLayer.clipKey), findsOneWidget);
    expect(find.byKey(InteractivePageLayer.dimKey), findsOneWidget);
    final clip =
        find.descendant(
          of: find.byKey(InteractivePageLayer.clipKey),
          matching: find.byType(Image),
        );
    expect(clip, findsOneWidget, reason: '静帧 firstFramePng');
  });

  testWidgets('销毁时取消动画与解码，无异常', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    await tester.pumpWidget(_host(_layer(key: key)));
    await tester.pump();
    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    key.currentState!.handleTap(box.localToGlobal(const Offset(50, 50)));
    await tester.pump();
    await _flushDecode(tester);
    await tester.pump();

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  // ---- T1 分格 / T2 格素材 / 悬停 / 注视 ----

  testWidgets('T1 命中分格，整页 GIF 按 pageRect 裁剪', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    await tester.pumpWidget(_host(_panelLayer(key: key)));
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    final Offset origin = box.localToGlobal(Offset.zero);

    // 100×200 竖图 contain 进 200×100：页面 (75,0,50,100)；
    // a = 左上 (75,0,25,50)，b = 右下 (100,50,25,50)。
    expect(
      key.currentState!.handleTap(box.localToGlobal(const Offset(87.5, 25))),
      isTrue,
    );
    await tester.pump();
    expect(key.currentState!.focusedId, 'a');
    expect(
      tester.getRect(find.byKey(InteractivePageLayer.clipKey)),
      Rect.fromLTWH(origin.dx + 75, origin.dy, 25, 50),
    );

    final gifFinder = find.byType(MotionGifView);
    expect(gifFinder, findsOneWidget);
    expect(tester.widget<MotionGifView>(gifFinder).gifBytes,
        same(_gifBytes));
    expect(tester.getSize(gifFinder), const Size(50, 100),
        reason: '整页 GIF 定位到 pageRect，外层裁剪到分格');

    expect(key.currentState!.handleTap(
        box.localToGlobal(const Offset(110, 60))), isTrue);
    await tester.pump();
    expect(key.currentState!.focusedId, 'b');
    expect(
      tester.getRect(find.byKey(InteractivePageLayer.clipKey)),
      Rect.fromLTWH(origin.dx + 100, origin.dy + 50, 25, 50),
    );

    // 页面内、所有分格之外：清焦并消费点击。
    expect(key.currentState!.handleTap(
        box.localToGlobal(const Offset(110, 20))), isTrue);
    expect(key.currentState!.focusedId, isNull);
  });

  testWidgets('T2 格素材优先于整页 GIF', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    final clipBytes = _png();
    await tester.pumpWidget(_host(_panelLayer(
      key: key,
      panelClips: <String, Uint8List>{'a': clipBytes},
    )));
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    key.currentState!.handleTap(box.localToGlobal(const Offset(87.5, 25)));
    await tester.pump();

    final gifFinder = find.byType(MotionGifView);
    expect(gifFinder, findsOneWidget);
    expect(tester.widget<MotionGifView>(gifFinder).gifBytes, same(clipBytes));
    expect(tester.getSize(gifFinder), const Size(25, 50),
        reason: '格素材铺满分格，不再定位到 pageRect');
  });

  testWidgets('T1 缺少 imageSize 触发断言', (tester) async {
    await tester.pumpWidget(_host(InteractivePageLayer(
      manifest: _manifest,
      gifBytes: _gifBytes,
      firstFramePng: _pngBytes,
    )));
    expect(tester.takeException(), isAssertionError);
  });

  testWidgets('hoverToFocus 悬停分格即聚焦，移出不失焦', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    await tester.pumpWidget(_host(_panelLayer(
      key: key,
      hoverToFocus: true,
    )));
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(0, 0));
    addTearDown(gesture.removePointer);

    await gesture.moveTo(box.localToGlobal(const Offset(110, 60)));
    await tester.pump();
    expect(key.currentState!.focusedId, 'b');

    await gesture.moveTo(box.localToGlobal(const Offset(110, 20)));
    await tester.pump();
    expect(key.currentState!.focusedId, 'b', reason: '移出分格不强制失焦');
  });

  testWidgets('gazeStream 归一化坐标经停留后聚焦', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    final gaze = StreamController<Offset>.broadcast();
    addTearDown(gaze.close);
    await tester.pumpWidget(_host(_panelLayer(
      key: key,
      gazeStream: gaze.stream,
    )));
    await tester.pump();

    gaze.add(const Offset(0.25, 0.25)); // a 的中心
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 2));
    expect(key.currentState!.focusedId, 'a');
  });

  testWidgets('interactive:true 自接单击', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    await tester.pumpWidget(_host(_layer(key: key, interactive: true)));
    await tester.pump();

    final box = tester.renderObject<RenderBox>(
        find.byType(InteractivePageLayer));
    await tester.tapAt(box.localToGlobal(const Offset(50, 50)));
    await tester.pump();
    expect(key.currentState!.focusedId, InteractivePageLayer.pagePanelId);
  });

  testWidgets('focusPanel 校验 id，unfocus 清焦', (tester) async {
    final key = GlobalKey<InteractivePageLayerState>();
    await tester.pumpWidget(_host(_panelLayer(key: key)));
    await tester.pump();

    expect(key.currentState!.focusPanel('missing'), isFalse);
    expect(key.currentState!.focusPanel('a'), isTrue);
    expect(key.currentState!.focusedId, 'a');
    key.currentState!.unfocus();
    expect(key.currentState!.focusedId, isNull);
  });
}
