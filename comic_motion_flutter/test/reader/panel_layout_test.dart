import 'dart:ui';

import 'package:comic_motion_flutter/reader.dart';
import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';

PanelSpec _panel(String id, Rect rect) => PanelSpec(id: id, rect: rect);

PanelLayout _layout({
  Rect available = const Rect.fromLTWH(0, 0, 200, 100),
  Size image = const Size(100, 200),
  BoxFit fit = BoxFit.contain,
  int quarterTurns = 0,
  List<PanelSpec>? panels,
}) =>
    PanelLayout.resolve(
      availableRect: available,
      imageSize: image,
      panels: panels ?? <PanelSpec>[_panel('p', const Rect.fromLTRB(0.1, 0.1, 0.5, 0.5))],
      fit: fit,
      quarterTurns: quarterTurns,
    );

void main() {
  test('contain 居中并映射分格', () {
    final layout = _layout();
    expect(layout.pageRect, const Rect.fromLTWH(75, 0, 50, 100));
    expect(layout.panelRects['p'], const Rect.fromLTWH(80, 10, 20, 40));
    expect(layout.hitTest(const Offset(90, 20)), 'p');
    expect(layout.hitTest(const Offset(10, 20)), isNull);
  });

  test('各 BoxFit 的显示矩形', () {
    expect(_layout(fit: BoxFit.fitWidth).pageRect,
        const Rect.fromLTWH(0, -150, 200, 400));
    expect(_layout(fit: BoxFit.fitHeight).pageRect,
        const Rect.fromLTWH(75, 0, 50, 100));
    expect(_layout(fit: BoxFit.cover).pageRect,
        const Rect.fromLTWH(0, -150, 200, 400));
    expect(_layout(fit: BoxFit.fill).pageRect,
        const Rect.fromLTWH(0, 0, 200, 100));
    expect(_layout(fit: BoxFit.none).pageRect,
        const Rect.fromLTWH(50, -50, 100, 200));
    expect(_layout(fit: BoxFit.scaleDown).pageRect,
        const Rect.fromLTWH(75, 0, 50, 100));
    expect(
      _layout(
        image: const Size(50, 50),
        fit: BoxFit.scaleDown,
      ).pageRect,
      const Rect.fromLTWH(75, 25, 50, 50),
    );
  });

  test('quarterTurns 顺时针映射分格', () {
    // 100×200 竖图在 200×200 内 contain：q0/q2 页面 100×200 居中（50,0），
    // q1/q3 交换宽高后页面 200×100 居中（0,50）。
    final expected = <int, Rect>{
      0: const Rect.fromLTWH(60, 20, 40, 80),
      1: const Rect.fromLTWH(100, 60, 80, 40),
      2: const Rect.fromLTWH(100, 100, 40, 80),
      3: const Rect.fromLTWH(20, 100, 80, 40),
    };
    for (final q in expected.keys) {
      final layout = _layout(
        available: const Rect.fromLTWH(0, 0, 200, 200),
        quarterTurns: q,
      );
      expect(
          layout.pageRect,
          q.isOdd
              ? const Rect.fromLTWH(0, 50, 200, 100)
              : const Rect.fromLTWH(50, 0, 100, 200),
          reason: 'q=$q');
      expect(layout.panelRects['p'], expected[q], reason: 'q=$q');
    }
  });

  test('旋转 90° 后显示尺寸交换宽高', () {
    final layout = _layout(
      available: const Rect.fromLTWH(0, 0, 200, 200),
      quarterTurns: 1,
    );
    expect(layout.pageRect.width, 200);
    expect(layout.pageRect.height, 100);
  });

  test('命中不越过可用区域', () {
    final layout = _layout(fit: BoxFit.fitWidth);
    // pageRect 上下溢出（20,-110,80,160）；可用区域外的点不算命中。
    expect(layout.hitTest(const Offset(90, 20)), 'p');
    expect(layout.hitTest(const Offset(90, -10)), isNull);
  });

  test('重叠取面积最小，面积相同取后者', () {
    final layout = _layout(
      fit: BoxFit.fill,
      panels: <PanelSpec>[
        _panel('big', const Rect.fromLTRB(0, 0, 1, 1)),
        _panel('small', const Rect.fromLTRB(0.2, 0.2, 0.4, 0.4)),
      ],
    );
    expect(layout.hitTest(const Offset(60, 30)), 'small');

    final tie = _layout(
      fit: BoxFit.fill,
      panels: <PanelSpec>[
        _panel('first', const Rect.fromLTRB(0.2, 0.2, 0.6, 0.6)),
        _panel('second', const Rect.fromLTRB(0.2, 0.2, 0.6, 0.6)),
      ],
    );
    expect(tie.hitTest(const Offset(60, 30)), 'second');
  });

  test('负 quarterTurns 归一化', () {
    final layout = _layout(
      available: const Rect.fromLTWH(0, 0, 200, 200),
      quarterTurns: -1,
    );
    expect(layout.panelRects['p'], const Rect.fromLTWH(20, 100, 80, 40));
  });
}
