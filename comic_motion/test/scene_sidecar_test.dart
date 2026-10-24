import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

void main() {
  group('SceneMotionParser 永不抛异常', () {
    test('坏 JSON → spec null + warning', () {
      final p = SceneMotionParser.parse('{not valid json');
      expect(p.spec, isNull);
      expect(p.warnings, isNotEmpty);
    });

    test('顶层非对象 → spec null + warning', () {
      final p = SceneMotionParser.parse('[1,2,3]');
      expect(p.spec, isNull);
      expect(p.warnings.join(' '), contains('scene'));
    });

    test('缺 version / version 不符 → 整份忽略', () {
      final noVer = SceneMotionParser.parse('{"panels":[]}');
      expect(noVer.spec, isNull);
      final badVer =
          SceneMotionParser.parse('{"version":99,"panels":[]}');
      expect(badVer.spec, isNull);
    });

    test('panels 非数组/为空 → 整份忽略', () {
      final p = SceneMotionParser.parse('{"version":1}');
      expect(p.spec, isNull);
      final q = SceneMotionParser.parse('{"version":1,"panels":[]}');
      expect(q.spec, isNull);
    });

    test('解析过程对任何输入不抛', () {
      const inputs = [
        '',
        'null',
        '"str"',
        '{"version":1,"panels":[{"x":"a"}]}',
        '{"version":1,"panels":[null,42,"x"]}',
      ];
      for (final s in inputs) {
        expect(() => SceneMotionParser.parse(s), returnsNormally,
            reason: '输入：$s');
      }
    });
  });

  group('SceneMotionParser 条目解析', () {
    test('motion:false → scale 0.0；motion:true → 1.0；显式 scale 透传', () {
      final p = SceneMotionParser.parse('''
{"version":1,"panels":[
  {"x":0,"y":0,"w":0.5,"h":1,"motion":false},
  {"x":0.5,"y":0,"w":0.5,"h":1,"motion":true},
  {"x":0,"y":0,"w":1,"h":1,"motion":true,"scale":0.5}
]}
''');
      expect(p.spec, isNotNull);
      expect(p.warnings, isEmpty);
      expect(p.spec!.panels[0].scale, 0.0);
      expect(p.spec!.panels[1].scale, 1.0);
      expect(p.spec!.panels[2].scale, 0.5);
    });

    test('缺 motion 与 scale 的条目 → 忽略 + warning', () {
      final p = SceneMotionParser.parse('''
{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1}]}
''');
      expect(p.spec, isNull);
      expect(p.warnings.join(' '), contains('scene'));
    });

    test('越界坐标条目忽略 + warning；scale 越界钳 [0,1] + warning', () {
      final p = SceneMotionParser.parse('''
{"version":1,"panels":[
  {"x":1.5,"y":0,"w":1,"h":1,"motion":false},
  {"x":0,"y":0,"w":0.5,"h":1,"motion":true,"scale":7}
]}
''');
      expect(p.spec, isNotNull);
      expect(p.spec!.panels, hasLength(1));
      expect(p.spec!.panels[0].scale, 1.0); // clamp(7,0,1)
      expect(p.warnings, isNotEmpty);
    });

    test('非有限数值条目忽略（NaN/Infinity 防御）', () {
      final p = SceneMotionParser.parse(
          '{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1,"scale":NaN}]}');
      expect(p.spec, isNull);
    });

    test('条数超上限截断 + warning', () {
      final buf = StringBuffer('{"version":1,"panels":[');
      for (var i = 0; i < SceneMotionSpec.maxPanels + 5; i++) {
        buf.write('{"x":0,"y":0,"w":0.1,"h":0.1,"motion":false},');
      }
      buf.write('{"x":0,"y":0,"w":0.1,"h":0.1,"motion":false}]}');
      final p = SceneMotionParser.parse(buf.toString());
      expect(p.spec, isNotNull);
      expect(p.spec!.panels.length, SceneMotionSpec.maxPanels);
      expect(p.warnings.join(' '), contains('上限'));
    });

    test('确定性：同文本两次解析结果一致', () {
      const text = '''
{"version":1,"panels":[
  {"x":0,"y":0,"w":0.4,"h":1,"motion":false},
  {"x":0.4,"y":0,"w":0.6,"h":1,"motion":true,"scale":0.25}
]}
''';
      final a = SceneMotionParser.parse(text);
      final b = SceneMotionParser.parse(text);
      expect(a.spec!.panels.length, b.spec!.panels.length);
      for (var i = 0; i < a.spec!.panels.length; i++) {
        expect(a.spec!.panels[i].x, b.spec!.panels[i].x);
        expect(a.spec!.panels[i].scale, b.spec!.panels[i].scale);
      }
      expect(a.warnings, b.warnings);
    });
  });

  group('SceneMotionSpec.panelScaleFor（IoU 匹配）', () {
    final spec =
        SceneMotionParser.parse('''
{"version":1,"panels":[
  {"x":0,"y":0,"w":0.5,"h":1,"motion":false},
  {"x":0.5,"y":0,"w":0.5,"h":1,"motion":true}
]}
''')
            .spec!;

    test('命中（IoU ≥ 阈值）→ 侧车 scale（侧车优先于启发式的前提）', () {
      // 画布 24x10 的左半格 (0,0,12,10) 归一化 (0,0,0.5,1)，与条目 0 重合。
      final s = spec
          .panelScaleFor(const PixelRect(0, 0, 12, 10), 24, 10);
      expect(s, 0.0);
      final s2 = spec
          .panelScaleFor(const PixelRect(12, 0, 12, 10), 24, 10);
      expect(s2, 1.0);
    });

    test('无重叠 / IoU 低于阈值 → null（回落启发式）', () {
      // 整页矩形与任何半页条目 IoU = 0.5/1.0 = 0.5 ≥ 0.3？——整页 (0,0,24,10)
      // 与条目 0 的交 = 0.5×1，并 = 1×1 → IoU 0.5 命中条目 0；与条目 1 同理。
      // 取最大 IoU 并列时取先出现者（确定性）。这里只验证命中语义。
      final whole = spec
          .panelScaleFor(const PixelRect(0, 0, 24, 10), 24, 10);
      expect(whole, 0.0); // 并列 → 输入序在前者胜
      // 深夜角落小矩形与所有条目 IoU 过低 → null。
      final corner = spec
          .panelScaleFor(const PixelRect(6, 3, 2, 2), 24, 10);
      expect(corner, isNull);
    });

    test('空 spec（无侧车）→ null', () {
      const empty = SceneMotionSpec(1, []);
      expect(
          empty.panelScaleFor(const PixelRect(0, 0, 10, 10), 10, 10), isNull);
    });
  });

  group('IoU 辅助函数', () {
    test('全同 → 1；相离 → 0；半叠 → 面积比正确', () {
      const a = SidecarScenePanel(0, 0, 0.5, 0.5, 1.0);
      expect(sceneIou(a, a, 1.0, 1.0), closeTo(1.0, 1e-9));
      const b = SidecarScenePanel(0.8, 0.8, 0.2, 0.2, 1.0);
      expect(sceneIou(a, b, 1.0, 1.0), 0.0);
      const c = SidecarScenePanel(0.25, 0, 0.5, 0.5, 1.0);
      // 交 0.25×0.5=0.125，并 0.25+0.25-0.125=0.375 → 1/3
      expect(sceneIou(a, c, 1.0, 1.0), closeTo(0.125 / 0.375, 1e-9));
    });
  });
}
