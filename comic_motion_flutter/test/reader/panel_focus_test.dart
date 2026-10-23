import 'dart:ui';

import 'package:comic_motion_flutter/reader.dart';
import 'package:flutter_test/flutter_test.dart';

PanelLayout _layout() => PanelLayout.resolve(
      availableRect: const Rect.fromLTWH(0, 0, 200, 100),
      imageSize: const Size(200, 100),
      panels: const <PanelSpec>[
        PanelSpec(id: 'p1', rect: Rect.fromLTRB(0.1, 0.1, 0.4, 0.4)),
        PanelSpec(id: 'p2', rect: Rect.fromLTRB(0.6, 0.6, 0.9, 0.9)),
      ],
    );

void main() {
  test('exclusive 互斥，且仅在状态变化时通知', () {
    final c = PanelFocusController();
    int notifications = 0;
    c.addListener(() => notifications++);

    expect(c.hasFocus, isFalse);
    expect(c.primaryId, isNull);
    expect(c.focusedIds, isEmpty);

    c.focus('p1');
    expect(c.primaryId, 'p1');
    expect(c.focusedIds, <String>{'p1'});
    expect(c.isFocused('p1'), isTrue);
    expect(notifications, 1);

    c.focus('p1');
    expect(notifications, 1);

    c.focus('p2');
    expect(c.primaryId, 'p2');
    expect(c.focusedIds, <String>{'p2'});
    expect(notifications, 2);

    c.unfocus();
    expect(c.hasFocus, isFalse);
    expect(notifications, 3);

    c.unfocus();
    expect(notifications, 3);
    c.dispose();
  });

  test('toggle 已聚焦即取消', () {
    final c = PanelFocusController();
    c.toggle('p1');
    expect(c.focusedIds, <String>{'p1'});
    c.toggle('p1');
    expect(c.hasFocus, isFalse);
    c.dispose();
  });

  test('multi 可叠加，primary 为最近聚焦', () {
    final c = PanelFocusController(mode: PanelFocusMode.multi);
    c.toggle('a');
    c.toggle('b');
    expect(c.focusedIds, <String>{'a', 'b'});
    expect(c.primaryId, 'b');

    c.focus('c');
    expect(c.focusedIds, <String>{'a', 'b', 'c'});
    expect(c.primaryId, 'c');

    c.unfocus('b');
    expect(c.focusedIds, <String>{'a', 'c'});
    expect(c.primaryId, 'c');

    c.toggle('a');
    expect(c.focusedIds, <String>{'c'});

    c.toggle('c');
    expect(c.hasFocus, isFalse);
    c.dispose();
  });

  test('tapAt 命中切换、未命中清焦、无焦未命中返回 false', () {
    final c = PanelFocusController();
    final layout = _layout();

    expect(c.tapAt(layout, const Offset(100, 50)), isFalse);
    expect(c.hasFocus, isFalse);

    expect(c.tapAt(layout, const Offset(30, 20)), isTrue);
    expect(c.focusedIds, <String>{'p1'});

    expect(c.tapAt(layout, const Offset(30, 20)), isTrue);
    expect(c.hasFocus, isFalse);

    c.focus('p1');
    expect(c.tapAt(layout, const Offset(100, 50)), isTrue);
    expect(c.hasFocus, isFalse);
    c.dispose();
  });

  testWidgets('注视停留后聚焦，离开后释放', (tester) async {
    final c = PanelFocusController(
      gazeDwell: const Duration(milliseconds: 600),
      gazeRelease: const Duration(milliseconds: 1200),
    );
    c.updateGaze('p1');
    await tester.pump(const Duration(milliseconds: 599));
    expect(c.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    expect(c.primaryId, 'p1');

    c.updateGaze(null);
    await tester.pump(const Duration(milliseconds: 1199));
    expect(c.primaryId, 'p1');
    await tester.pump(const Duration(milliseconds: 2));
    expect(c.hasFocus, isFalse);
    c.dispose();
  });

  testWidgets('切换注视目标重置停留', (tester) async {
    final c = PanelFocusController(
      gazeDwell: const Duration(milliseconds: 600),
    );
    c.updateGaze('p1');
    await tester.pump(const Duration(milliseconds: 300));
    c.updateGaze('p2');
    await tester.pump(const Duration(milliseconds: 599));
    expect(c.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    expect(c.focusedIds, <String>{'p2'});
    c.dispose();
  });

  testWidgets('手动聚焦接管，注视释放不清手动焦点', (tester) async {
    final c = PanelFocusController(
      gazeDwell: const Duration(milliseconds: 100),
      gazeRelease: const Duration(milliseconds: 200),
    );
    c.updateGaze('p1');
    await tester.pump(const Duration(milliseconds: 101));
    expect(c.primaryId, 'p1');

    c.updateGaze(null);
    c.focus('p2');
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.primaryId, 'p2');

    c.updateGaze(null);
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.primaryId, 'p2');
    c.dispose();
  });

  testWidgets('注视命中的已手动聚焦格不被释放', (tester) async {
    final c = PanelFocusController(
      gazeDwell: const Duration(milliseconds: 100),
      gazeRelease: const Duration(milliseconds: 200),
    );
    c.focus('p2');
    c.updateGaze('p2');
    await tester.pump(const Duration(milliseconds: 101));
    c.updateGaze(null);
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.primaryId, 'p2');
    c.dispose();
  });

  testWidgets('clearGaze 立即释放注视焦点', (tester) async {
    final c = PanelFocusController(
      gazeDwell: const Duration(milliseconds: 100),
    );
    c.updateGaze('p1');
    await tester.pump(const Duration(milliseconds: 101));
    c.clearGaze();
    expect(c.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 101));
    expect(c.hasFocus, isFalse);
    c.dispose();
  });

  testWidgets('dispose 取消计时器', (tester) async {
    final c = PanelFocusController(
      gazeDwell: const Duration(milliseconds: 100),
      gazeRelease: const Duration(milliseconds: 200),
    );
    c.updateGaze('p1');
    c.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}
