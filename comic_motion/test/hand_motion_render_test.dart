import 'dart:math' as math;

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// Plan B Task 5：把手部动作（`handMotion`）接进 `FrameCompositor`。
///
/// 四条不变量，逐条有门：
/// 1. **默认惰性**——没有 `part_motion.json`（parts=null）、没开效果、legacy
///    档、reducedMotion 四种情形都必须与「完全没有这个功能」逐字节相同；
/// 2. **静止姿态 = 原画**——0 号部件在 t=0 的摆角是精确 0.0，因此首帧像素与
///    无部件一致。这条决定了相位载体只能用 `MotionMath.wave`（sin，0 处为
///    0），不能用 `snapWave`（u=0 处 ≈0.3387，会把原画预旋 1/3 个幅度）；
/// 3. **局部**——改动像素只落在部件 bbox（含羽化与最大位移余量）里；
/// 4. **无缝 + 确定**——首尾帧逐字节一致，同 config 同 parts 两次合成一致。
const w = 120, h = 200;

void main() {
  /// 白纸 + 两条竖直条纹带（A：y 44..88，B：y 124..168）+ 左上角标记。
  /// 条纹提供强水平梯度：旋转后采样点平移，逐像素必然看得出差异；
  /// 角标记在所有部件 bbox 之外，用来证明形变是局部的。
  RgbaImage canvas() {
    final img = RgbaImage(width: w, height: h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      img.data[o] = 250;
      img.data[o + 1] = 250;
      img.data[o + 2] = 250;
      img.data[o + 3] = 255;
    }
    void stripes(int y0, int y1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = 20; x <= 100; x++) {
          if (((x - 20) ~/ 5).isEven) {
            final o = (y * w + x) * 4;
            img.data[o] = 10;
            img.data[o + 1] = 10;
            img.data[o + 2] = 10;
          }
        }
      }
    }

    stripes(44, 88);
    stripes(124, 168);
    for (var y = 2; y <= 8; y++) {
      for (var x = 2; x <= 8; x++) {
        final o = (y * w + x) * 4;
        img.data[o] = 5;
        img.data[o + 1] = 5;
        img.data[o + 2] = 5;
      }
    }
    return img;
  }

  /// A 带的手：手腕（根）在左缘 (20,62)，尖是多边形里最远的顶点 (100,84)。
  PartMotion handA({PartKind kind = PartKind.hand}) => PartMotion(
        kind: kind,
        polygon: [
          PartPoint(20 / w, 48 / h),
          PartPoint(100 / w, 44 / h),
          PartPoint(100 / w, 84 / h),
          PartPoint(20 / w, 88 / h),
        ],
        anchorX: 20 / w,
        anchorY: 62 / h,
        joint: 'wrist',
      );

  PartMotion handB() => PartMotion(
        kind: PartKind.hand,
        polygon: [
          PartPoint(20 / w, 128 / h),
          PartPoint(100 / w, 124 / h),
          PartPoint(100 / w, 164 / h),
          PartPoint(20 / w, 168 / h),
        ],
        anchorX: 20 / w,
        anchorY: 142 / h,
        joint: 'wrist',
      );

  /// 面积 < 1px² 的退化多边形：`buildPlan` 必须返回空 plan。
  PartMotion degenerate() => PartMotion(
        kind: PartKind.hand,
        polygon: [
          PartPoint(50 / w, 50 / h),
          PartPoint(50.3 / w, 50 / h),
          PartPoint(50 / w, 50.3 / h),
        ],
        anchorX: 50 / w,
        anchorY: 50 / h,
        joint: 'wrist',
      );

  final img = canvas();
  late List<LayerImage> layers;

  setUpAll(() {
    layers = LayerSplitter(layerCount: 3)
        .split(img, HeuristicDepthEstimator().estimate(img));
  });

  EffectConfig cfg({
    bool on = true,
    double ampDeg = 8.0,
    double periodSec = 2.0,
    double durationSec = 2.0,
    RenderTier tier = RenderTier.standard,
    bool reduced = false,
  }) =>
      EffectConfig(
        effects: on ? [EffectKind.handMotion] : const [],
        handMotion: HandMotionParams(ampDeg: ampDeg, periodSec: periodSec),
        fps: 8,
        durationSec: durationSec,
        seed: 11,
        quality: QualityParams(tier: tier),
        reducedMotion: reduced,
      );

  FrameCompositor comp(EffectConfig c, {List<PartMotion>? parts}) =>
      FrameCompositor(layers, img, c, parts: parts);

  int changed(RgbaImage a, RgbaImage b) {
    var n = 0;
    for (var i = 0; i < a.pixelCount; i++) {
      final o = i * 4;
      // apply() 只写 RGB（alpha 通道不动），这里也只看 RGB。
      if (a.data[o] != b.data[o] ||
          a.data[o + 1] != b.data[o + 1] ||
          a.data[o + 2] != b.data[o + 2]) {
        n++;
      }
    }
    return n;
  }

  group('默认惰性：四种关闭路径逐字节等于「没有这个功能」', () {
    test('开效果但不给 parts ⇒ 与不开效果完全一致', () {
      final off = comp(cfg(on: false)).renderFrame(0.7);
      final inert = comp(cfg(on: true)).renderFrame(0.7);
      expect(inert.data, equals(off.data));
    });

    test('给了 parts 但没开效果 ⇒ 一个像素都不动', () {
      final off = comp(cfg(on: false)).renderFrame(0.7);
      final inert = comp(cfg(on: false), parts: [handA(), handB()]).renderFrame(0.7);
      expect(inert.data, equals(off.data));
    });

    test('legacy 档不做部位形变（逐字节回滚承诺）', () {
      final base = comp(cfg(tier: RenderTier.legacy)).renderFrame(0.5);
      final withParts =
          comp(cfg(tier: RenderTier.legacy), parts: [handA()]).renderFrame(0.5);
      expect(withParts.data, equals(base.data));
      // 反向确认门非空：同一 parts 在 standard 档确实动了。
      expect(
          changed(comp(cfg()).renderFrame(0.5),
                  comp(cfg(), parts: [handA()]).renderFrame(0.5)),
          greaterThan(0));
    });

    test('reducedMotion 下部件完全静止', () {
      final base = comp(cfg(reduced: true)).renderFrame(0.5);
      final withParts =
          comp(cfg(reduced: true), parts: [handA()]).renderFrame(0.5);
      expect(withParts.data, equals(base.data));
    });
  });

  group('非空形变', () {
    test('t=0 是原画姿态：0 号部件摆角精确 0，像素与无部件一致', () {
      expect(comp(cfg(), parts: [handA()]).debugHandAngleDeg(0, 0.0), 0.0);
      expect(comp(cfg(), parts: [handA()]).debugHandAngleDeg(0, 0.5),
          closeTo(8.0 * math.sin(2 * math.pi * 0.5 / 2.0), 1e-12));
      final rest = comp(cfg(on: false)).renderFrame(0.0);
      final withParts = comp(cfg(), parts: [handA()]).renderFrame(0.0);
      expect(changed(rest, withParts), 0);
    });

    test('ampDeg=0 回到无部件；ampDeg 越大改动越多', () {
      final quiet = comp(cfg(ampDeg: 0.0), parts: [handA()]).renderFrame(0.5);
      final none = comp(cfg(on: false)).renderFrame(0.5);
      expect(quiet.data, equals(none.data));
      final soft =
          comp(cfg(ampDeg: 4.0), parts: [handA()]).renderFrame(0.5);
      final loud =
          comp(cfg(ampDeg: 16.0), parts: [handA()]).renderFrame(0.5);
      final softDiff = changed(none, soft);
      final loudDiff = changed(none, loud);
      expect(softDiff, greaterThan(0));
      expect(loudDiff, greaterThan(softDiff),
          reason: '幅度必须真的放大形变面积，否则 ampDeg 是死参数');
      expect(changed(soft, loud), greaterThan(0));
    });

    test('形变局部：改动像素全部落在部件 bbox 的余量内', () {
      final none = comp(cfg(on: false)).renderFrame(0.5);
      // t=0.5 = 1/4 周期 ⇒ sin=1，摆角取满 ampDeg=8°。
      // 最大位移 ≈ θ_rad · 轴长 = 8·π/180 · sqrt(80²+22²) ≈ 11.6px，
      // 羽化 pad = featherPx(2)+1，合计取 15px 余量。
      const m = 15;
      final x0 = 20 - m, x1 = 100 + m, y0 = 44 - m, y1 = 88 + m;
      final out = comp(cfg(), parts: [handA()]).renderFrame(0.5);
      var inside = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          final diff = none.data[o] != out.data[o] ||
              none.data[o + 1] != out.data[o + 1] ||
              none.data[o + 2] != out.data[o + 2];
          if (!diff) continue;
          if (x < x0 || x > x1 || y < y0 || y > y1) {
            fail('bbox 外的像素 ($x,$y) 被改动：形变必须是局部的');
          }
          inside++;
        }
      }
      expect(inside, greaterThan(0));
      // B 带与角标记都在余量外，必须逐字节不动。
      expect(out.data[(3 * w + 3) * 4], 5);
      expect(changed(_cropRow(none, 124, 168), _cropRow(out, 124, 168)), 0);
    });

    test('逐部件相位错开（两只手不同步）', () {
      final c = comp(cfg(), parts: [handA(), handB()]);
      final a0 = c.debugHandAngleDeg(0, 0.0);
      final b0 = c.debugHandAngleDeg(1, 0.0);
      expect(a0, 0.0);
      expect(b0, isNot(0.0),
          reason: '若两部件同相，这里会同时为 0 —— 看起来像贴图不是像挥手');
      final none = comp(cfg(on: false)).renderFrame(0.5);
      final both = c.renderFrame(0.5);
      expect(changed(_cropRow(none, 44, 88), _cropRow(both, 44, 88)),
          greaterThan(0));
      expect(changed(_cropRow(none, 124, 168), _cropRow(both, 124, 168)),
          greaterThan(0));
    });

    test('只实现 hand：其余 kind 解析通过但渲染跳过', () {
      final none = comp(cfg(on: false)).renderFrame(0.5);
      final head = comp(cfg(), parts: [handA(kind: PartKind.head)])
          .renderFrame(0.5);
      expect(head.data, equals(none.data));
    });

    test('退化多边形（空 plan）不产生形变', () {
      final none = comp(cfg(on: false)).renderFrame(0.5);
      final deg = comp(cfg(), parts: [degenerate()]).renderFrame(0.5);
      expect(deg.data, equals(none.data));
    });
  });

  group('无缝与确定', () {
    test('首尾帧逐字节一致（对齐与未对齐周期都算）', () {
      for (final (dur, per) in [(2.0, 2.0), (3.0, 2.0), (4.0, 3.0)]) {
        final c = comp(cfg(durationSec: dur, periodSec: per),
            parts: [handA(), handB()]);
        expect(c.renderFrame(0.0).data, equals(c.renderFrame(dur).data),
            reason: 'duration=$dur period=$per 的 loop 必须无缝');
      }
    });

    test('同 config 同 parts 两次合成逐字节一致', () {
      final a = comp(cfg(), parts: [handA(), handB()]).renderFrame(0.7);
      final b = comp(cfg(), parts: [handA(), handB()]).renderFrame(0.7);
      expect(a.data, equals(b.data));
    });

    test('worker 路径：fromRasters 与主构造器对同一 parts 逐字节一致', () {
      final parts = [handA(), handB()];
      final c = cfg();
      final main = comp(c, parts: parts).renderFrame(0.55);
      final viaRasters = FrameCompositor.fromRasters(
        base: img.data,
        layers: [for (final l in layers) l.image.data],
        w: w,
        h: h,
        config: c,
        ranks: [for (final l in layers) l.depthRank],
        clips: [for (final l in layers) l.clip],
        parts: parts,
      ).renderFrame(0.55);
      expect(viaRasters.data, equals(main.data));
    });
  });
}

/// 取行区间 [y0,y1] 的裁切副本（只用于「这一带必须不动」的局部断言）。
RgbaImage _cropRow(RgbaImage img, int y0, int y1) {
  final out = RgbaImage(width: w, height: y1 - y0 + 1);
  for (var y = 0; y < out.height; y++) {
    final src = ((y0 + y) * w) * 4;
    out.data.setRange(0, w * 4, img.data.sublist(src, src + w * 4));
  }
  return out;
}
