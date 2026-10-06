import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// X7（v1.5）：autoCurate 内容感知效果量调节 —— 按页面活动度缩放播种粒子
/// 族总量；近空白页整体跳过叠加粒子。
///
/// 红线锚点：opt-in（默认 false，条件序列化 ⇒ 默认 JSON 键集与 configHash
/// 键集不动）；判定只在构造期做一次（确定性、不影响无缝循环）；依赖
/// contentAware 的 AnchorMap，contentAware=false 时零行为变化；忙页满配
/// （系数上限 1.0）⇒ 与关闭状态产出一致。
void main() {
  /// coverage ∈ [0,1]：暗色内容块的面积占比（其余近白）。
  RgbaImage page({required double coverage, int w = 160, int h = 120}) {
    final im = RgbaImage(width: w, height: h);
    final darkPixels = (w * h * coverage).round();
    var painted = 0;
    for (var y = 0; y < h && painted < darkPixels; y++) {
      for (var x = 0; x < w && painted < darkPixels; x++) {
        final o = (y * w + x) * 4;
        im.data[o] = 20;
        im.data[o + 1] = 20;
        im.data[o + 2] = 20;
        painted++;
      }
    }
    // 其余像素近白。
    for (var i = 0; i < im.data.length; i += 4) {
      if (im.data[i] == 20 && im.data[i + 1] == 20 && im.data[i + 2] == 20) {
        continue;
      }
      im.data[i] = 250;
      im.data[i + 1] = 250;
      im.data[i + 2] = 250;
      im.data[i + 3] = 255;
    }
    for (var i = 0; i < im.data.length; i += 4) {
      im.data[i + 3] = 255;
    }
    return im;
  }

  Map<String, dynamic> cfgJson({required bool curate, bool contentAware = true}) =>
      {
        'effects': ['rain', 'snow', 'sakura', 'ambient'],
        'fps': 24,
        'durationSec': 2.0,
        'seed': 42,
        if (curate) 'autoCurate': true,
        if (!contentAware) 'contentAware': false,
      };

  FrameCompositor compositor(RgbaImage base, Map<String, dynamic> json) {
    final config = EffectConfig.fromJson(json);
    // 与管线同源：contentAware 开启时由 SaliencyAnalyzer 生成 AnchorMap
    // 再注入合成器（管线内由 _downscaleAndSplit 完成，直接构造需自带）。
    final anchors =
        config.contentAware ? const SaliencyAnalyzer().analyze(base) : null;
    return FrameCompositor(
      [
        LayerImage(
            RgbaImage.fromBytes(
                width: base.width, height: base.height, data: base.data),
            0),
      ],
      base,
      config,
      anchors: anchors,
    );
  }

  group('配置层', () {
    test('默认关闭：JSON 无 autoCurate 键，往返无损', () {
      final c = EffectConfig.fromJson(cfgJson(curate: false));
      expect(c.autoCurate, isFalse);
      expect(c.toJson().containsKey('autoCurate'), isFalse);
      expect(EffectConfig.fromJson(c.toJson()).configHash, c.configHash);
    });

    test('显式开启：写出键；非布尔值按 false 处理（sanitize 口径同 reducedMotion）',
        () {
      final on = EffectConfig.fromJson(cfgJson(curate: true));
      expect(on.autoCurate, isTrue);
      expect(on.toJson()['autoCurate'], true);
      expect(EffectConfig.fromJson(on.toJson()).configHash, on.configHash);
      final junk = EffectConfig.fromJson({
        ...cfgJson(curate: false),
        'autoCurate': 'yes',
      });
      expect(junk.autoCurate, isFalse, reason: '非严格布尔 true ⇒ 关闭');
    });
  });

  group('渲染层', () {
    test('默认关闭：粒子数量与参数一致（零行为变化）', () {
      final c = compositor(page(coverage: 0.5), cfgJson(curate: false));
      // rain 默认 count：RainParams().count（框架内 clamp 后原样）。
      final seeds = c.debugParticleSeeds(EffectKind.rain);
      expect(seeds, hasLength(const RainParams().count));
      expect(c.debugParticleSeeds(EffectKind.snow),
          hasLength(const SnowParams().count));
    });

    test('忙页（coverage 0.5）：系数达到上限 1.0 ⇒ 数量与关闭时一致', () {
      final busy = page(coverage: 0.5);
      final off = compositor(busy, cfgJson(curate: false));
      final on = compositor(busy, cfgJson(curate: true));
      expect(on.debugParticleSeeds(EffectKind.rain).length,
          off.debugParticleSeeds(EffectKind.rain).length,
          reason: 'mean ≥ 0.12 的忙页不被缩量');
    });

    test('静页（coverage 0.08）：粒子收敛但不归零，且数量确定', () {
      final quiet = page(coverage: 0.08);
      final on = compositor(quiet, cfgJson(curate: true));
      final n = on.debugParticleSeeds(EffectKind.rain).length;
      expect(n, greaterThan(0), reason: '0.02 ≤ mean ⇒ 只缩量不清零');
      expect(n, lessThan(const RainParams().count), reason: '静页应收敛');
      final on2 = compositor(quiet, cfgJson(curate: true));
      expect(on2.debugParticleSeeds(EffectKind.rain).length, n,
          reason: '同页同配置确定性');
    });

    test('近空白页（coverage 0）：叠加粒子整体跳过，渲染照常出图', () {
      final blank = page(coverage: 0.0);
      final on = compositor(blank, cfgJson(curate: true));
      expect(on.debugParticleSeeds(EffectKind.rain), isEmpty);
      expect(on.debugParticleSeeds(EffectKind.snow), isEmpty);
      expect(on.debugParticleSeeds(EffectKind.sakura), isEmpty);
      expect(on.debugParticleSeeds(EffectKind.ambient), isEmpty);
      final f = on.renderFrame(0.5);
      expect(f.data.length, 160 * 120 * 4);
    });

    test('contentAware=false：autoCurate 不生效（数量与关闭时一致）', () {
      final busy = page(coverage: 0.0);
      final off = compositor(
          busy, cfgJson(curate: false, contentAware: false));
      final on = compositor(busy, cfgJson(curate: true, contentAware: false));
      expect(on.debugParticleSeeds(EffectKind.rain).length,
          off.debugParticleSeeds(EffectKind.rain).length);
    });
  });
}
