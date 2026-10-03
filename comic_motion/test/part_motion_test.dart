import 'dart:convert';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// Plan B §2.3：`part_motion.json` 契约解析。
///
/// 红线：解析器**永不抛异常**（坏输入降级为 spec=null + warning），每个丢弃
/// 决定都必须留一行 warning（不静默），且同输入必得同输出（确定性）。
void main() {
  Map<String, dynamic> handPart({
    List<List<double>>? polygon,
    Map<String, dynamic>? anchor,
    String kind = 'hand',
    String? inpaint,
  }) =>
      {
        'kind': kind,
        'polygon': polygon ??
            [
              [0.10, 0.10],
              [0.30, 0.12],
              [0.28, 0.32],
              [0.12, 0.30],
            ],
        'anchor': anchor ?? {'x': 0.16, 'y': 0.28, 'joint': 'wrist'},
        if (inpaint != null) 'inpaint': inpaint,
      };

  String doc(List<Map<String, dynamic>> parts, {Object? version = 1}) =>
      jsonEncode({
        if (version != null) 'version': version,
        'parts': parts,
      });

  group('契约解析', () {
    test('合法单部件：解析成功且无 warning', () {
      final r = PartMotionParser.parse(doc([handPart()]));
      expect(r.spec, isNotNull);
      expect(r.warnings, isEmpty);
      expect(r.spec!.parts, hasLength(1));
      expect(r.spec!.parts.first.kind, PartKind.hand);
      expect(r.spec!.version, 1);
    });

    test('inpaint 缺省为 null，给出时原样保留', () {
      final a = PartMotionParser.parse(doc([handPart()]));
      expect(a.spec!.parts.single.inpaintPath, isNull);
      final b = PartMotionParser.parse(doc([handPart(inpaint: 'a/hand.png')]));
      expect(b.spec!.parts.single.inpaintPath, 'a/hand.png');
    });

    test('空 parts 是合法输入（无部件 = 无动作，不告警）', () {
      final r = PartMotionParser.parse(doc([]));
      expect(r.spec, isNotNull);
      expect(r.spec!.parts, isEmpty);
      expect(r.warnings, isEmpty);
    });

    test('未实现的 kind 照常解析，由渲染侧决定跳过', () {
      final r = PartMotionParser.parse(doc([
        handPart(kind: 'head'),
        handPart(kind: 'garment'),
      ]));
      expect(r.spec!.parts.map((p) => p.kind),
          [PartKind.head, PartKind.garment]);
      expect(PartKind.hand.isImplemented, isTrue);
      expect(PartKind.head.isImplemented, isFalse);
    });
  });

  group('整份拒绝', () {
    test('非法 JSON：spec=null 且不抛', () {
      final r = PartMotionParser.parse('{not json');
      expect(r.spec, isNull);
      expect(r.warnings, hasLength(1));
      expect(r.warnings.single, contains('part_motion'));
    });

    test('顶层不是对象：整份拒绝', () {
      final r = PartMotionParser.parse(jsonEncode([1, 2, 3]));
      expect(r.spec, isNull);
      expect(r.warnings.single, contains('version'));
    });

    test('version 缺失：整份拒绝（契约要求显式版本号）', () {
      final r = PartMotionParser.parse(
          jsonEncode({
        'parts': [handPart()]
      }));
      expect(r.spec, isNull);
      expect(r.warnings.single, contains('version'));
    });

    test('version=2（未来契约）：整份拒绝并说明支持范围', () {
      final r = PartMotionParser.parse(doc([handPart()], version: 2));
      expect(r.spec, isNull);
      expect(r.warnings.single, contains('2'));
      expect(r.warnings.single, contains('${PartMotionParser.supportedVersion}'));
    });

    test('parts 不是数组：整份拒绝', () {
      final r = PartMotionParser.parse(jsonEncode({
        'version': 1,
        'parts': {'kind': 'hand'}
      }));
      expect(r.spec, isNull);
      expect(r.warnings, hasLength(1));
    });
  });

  group('逐部件丢弃（其余部件保留）', () {
    test('未知 kind：丢弃该部件，warning 点名', () {
      final r = PartMotionParser.parse(doc([
        handPart(kind: 'wing'),
        handPart(),
      ]));
      expect(r.spec!.parts, hasLength(1));
      expect(r.warnings, hasLength(1));
      expect(r.warnings.single, contains('wing'));
    });

    test('多边形少于 3 点：丢弃', () {
      final r = PartMotionParser.parse(doc([
        handPart(polygon: [
          [0.1, 0.1],
          [0.2, 0.2],
        ]),
      ]));
      expect(r.spec!.parts, isEmpty);
      expect(r.warnings.single, contains('polygon'));
    });

    test('多边形共线（面积≈0）：丢弃', () {
      final r = PartMotionParser.parse(doc([
        handPart(polygon: [
          [0.1, 0.1],
          [0.5, 0.5],
          [0.9, 0.9],
        ]),
      ]));
      expect(r.spec!.parts, isEmpty);
      expect(r.warnings.single, contains('面积'));
    });

    test('坐标越界：丢弃（契约要求归一化 0..1）', () {
      final r = PartMotionParser.parse(doc([
        handPart(polygon: [
          [0.1, 0.1],
          [1.4, 0.2],
          [0.2, 0.9],
        ]),
      ]));
      expect(r.spec!.parts, isEmpty);
      expect(r.warnings.single, contains('归一'));
    });

    test('anchor 缺 x：丢弃', () {
      final r = PartMotionParser.parse(doc([
        handPart(anchor: {'y': 0.3, 'joint': 'wrist'}),
      ]));
      expect(r.spec!.parts, isEmpty);
      expect(r.warnings.single, contains('anchor'));
    });

    test('部件数超上限：截断并报告丢弃数量', () {
      final many = [
        for (var i = 0; i < PartMotionParser.maxParts + 3; i++) handPart()
      ];
      final r = PartMotionParser.parse(doc(many));
      expect(r.spec!.parts, hasLength(PartMotionParser.maxParts));
      expect(r.warnings.single, contains('3'));
    });

    test('丢弃不影响合法部件：一条 warning 对应一个被丢部件', () {
      final r = PartMotionParser.parse(doc([
        handPart(),
        handPart(kind: 'wing'),
        handPart(polygon: [
          [0.1, 0.1],
          [0.2, 0.2],
        ]),
      ]));
      expect(r.spec!.parts, hasLength(1));
      expect(r.warnings, hasLength(2));
    });
  });

  group('锚点修正', () {
    test('锚点在多边形内：不动、不告警', () {
      final r = PartMotionParser.parse(doc([
        handPart(anchor: {'x': 0.2, 'y': 0.2, 'joint': 'wrist'}),
      ]));
      final p = r.spec!.parts.single;
      expect(p.anchorX, closeTo(0.2, 1e-12));
      expect(p.anchorY, closeTo(0.2, 1e-12));
      expect(r.warnings, isEmpty);
    });

    test('锚点在多边形外：钳到最近顶点并告警', () {
      final r = PartMotionParser.parse(doc([
        handPart(anchor: {'x': 0.0, 'y': 0.35, 'joint': 'wrist'}),
      ]));
      final p = r.spec!.parts.single;
      expect([p.anchorX, p.anchorY], [0.12, 0.30]);
      expect(r.warnings.single, contains('anchor'));
    });
  });

  group('确定性', () {
    test('同输入两次解析：逐字段相同', () {
      final text = doc([
        handPart(),
        handPart(kind: 'hair'),
        handPart(kind: 'nope'),
      ]);
      final a = PartMotionParser.parse(text);
      final b = PartMotionParser.parse(text);
      expect(b.warnings, a.warnings);
      expect(b.spec!.parts.length, a.spec!.parts.length);
      for (var i = 0; i < a.spec!.parts.length; i++) {
        expect(b.spec!.parts[i].kind, a.spec!.parts[i].kind);
        expect(b.spec!.parts[i].anchorX, a.spec!.parts[i].anchorX);
        expect(b.spec!.parts[i].anchorY, a.spec!.parts[i].anchorY);
        expect(b.spec!.parts[i].polygon.map((p) => [p.x, p.y]).toList(),
            a.spec!.parts[i].polygon.map((p) => [p.x, p.y]).toList());
      }
    });

    test('joint 字段原样保留（三期按它选波形）', () {
      final r = PartMotionParser.parse(doc([
        handPart(anchor: {'x': 0.2, 'y': 0.2, 'joint': 'elbow'}),
      ]));
      expect(r.spec!.parts.single.joint, 'elbow');
    });
  });

  // Task 5 前置：契约只给 polygon + anchor（手腕），摆动轴的另一端必须由引擎
  // 确定性地推出来。衰减旋转的杠杆 = anchor→tip，故 tip 取「离锚点最远的顶点」。
  group('PartMotion 摆动轴推导', () {
    PartMotion quad(
            List<PartPoint> poly, double ax, double ay) =>
        PartMotion(
            kind: PartKind.hand,
            polygon: poly,
            anchorX: ax,
            anchorY: ay,
            joint: 'wrist');
    const box = [
      PartPoint(0.2, 0.2),
      PartPoint(0.8, 0.2),
      PartPoint(0.8, 0.9),
      PartPoint(0.2, 0.9),
    ];

    test('tipPoint = 离锚点最远的顶点', () {
      final t = quad(box, 0.2, 0.2).tipPoint;
      expect(t.x, 0.8);
      expect(t.y, 0.9);
    });

    test('等距平手取列表最靠前的顶点（确定性 tie-break）', () {
      // 坐标全取二进制可精确表示的四分之一，否则 0.8-0.5 与 0.5-0.2 在
      // IEEE-754 下差 1 ulp，压根不存在「平手」，测不到 tie-break。
      final square = const [
        PartPoint(0.25, 0.25),
        PartPoint(0.75, 0.25),
        PartPoint(0.75, 0.75),
        PartPoint(0.25, 0.75),
      ];
      final t = quad(square, 0.5, 0.5).tipPoint;
      expect(t.x, 0.25);
      expect(t.y, 0.25);
    });

    test('锚点落在多边形内部 ⇒ 轴长严格为正（退化会被 warper 判空）', () {
      final p = quad(box, 0.5, 0.5);
      final dx = p.tipPoint.x - p.anchorX, dy = p.tipPoint.y - p.anchorY;
      expect(dx * dx + dy * dy, greaterThan(0.0));
    });
  });
}
