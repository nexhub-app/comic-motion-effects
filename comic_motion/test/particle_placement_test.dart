import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:comic_motion/comic_motion.dart';

/// Task 2.2 — activity-weighted particle seeding (rejection sampling).
///
/// All randomness stays seeded from `EffectConfig.seed`; these tests pin the
/// real behavior: seeds bias into high-`activity` regions, the default/legacy
/// (contentAware=false) render stays byte-for-byte unchanged, exact particle
/// `count` is preserved, the ON render is deterministic, and a blank/flat
/// activity field falls back to the original uniform distribution.
RgbaImage blankPage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var i = 0; i < img.pixelCount; i++) {
    img.setPixel(i % w, i ~/ w, 250, 250, 250);
  }
  return img;
}

/// A hand-built [AnchorMap] whose activity field is high on the RIGHT half and
/// near-zero on the left — the canonical "subject is on the right" fixture.
AnchorMap rightHalfMap(int gw, int gh, {double hi = 0.9, double lo = 0.02}) {
  final act = Float64List(gw * gh);
  for (var y = 0; y < gh; y++) {
    for (var x = 0; x < gw; x++) {
      act[y * gw + x] = x >= gw ~/ 2 ? hi : lo;
    }
  }
  return AnchorMap(gw, gh, act, const PixelRect(0, 0, 999, 999),
      const [Anchor(0.75, 0.5, 1.0)], const [PixelRect(0, 0, 999, 999)]);
}

/// A blank/flat activity map (maxAct == 0): the guaranteed no-subject fallback.
AnchorMap flatMap(int gw, int gh) {
  return AnchorMap(gw, gh, Float64List(gw * gh), const PixelRect(0, 0, 999, 999),
      const [], const [PixelRect(0, 0, 999, 999)]);
}

FrameCompositor build(EffectConfig cfg, {AnchorMap? anchors}) =>
    FrameCompositor.fromRasters(
      base: Uint8List(64 * 64 * 4),
      layers: const [],
      w: 64,
      h: 64,
      config: cfg,
      anchors: anchors,
    );

EffectConfig snowCfg(bool ca) => EffectConfig(
    effects: const [EffectKind.snow],
    fps: 8,
    durationSec: 2,
    seed: 41,
    contentAware: ca,
    snow: const SnowParams(count: 200));

EffectConfig rainCfg(bool ca) => EffectConfig(
    effects: const [EffectKind.rain],
    fps: 8,
    durationSec: 2,
    seed: 41,
    contentAware: ca,
    rain: const RainParams(count: 200));

int rightCount(List<(double, double)> seeds) =>
    seeds.where((s) => s.$1 > 0.5).length;

