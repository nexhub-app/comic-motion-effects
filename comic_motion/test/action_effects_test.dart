import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// X6（v1.5）：动作动效四件套 —— slashFlash / sparkBurst / impactDust /
/// windStreak。
///
/// 红线锚点：opt-in（不进默认效果集，默认 JSON 键集与 configHash 不动）；
/// standard+ 档渲染、legacy 档整效果跳过（handMotion 同款裁决习语）；窗口
/// 式包络两端归零 ⇒ 循环无缝（首尾帧一致）；sparkBurst/impactDust 焦点吃
/// contentAware 锚点（显式 pin 优先）；windStreak 泳道走播种管线（ROI/
/// 分格约束生效）；确定性（独立随机流，同 seed 同参数逐字节一致）。
void main() {
  RgbaImage baseRaster({int w = 120, int h = 90}) {
    final im = RgbaImage(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        im.data[o] = (x * 255) ~/ w;
        im.data[o + 1] = (y * 255) ~/ h;
        im.data[o + 2] = 128;
        im.data[o + 3] = 255;
      }
    }
    return im;
  }

  EffectConfig cfg(List<String> effects, [Map<String, dynamic>? params]) =>
      EffectConfig.fromJson({
        'effects': effects,
        'fps': 24,
        'durationSec': 2.0,
        'seed': 42,
        for (final e in params?.entries ?? const <MapEntry<String, dynamic>>[])
          e.key: e.value,
      });

  /// 首尾帧逐字节一致（循环无缝的必要条件）。
  void expectSeamless(EffectConfig config) {
    final c = FrameCompositor(
      [LayerImage(baseRaster(), 0)],
      baseRaster(),
      config,
    );
    final first = c.renderFrame(0);
    final u1 = c.renderFrame(config.durationSec);
    expect(u1.data, first.data, reason: 'u=0 与 u=1 帧必须逐字节一致（无缝）');
    expect(first.data.length, 120 * 90 * 4);
  }

  group('配置层（opt-in 契约）', () {
    test('默认效果集不含新效果，JSON 键集不变', () {
      final c = EffectConfig();
      expect(c.effects.contains(EffectKind.slashFlash), isFalse);
      expect(c.toJson().containsKey('slashFlash'), isFalse);
      expect(c.toJson().containsKey('sparkBurst'), isFalse);
      expect(c.toJson().containsKey('impactDust'), isFalse);
      expect(c.toJson().containsKey('windStreak'), isFalse);
    });

    test('启用后条件序列化 + 往返无损', () {
      final c = EffectConfig.fromJson({
        'effects': ['slashFlash', 'sparkBurst', 'impactDust', 'windStreak'],
        'slashFlash': {'flashes': 3, 'intensity': 0.5},
        'sparkBurst': {'bursts': 4},
        'impactDust': {'puffs': 8},
        'windStreak': {'count': 5, 'angleDeg': -15.0},
      });
      final json = c.toJson();
      expect((json['slashFlash'] as Map)['flashes'], 3);
      expect((json['windStreak'] as Map)['angleDeg'], -15.0);
      final rt = EffectConfig.fromJson(json);
      expect(rt.slashFlash.flashes, 3);
      expect(rt.sparkBurst.bursts, 4);
      expect(rt.impactDust.puffs, 8);
      expect(rt.windStreak.count, 5);
      expect(rt.configHash, c.configHash);
    });

    test('copy()/withEffect 保留参数对象', () {
      final c = cfg(['slashFlash']).withEffect(EffectKind.sparkBurst);
      expect(c.effects, containsAll([EffectKind.slashFlash, EffectKind.sparkBurst]));
    });
  });

  group('渲染层', () {
    test('四个效果逐帧渲染确定（同配置双实例逐字节一致）', () {
      final effects = [
        ['slashFlash'],
        ['sparkBurst'],
        ['impactDust'],
        ['windStreak'],
        ['slashFlash', 'sparkBurst', 'impactDust', 'windStreak'],
      ];
      for (final fx in effects) {
        final config = cfg(fx);
        FrameCompositor mk() => FrameCompositor(
            [LayerImage(baseRaster(), 0)], baseRaster(), config);
        for (final t in [0.0, 7 / 24, 0.5]) {
          expect(mk().renderFrame(t).data, mk().renderFrame(t).data,
              reason: 'effects=$fx t=$t');
        }
      }
    });

    test('循环无缝：u=0 与 u=1 逐字节一致', () {
      for (final fx in [
        ['slashFlash'],
        ['sparkBurst'],
        ['impactDust'],
        ['windStreak'],
      ]) {
        expectSeamless(cfg(fx));
      }
    });

    test('确实改变了画面：开启效果后的帧与纯底图帧不同', () {
      final plain = cfg([]); // 全空效果 = 静帧
      final base = baseRaster();
      final plainFrame = FrameCompositor(
              [LayerImage(baseRaster(), 0)], base, plain)
          .renderFrame(1 / 24);
      // t=1/24：四个效果的窗口包络都处于可见相位。
      for (final fx in [
        ['slashFlash'],
        ['sparkBurst'],
        ['impactDust'],
        ['windStreak'],
      ]) {
        final f = FrameCompositor(
                [LayerImage(baseRaster(), 0)], baseRaster(), cfg(fx))
            .renderFrame(1 / 24);
        var diff = false;
        for (var i = 0; i < f.data.length && !diff; i++) {
          if (f.data[i] != plainFrame.data[i]) diff = true;
        }
        expect(diff, isTrue, reason: '$fx 必须画出可见像素');
      }
    });

    test('sparkBurst 焦点吃 contentAware 锚点；显式 pin 优先', () {
      // 无显式焦点 + contentAware（默认开）+ 无锚点输入 ⇒ 管线未给 anchors
      // 时回落参数默认 (0.5, 0.5)。
      final c1 = FrameCompositor([LayerImage(baseRaster(), 0)], baseRaster(),
          cfg(['sparkBurst']));
      expect(c1.debugActionFocal(EffectKind.sparkBurst).fx, 0.5);
      // 注入 anchors：焦点应收敛到权重最高锚点。
      final map = AnchorMap(
        8,
        8,
        Float64List(64),
        const PixelRect(0, 0, 8, 8),
        const [Anchor(0.25, 0.75, 0.9), Anchor(0.75, 0.25, 0.4)],
        const [PixelRect(0, 0, 120, 90)],
      );
      final c2 = FrameCompositor([LayerImage(baseRaster(), 0)], baseRaster(),
          cfg(['sparkBurst']),
          anchors: map);
      final f = c2.debugActionFocal(EffectKind.sparkBurst);
      expect(f.fx, 0.25);
      expect(f.fy, 0.75);
      // 显式 pin（非默认 focal）覆盖锚点。
      final c3 = FrameCompositor(
          [LayerImage(baseRaster(), 0)],
          baseRaster(),
          cfg(['sparkBurst'], {
            'sparkBurst': {'focalX': 0.1, 'focalY': 0.2},
          }),
          anchors: map);
      final f3 = c3.debugActionFocal(EffectKind.sparkBurst);
      expect(f3.fx, 0.1);
      expect(f3.fy, 0.2);
    });

    test('windStreak 泳道吃 effectRegions ROI', () {
      final config = EffectConfig.fromJson({
        'effects': ['windStreak'],
        'fps': 24,
        'durationSec': 2.0,
        'seed': 42,
        'effectRegions': {
          'windStreak': {'x': 0.0, 'y': 0.6, 'w': 1.0, 'h': 0.4},
        },
      });
      final c = FrameCompositor(
          [LayerImage(baseRaster(), 0)], baseRaster(), config);
      for (final (_, y) in c.debugParticleSeeds(EffectKind.windStreak)) {
        expect(y, greaterThanOrEqualTo(0.6 - 1e-9), reason: 'y=$y 越出 ROI');
      }
    });

    test('legacy 档：效果整体跳过（渲染零成本，输出 = 纯层栈）', () {
      final base = baseRaster();
      final legacyConfig = EffectConfig.fromJson({
        'effects': ['slashFlash', 'sparkBurst', 'impactDust', 'windStreak'],
        'quality': {'tier': 'legacy'},
        'fps': 24,
        'durationSec': 2.0,
        'seed': 42,
      });
      final plainConfig = EffectConfig.fromJson({
        'effects': [],
        'quality': {'tier': 'legacy'},
        'fps': 24,
        'durationSec': 2.0,
        'seed': 42,
      });
      final f1 = FrameCompositor(
              [LayerImage(baseRaster(), 0)], base, legacyConfig)
          .renderFrame(0.3);
      final f2 = FrameCompositor(
              [LayerImage(baseRaster(), 0)], base, plainConfig)
          .renderFrame(0.3);
      expect(f1.data, f2.data, reason: 'legacy 档新效果必须整体跳过');
    });
  });
}
