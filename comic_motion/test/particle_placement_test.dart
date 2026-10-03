import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:comic_motion/comic_motion.dart';

/// Task 2.2 — activity-weighted particle seeding (rejection sampling).
///
/// All randomness stays seeded from `EffectConfig.seed`; these tests pin the
/// real behavior: seeds bias into high-`activity` regions, the **helper-pinned**
/// `contentAware: false` render stays byte-for-byte unchanged (Task 3.7 清单 #13:
/// 本文件所有 cfg 助手都**显式**传 ca，`EffectConfig` 的默认自 R30/R36 起已是
/// true —— 旧注释把「助手传 false」说成「默认 false」，是文档失真不是行为差异),
/// exact particle
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
          reason: 'map 未消费时（本条助手显式传 contentAware: false；配置默认自 R30 起是 true）产物逐字节不变');

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
            // 3.6b 前提修复：缺键现在兜底 true（默认即 on）⇒ off 臂必须
            // **显式写** false，本条 ON vs OFF 的对照才仍是 ON vs OFF
            // （断言一字未动）。
            'contentAware': ca,
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

  // ---- Task 3.6b（R30/R36）：落位开箱即活——默认配置（不写 contentAware 键、
  // 不写 quality 键、不钉任何 tier）必须真的驱动 placement ----
  //
  // 投诉 #2（「并不能很好的识别出该出现动态效果的地方」）的验收门：仅有配置
  // 测试不算数，这里从**默认构造/默认 JSON** 出发观察播种行为。
  // 清单 #11（Task 3.7）：R37 给这条公开主干补上了带回 AnchorMap 的签名
  // `downscaleSplitAnchorsForExport` ⇒ 原先那段「brief 点名的方法只返回二元组，
  // 退一步在 working 图上手跑一次 analyze 做等价口径」的逃生说明已过期，
  // 本条现在直接断言**主干自己产出的第三返回值**。
  group('Task 3.6b: placement is live out of the box (default config)', () {
    /// 右半有暗墨块的白页——与 Task 2.2 worker 测试同款主体。
    RgbaImage rightBlobPage() {
      final img = blankPage(64, 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final dx = x - 48, dy = y - 32;
          if (dx * dx + dy * dy <= 12 * 12) img.setPixel(x, y, 15, 15, 15);
        }
      }
      return img;
    }

    // 默认配置：JSON 里既无 contentAware 键也无 quality 键（tier 不钉）。
    Map<String, dynamic> defaultCfgJson([bool? ca]) => <String, dynamic>{
          'effects': ['snow'],
          'fps': 8,
          'durationSec': 1.0,
          'maxDimension': 64,
          'outputFormat': 'gif',
          'seed': 7,
          'snow': {'count': 160},
          if (ca != null) 'contentAware': ca,
        };

    test('默认 config：锚点扫描产出非 null AnchorMap 且播种与显式回滚不同', () {
      final def = EffectConfig.fromJson(defaultCfgJson());
      expect(def.contentAware, isTrue,
          reason: 'R30/R36：缺键兜底 == 新默认 true（不写键 = 开启）');
      final page = rightBlobPage();
      // 主干自己那张 map（不是等价口径）：contentAware 缺键 ⇒ true ⇒ 第三返回值
      // 必须非 null，且带右半墨块给出的 anchor。
      final map = MotionPipeline(def).downscaleSplitAnchorsForExport(page).$3;
      expect(map, isNotNull,
          reason: '默认 config 的 _analyzeAnchors 门控只认 contentAware ⇒ 主干必产出 map');
      expect(map!.anchors, isNotEmpty, reason: '右半墨块必须给出 anchor');

      // _particleWeightingActive 驱动的播种：默认 config 显著聚向右半主体，
      // 同 seed 显式 false 回滚仍是均匀分布，两者逐粒子不同。
      final onSeeds = build(def, anchors: map).debugParticleSeeds(EffectKind.snow);
      final offCfg = EffectConfig.fromJson(defaultCfgJson(false));
      final offSeeds =
          build(offCfg, anchors: map).debugParticleSeeds(EffectKind.snow);
      expect(onSeeds.length, 160);
      expect(onSeeds.length, offSeeds.length);
      expect(onSeeds, isNot(equals(offSeeds)),
          reason: '开箱默认必须重播种：与 contentAware:false 同 seed 跑逐粒子不同');
      final onFrac = rightCount(onSeeds) / onSeeds.length;
      expect(onFrac, greaterThan(0.6),
          reason: '默认路径应把粒子送进主体侧（实测 $onFrac）');
      final offFrac = rightCount(offSeeds) / offSeeds.length;
      expect(offFrac, inInclusiveRange(0.3, 0.7),
          reason: '回滚臂保持旧均匀分布（实测 $offFrac）');
    });

    test('默认 config 端到端（真实 worker 路径）≠ 显式 false 回滚，且双跑确定',
        () async {
      final page = rightBlobPage();
      final bytes = Uint8List.fromList(ImageIO.encodePngFrame(page));
      final def = EffectConfig.fromJson(defaultCfgJson());
      final off = EffectConfig.fromJson(defaultCfgJson(false));
      final a = (await MotionPipeline(def).processBytes(input: bytes)).gifBytes!;
      final b = (await MotionPipeline(def).processBytes(input: bytes)).gifBytes!;
      final o = (await MotionPipeline(off).processBytes(input: bytes)).gifBytes!;
      expect(a, equals(b),
          reason: '默认开启后仍须逐字节确定（重播种自同一 seed 流）');
      expect(a, isNot(equals(o)),
          reason: '开箱产物必须已带内容感知落位（投诉 #2 的端到端验收）');
    });
  });
}