void main() {
  group('Task 2.2: activity-weighted particle seeding', () {
    test('snow seeds cluster into the high-activity (right) half', () {
      final map = rightHalfMap(16, 16);
      final seeds = build(snowCfg(true), anchors: map).debugParticleSeeds(EffectKind.snow);
      expect(seeds.length, 200, reason: 'count preserved');
      final frac = rightCount(seeds) / seeds.length;
      // Weighted rejection sampling should send ~97% right (accept 0.9 vs 0.02);
      // a uniform draw would sit near 50%. >60% proves it is actually biased.
      expect(frac, greaterThan(0.6),
          reason: 'contentAware ON: 粒子应显著聚向右半显著区（实测 $frac）');
    });

    test('rain also clusters into the high-activity half', () {
      final map = rightHalfMap(16, 16);
      final seeds = build(rainCfg(true), anchors: map).debugParticleSeeds(EffectKind.rain);
      expect(seeds.length, 200);
      final frac = rightCount(seeds) / seeds.length;
      expect(frac, greaterThan(0.6), reason: 'rain ON 也应聚右（实测 $frac）');
    });

    test('contentAware OFF seeds stay near-uniform (~50% right)', () {
      // The contrast that makes the ON assertion meaningful: with the master off
      // the seeds come from the unchanged uniform path.
      final map = rightHalfMap(16, 16);
      final seeds = build(snowCfg(false), anchors: map).debugParticleSeeds(EffectKind.snow);
      final frac = rightCount(seeds) / seeds.length;
      expect(frac, inInclusiveRange(0.3, 0.7),
          reason: 'contentAware OFF: 均匀分布应接近一半（实测 $frac）');
    });

    test('contentAware OFF render is byte-identical with or without anchors',
        () {
      final map = rightHalfMap(16, 16);
      final withMap = build(snowCfg(false), anchors: map).renderFrame(0.5);
      final noMap = build(snowCfg(false)).renderFrame(0.5);
      expect(withMap.data, equals(noMap.data),
          reason: 'map 未消费时（默认 contentAware=false）产物逐字节不变');

      final rainWith = build(rainCfg(false), anchors: map).renderFrame(0.5);
      final rainNo = build(rainCfg(false)).renderFrame(0.5);
      expect(rainWith.data, equals(rainNo.data));
    });

    test('contentAware ON changes the render vs OFF (weighting is live)', () {
      final map = rightHalfMap(16, 16);
      final on = build(snowCfg(true), anchors: map).renderFrame(0.5);
      final off = build(snowCfg(false), anchors: map).renderFrame(0.5);
      expect(on.data, isNot(equals(off.data)),
          reason: 'ON 落位改变 → 帧应与 OFF 不同');
    });

    test('exact particle count is preserved on vs off', () {
      final map = rightHalfMap(16, 16);
      final on = build(snowCfg(true), anchors: map).debugParticleSeeds(EffectKind.snow);
      final off = build(snowCfg(false), anchors: map).debugParticleSeeds(EffectKind.snow);
      expect(on.length, off.length);
      expect(on.length, 200);
    });

    test('ON render is deterministic across two builds (same seed+config+activity)',
        () {
      final map = rightHalfMap(16, 16);
      final a = build(snowCfg(true), anchors: map).renderFrame(0.3);
      final b = build(snowCfg(true), anchors: map).renderFrame(0.3);
      expect(a.data, equals(b.data), reason: '同 seed+config+activity → 逐字节确定');
      // And the seed positions themselves reproduce exactly.
      final sa = build(snowCfg(true), anchors: map).debugParticleSeeds(EffectKind.snow);
      final sb = build(snowCfg(true), anchors: map).debugParticleSeeds(EffectKind.snow);
      expect(sa, equals(sb));
    });

    test('blank/flat activity falls back to the uniform path (no throw)', () {
      final flat = flatMap(16, 16);
      // maxAct == 0 → weighting inactive → positions identical to contentAware
      // OFF (both draw from the unchanged attribute stream).
      final on = build(snowCfg(true), anchors: flat);
      final off = build(snowCfg(false), anchors: flat);
      expect(on.debugParticleSeeds(EffectKind.snow).length, 200);
      expect(on.debugParticleSeeds(EffectKind.snow),
          equals(off.debugParticleSeeds(EffectKind.snow)),
          reason: '平坦/空白 activity → 回落到旧均匀分布');
      expect(on.renderFrame(0.5).data, equals(off.renderFrame(0.5).data),
          reason: '回退产物逐字节等于旧行为，且不抛异常');
    });

    test('weighting gated on contentAware alone, NOT render tier (R6)', () {
      // A legacy-tier config with contentAware on still clusters — the tier is
      // the pixel-algorithm freeze and must not gate placement.
      final map = rightHalfMap(16, 16);
      final cfg = EffectConfig(
          effects: const [EffectKind.snow],
          fps: 8,
          durationSec: 2,
          seed: 41,
          contentAware: true,
          qualityTier: RenderTier.legacy,
          snow: const SnowParams(count: 200));
      final seeds = build(cfg, anchors: map).debugParticleSeeds(EffectKind.snow);
      final frac = rightCount(seeds) / seeds.length;
      expect(frac, greaterThan(0.6),
          reason: 'legacy 档 + contentAware 仍应加权（R6：门控只看 contentAware）');
    });

    test('worker/pipeline path: ON deterministic (rebuilds compositor per job) '
        'and differs from OFF (real analyzer map drives seeding)', () async {
      // A real page with a dark blob in the RIGHT half; the pipeline analyzes it
      // (SaliencyAnalyzer) and hands the AnchorMap to each per-job compositor via
      // FrameCompositor.fromRasters — the exact worker rebuild path R5 cites.
      final img = blankPage(64, 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final dx = x - 48, dy = y - 32;
          if (dx * dx + dy * dy <= 12 * 12) img.setPixel(x, y, 15, 15, 15);
        }
      }
      final bytes = Uint8List.fromList(ImageIO.encodePngFrame(img));
      Map<String, dynamic> cfgJson(bool ca) => <String, dynamic>{
            'effects': ['snow'],
            'fps': 8,
            'durationSec': 1.0,
            'maxDimension': 64,
            'outputFormat': 'gif',
            'seed': 7,
            'snow': {'count': 160},
            if (ca) 'contentAware': true,
          };
      final on = EffectConfig.fromJson(cfgJson(true));
      final off = EffectConfig.fromJson(cfgJson(false));
      final a = (await MotionPipeline(on).processBytes(input: bytes)).gifBytes!;
      final b = (await MotionPipeline(on).processBytes(input: bytes)).gifBytes!;
      final o = (await MotionPipeline(off).processBytes(input: bytes)).gifBytes!;
      expect(a, equals(b),
          reason: 'contentAware ON 双跑（真实 isolate/worker 路径）逐字节确定');
      expect(a, isNot(equals(o)),
          reason: '粒子现消费 activity，ON 应区别于 OFF');
    });
  });
}
