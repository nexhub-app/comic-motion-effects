import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// X3（v1.5）：`anchors.json` 显著性侧车 —— 解析契约、估算器适配与管线注入。
///
/// 红线锚点：解析器**永不抛**（坏输入降级 null spec + warning，与
/// PartMotionParser 同族三约束：永不抛 / 不静默 / 确定性）；侧车是运行期
/// 输入，不进 configHash；优先级 侧车 > SaliencyEstimator 注入 > 内置启发式；
/// 不给侧车时既有路径逐字节零变化（全量字节契约测试群兜底）；
/// contentAware=false 时侧车与启发式一并关闭。
void main() {
  group('AnchorsSpecParser：解析契约', () {
    test('合法侧车：anchors 按 weight 降序、并列按输入序', () {
      final p = AnchorsSpecParser.parse(jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.1, 'y': 0.2, 'weight': 0.4},
          {'x': 0.3, 'y': 0.4, 'weight': 0.9},
          {'x': 0.5, 'y': 0.6, 'weight': 0.4},
        ],
      }));
      expect(p.warnings, isEmpty);
      expect(p.spec, isNotNull);
      final list = p.spec!.anchors;
      expect(list, hasLength(3));
      expect(list[0].x, 0.3, reason: 'weight 0.9 最高');
      expect(list[1].y, 0.2, reason: 'weight 并列 0.4，输入序在前者先');
      expect(list[2].y, 0.6);
    });

    test('坏 JSON / 顶层非对象 / 缺 version / 版本不符：整份忽略 + warning', () {
      for (final bad in [
        'not json {',
        '[1,2,3]',
        '{"anchors":[]}',
        '{"version":2,"anchors":[{"x":0.1,"y":0.1,"weight":1}]}',
      ]) {
        final p = AnchorsSpecParser.parse(bad);
        expect(p.spec, isNull, reason: bad);
        expect(p.warnings, isNotEmpty, reason: bad);
      }
    });

    test('坐标越界 / 非数值 / 非有限：单条丢弃 + warning，不整份拒绝', () {
      final p = AnchorsSpecParser.parse(jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 1.5, 'y': 0.2, 'weight': 0.5},
          {'x': 0.1, 'weight': 0.5},
          {'x': 'a', 'y': 0.2, 'weight': 0.5},
          {'x': 0.7, 'y': 0.8, 'weight': 1.0},
        ],
      }));
      expect(p.spec, isNotNull);
      expect(p.spec!.anchors, hasLength(1));
      expect(p.spec!.anchors.first.x, 0.7);
      expect(p.warnings, hasLength(3));
    });

    test('条数超上限 16：截断 + warning', () {
      final anchors = [
        for (var i = 0; i < 20; i++)
          {'x': i / 40, 'y': 0.5, 'weight': 0.5},
      ];
      final p = AnchorsSpecParser.parse(
          jsonEncode({'version': 1, 'anchors': anchors}));
      expect(p.spec!.anchors, hasLength(16));
      expect(p.warnings, hasLength(1), reason: '一条截断告警');
    });

    test('weight 越界钳到 [0,1] + warning；subjectBox 非法整字段忽略', () {
      final p = AnchorsSpecParser.parse(jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.5, 'y': 0.5, 'weight': 2.0},
        ],
        'subjectBox': {'x': 0.8, 'y': 0.8, 'w': 0.5, 'h': 0.5},
      }));
      expect(p.spec!.anchors.first.weight, 1.0);
      expect(p.spec!.subjectBox, isNull, reason: 'x+w 越界，整字段忽略');
      expect(p.warnings, hasLength(2));
    });

    test('activity 网格：尺寸/长度非法整网格忽略；合法时保留并钳值', () {
      final bad = AnchorsSpecParser.parse(jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.5, 'y': 0.5, 'weight': 0.5},
        ],
        'activity': {'width': 2, 'height': 2, 'values': [0.1, 0.2, 0.3]},
      }));
      expect(bad.spec!.activity, isNull);
      expect(bad.warnings, isNotEmpty);

      final good = AnchorsSpecParser.parse(jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.5, 'y': 0.5, 'weight': 0.5},
        ],
        'activity': {
          'width': 2,
          'height': 2,
          'values': [0.0, 0.5, 1.7, 0.2],
        },
      }));
      expect(good.spec!.activity, isNotNull);
      expect(good.spec!.activity![2], 1.0, reason: '1.7 钳到 1.0');
    });

    test('确定性：同文本两次解析结果一致；永不抛（模糊垃圾输入）', () {
      final text = jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.25, 'y': 0.75, 'weight': 0.8},
        ],
        'activity': {
          'width': 2,
          'height': 2,
          'values': [0.0, 0.5, 1.0, 0.2],
        },
      });
      final a = AnchorsSpecParser.parse(text);
      final b = AnchorsSpecParser.parse(text);
      expect(a.spec!.anchors.first.x, b.spec!.anchors.first.x);
      expect(a.spec!.activity, b.spec!.activity);
      for (final garbage in ['', '{}', 'null', '123', '{"version":1}']) {
        expect(() => AnchorsSpecParser.parse(garbage), returnsNormally);
      }
    });
  });

  group('AnchorsSpec.toAnchorMap / 估算器适配', () {
    test('归一化 → 画布像素换算 + 无网格时加权回落', () {
      final spec = AnchorsSpecParser.parse(jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.5, 'y': 0.25, 'weight': 1.0},
        ],
        'subjectBox': {'x': 0.2, 'y': 0.1, 'w': 0.4, 'h': 0.3},
      })).spec!;
      final map = spec.toAnchorMap(200, 100);
      expect(map.width, 0, reason: '无网格 ⇒ width 0（加权检测自然回落）');
      expect(map.anchors.first.nx, 0.5);
      expect(map.anchors.first.ny, 0.25);
      expect(map.subjectBox.x, 40, reason: '0.2 × 200');
      expect(map.subjectBox.y, 10, reason: '0.1 × 100');
      expect(map.subjectBox.width, 80, reason: '0.4 × 200');
      expect(map.subjectBox.height, 30, reason: '0.3 × 100');

      final estimator = SidecarSaliencyEstimator(spec);
      final img = RgbaImage(width: 64, height: 48);
      final m2 = estimator.analyze(img);
      expect(m2.width, 0);
      expect(m2.anchors.first.ny, 0.25);
    });

    test('有网格时 AnchorMap 携带活动度（驱动粒子加权）', () {
      final spec = AnchorsSpecParser.parse(jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.5, 'y': 0.5, 'weight': 1.0},
        ],
        'activity': {
          'width': 4,
          'height': 4,
          'values': [for (var i = 0; i < 16; i++) i / 16],
        },
      })).spec!;
      final map = spec.toAnchorMap(100, 100);
      expect(map.width, 4);
      expect(map.height, 4);
      expect(map.activity.length, 16);
      expect(map.activity[15], closeTo(15 / 16, 1e-9));
    });
  });

  group('MotionPipeline 注入', () {
    Uint8List pngBytes() {
      // 128×128 非对称灰阶图：焦点类效果落在不同位置 ⇒ 字节不同。
      final img = RgbaImage(width: 128, height: 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          final o = (y * 128 + x) * 4;
          img.data[o] = x;
          img.data[o + 1] = y;
          img.data[o + 2] = 90;
          img.data[o + 3] = 255;
        }
      }
      return Uint8List.fromList(ImageIO.encodePngFrame(img));
    }

    Map<String, dynamic> cfgJson() => {
          'effects': ['focusLines'],
          'fps': 12,
          'durationSec': 1.0,
          'maxDimension': 128,
          'seed': 7,
        };

    test('anchorsDigest：稳定 8 位十六进制；不给侧车为 null', () async {
      final sidecar = jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.3, 'y': 0.7, 'weight': 1.0},
        ],
      });
      final bytes = pngBytes();
      final p1 = MotionPipeline(EffectConfig.fromJson(cfgJson()),
          anchors: sidecar);
      final r1 = await p1.processBytes(input: bytes);
      final r2 = await MotionPipeline(EffectConfig.fromJson(cfgJson()),
              anchors: sidecar)
          .processBytes(input: bytes);
      expect(r1.anchorsDigest, isNotNull);
      expect(r1.anchorsDigest, r2.anchorsDigest);
      expect(r1.anchorsDigest!.length, 8);
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(r1.anchorsDigest!), isTrue);
      expect(p1.effectiveAnchors, isNotNull);

      final p0 = MotionPipeline(EffectConfig.fromJson(cfgJson()));
      final r0 = await p0.processBytes(input: bytes);
      expect(r0.anchorsDigest, isNull);
      expect(p0.effectiveAnchors, isNull);
      expect(r0.warnings, isEmpty);
    });

    test('侧车改变落位：不同锚点 ⇒ 产物字节不同（端到端）', () async {
      final bytes = pngBytes();
      final cfg = EffectConfig.fromJson(cfgJson());
      final a = await MotionPipeline(
              cfg, anchors: jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.2, 'y': 0.2, 'weight': 1.0},
        ],
      }))
          .processBytes(input: bytes);
      final b = await MotionPipeline(
              cfg, anchors: jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.8, 'y': 0.8, 'weight': 1.0},
        ],
      }))
          .processBytes(input: bytes);
      expect(a.gifBytes, isNotNull);
      expect(b.gifBytes, isNotNull);
      expect(b.gifBytes, isNot(equals(a.gifBytes)),
          reason: '焦点不同的两份侧车必须产生不同画面');
    });

    test('坏侧车：永不失败，warning 冒泡到结果', () async {
      final r = await MotionPipeline(EffectConfig.fromJson(cfgJson()),
              anchors: 'garbage{{{')
          .processBytes(input: pngBytes());
      expect(r.anchorsDigest, isNotNull, reason: '侧车给了就有指纹');
      expect(r.warnings, isNotEmpty);
      expect(r.warnings.first, contains('anchors'));
    });

    test('contentAware=false：侧车被忽略，产物与无侧车一致', () async {
      final bytes = pngBytes();
      final sidecar = jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.2, 'y': 0.2, 'weight': 1.0},
        ],
      });
      final cfgOff = EffectConfig.fromJson({
        ...cfgJson(),
        'contentAware': false,
      });
      final a = await MotionPipeline(cfgOff).processBytes(input: bytes);
      final b = await MotionPipeline(cfgOff, anchors: sidecar)
          .processBytes(input: bytes);
      expect(b.gifBytes, equals(a.gifBytes));
    });

    test('SaliencyEstimator 注入：默认 == 内置启发式（逐字节）', () async {
      final bytes = pngBytes();
      final cfg = EffectConfig.fromJson(cfgJson());
      final a = await MotionPipeline(cfg).processBytes(input: bytes);
      final b = await MotionPipeline(cfg,
              saliencyEstimator: const SaliencyAnalyzer())
          .processBytes(input: bytes);
      expect(b.gifBytes, equals(a.gifBytes),
          reason: '显式注入内置实现 == 缺省路径（DepthEstimator 同款验收）');
    });
  });
}
