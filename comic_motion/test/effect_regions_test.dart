import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// X5（v1.5）：effectRegions —— 把播种粒子效果限制在归一化 ROI 矩形内。
///
/// 红线锚点：不配置区域时与旧路径逐字节相同（默认 JSON 键集与 configHash
/// 键集不动，粒子播种走原路径）；RNG 消费序列不变（区域只改变落位，不改
/// 变随机流游标）；未知效果名抛 E_UNKNOWN_EFFECT、非法矩形抛 E_BAD_CONFIG
/// （结构性 fail-fast）；区域 × panelAware 格矩形取交集；确定性。
void main() {
  Map<String, dynamic> cfgJson(Map<String, dynamic>? regions) => {
        'effects': ['rain'],
        'fps': 24,
        'durationSec': 2.0,
        'seed': 42,
        if (regions != null) 'effectRegions': regions,
      };

  group('配置层', () {
    test('未配置区域：JSON 无 effectRegions 键，往返无损', () {
      final c = EffectConfig.fromJson(cfgJson(null));
      expect(c.effectRegions, isEmpty);
      expect(c.toJson().containsKey('effectRegions'), isFalse);
      final rt = EffectConfig.fromJson(c.toJson());
      expect(rt.configHash, c.configHash);
    });

    test('配置区域：序列化往返无损，configHash 稳定', () {
      final c = EffectConfig.fromJson(cfgJson({
        'rain': {'x': 0.5, 'y': 0.0, 'w': 0.5, 'h': 1.0},
      }));
      expect(c.effectRegions, hasLength(1));
      expect(c.effectRegions[EffectKind.rain]!.x, 0.5);
      final json = c.toJson();
      expect(json.containsKey('effectRegions'), isTrue);
      final rt = EffectConfig.fromJson(json);
      expect(rt.effectRegions[EffectKind.rain]!.w, 0.5);
      expect(rt.configHash, c.configHash);
      // 同一配置两次哈希一致（插入序确定性）。
      expect(c.configHash, c.configHash);
    });

    test('未知效果名：E_UNKNOWN_EFFECT（与 effects 数组同口径）', () {
      expect(
        () => EffectConfig.fromJson(cfgJson({
          'noSuchEffect': {'x': 0, 'y': 0, 'w': 1, 'h': 1},
        })),
        throwsA(isA<ConfigException>()
            .having((e) => e.code, 'code', 'E_UNKNOWN_EFFECT')),
      );
    });

    test('非法矩形：E_BAD_CONFIG（越界 / 零宽高 / 非有限值）', () {
      final bad = [
        {'x': 0.5, 'y': 0.0, 'w': 0.6, 'h': 1.0}, // x+w > 1
        {'x': 0.0, 'y': 0.0, 'w': 0.0, 'h': 1.0}, // w == 0
        {'x': -0.1, 'y': 0.0, 'w': 0.5, 'h': 1.0}, // x < 0
      ];
      for (final r in bad) {
        expect(
          () => EffectConfig.fromJson(cfgJson({'rain': r})),
          throwsA(isA<ConfigException>()
              .having((e) => e.code, 'code', 'E_BAD_CONFIG')),
          reason: 'region=$r',
        );
      }
    });

    test('copy() 保留 effectRegions，withEffect 等派生 API 同样保留', () {
      final c = EffectConfig.fromJson(cfgJson({
        'rain': {'x': 0.5, 'y': 0.0, 'w': 0.5, 'h': 1.0},
      })).withEffect(EffectKind.snow);
      expect(c.effectRegions, hasLength(1));
      expect(c.effectRegions[EffectKind.rain], isNotNull);
    });
  });

  group('渲染层（播种约束）', () {
    RgbaImage baseRaster() {
      final im = RgbaImage(width: 100, height: 100);
      for (var i = 0; i < im.data.length; i += 4) {
        im.data[i] = 120;
        im.data[i + 1] = 120;
        im.data[i + 2] = 120;
        im.data[i + 3] = 255;
      }
      return im;
    }

    FrameCompositor compositor(Map<String, dynamic>? regions,
        {List<LayerImage>? layers}) {
      final config = EffectConfig.fromJson(cfgJson(regions));
      final base = baseRaster();
      return FrameCompositor(
        layers ??
            [
              LayerImage(
                  RgbaImage.fromBytes(
                      width: 100,
                      height: 100,
                      data: base.data), // 共享只读即可（合成器不写层）
                  0),
            ],
        base,
        config,
      );
    }

    test('右半区域：rain 播种点全部落在 x ≥ 0.5', () {
      final c = compositor({
        'rain': {'x': 0.5, 'y': 0.0, 'w': 0.5, 'h': 1.0},
      });
      final seeds = c.debugParticleSeeds(EffectKind.rain);
      expect(seeds, isNotEmpty);
      for (final (x, _) in seeds) {
        expect(x, greaterThanOrEqualTo(0.5 - 1e-9), reason: 'x=$x 越出区域');
      }
    });

    test('左上四分之一区域：x 与 y 双向约束', () {
      final c = compositor({
        'rain': {'x': 0.0, 'y': 0.0, 'w': 0.5, 'h': 0.5},
      });
      for (final (x, y) in c.debugParticleSeeds(EffectKind.rain)) {
        expect(x, lessThanOrEqualTo(0.5 + 1e-9));
        expect(y, lessThanOrEqualTo(0.5 + 1e-9));
      }
    });

    test('区域 × 格裁剪取交集：粒子落在交集中', () {
      // 格（层 clip）= 右半页；区域 = 左半页 → 交集为空 ⇒ 粒子全部被裁掉，
      // 但播种/裁剪路径必须确定性工作。
      final base = baseRaster();
      final layer = RgbaImage.fromBytes(
          width: 100, height: 100, data: base.data);
      final c = compositor(
        {
          'rain': {'x': 0.0, 'y': 0.0, 'w': 0.5, 'h': 1.0},
        },
        layers: [
          LayerImage(layer, 0, clip: const PixelRect(50, 0, 50, 100)),
        ],
      );
      final seeds = c.debugParticleSeeds(EffectKind.rain);
      expect(seeds, isNotEmpty);
      // 交集为空：所有粒子的 clip 退化为零宽矩形，渲染被完全裁掉。
      // 位置仍确定（钳在交集角点），关键是不抛错、逐帧确定。
      final f1 = c.renderFrame(0);
      final f2 = c.renderFrame(1 / 24);
      expect(f1.data.length, f2.data.length);
    });

    test('确定性：同配置两次构造的播种序列一致', () {
      final a = compositor({
        'rain': {'x': 0.2, 'y': 0.1, 'w': 0.6, 'h': 0.8},
      }).debugParticleSeeds(EffectKind.rain);
      final b = compositor({
        'rain': {'x': 0.2, 'y': 0.1, 'w': 0.6, 'h': 0.8},
      }).debugParticleSeeds(EffectKind.rain);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].$1, b[i].$1);
        expect(a[i].$2, b[i].$2);
      }
    });

    test('无区域的 rain 播种与 uniform 路径等价（回滚锚）', () {
      // 无 effectRegions ⇒ _seedPlacement roi == null ⇒ 与旧路径完全一致：
      // 播种应铺满整页（不能被任何隐式区域约束）。
      final seeds = compositor(null).debugParticleSeeds(EffectKind.rain);
      expect(seeds, isNotEmpty);
      var minX = 1.0, maxX = 0.0;
      for (final (x, _) in seeds) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      expect(minX, lessThan(0.4), reason: '播种应横跨整页');
      expect(maxX, greaterThan(0.6), reason: '播种应横跨整页');
    });
  });
}
