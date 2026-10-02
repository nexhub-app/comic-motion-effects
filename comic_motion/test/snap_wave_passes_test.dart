import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion/src/render/waveform.dart';

/// Task 3.4：snapWave 接入 shake/speedLines/impactRings/parallax（standard+）。
///
/// 契约：legacy 分支逐字节冻结为原 sin；standard 分支载体换成 snapWave。
/// 因为 snapWave(0)=0.3387≠0，standard 在 t=0 不是中性帧（静态偏移，R17 接受
/// 的行为差）。本文件用真实渲染管线（FrameCompositor.renderFrame）+ 质心/亮度
/// 度量，同档内比对以隔离 snapWave（跨档字节差还混有 AA/screen，另设粗比对）。
void main() {
  // ---------- 场景与度量 helpers（沿用 engine_test 的真实模式） ----------

  /// x/y 双向渐变：任何方向的平移都会改变大量像素亮度。
  RgbaImage grad2D({int w = 96, int h = 96}) {
    final img = RgbaImage(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final lum = (60 + x * 120 ~/ (w - 1) + y * 60 ~/ (h - 1)).clamp(0, 255);
        img.setPixel(x, y, lum, lum, lum);
      }
    }
    return img;
  }

  RgbaImage render(RgbaImage img, EffectConfig cfg, double t) =>
      FrameCompositor(
              LayerSplitter(layerCount: 3)
                  .split(img, HeuristicDepthEstimator().estimate(img)),
              img,
              cfg)
          .renderFrame(t);

  int changedPixels(RgbaImage a, RgbaImage b) {
    var n = 0;
    for (var i = 0; i < a.pixelCount; i++) {
      if (a.data[i] != b.data[i]) n++;
    }
    return n;
  }

  /// 与某参考列对齐的暗色竖条质心列（均值，可给出亚像素位移）。
  double barCentroidCol(RgbaImage f, int row) {
    var sum = 0, n = 0;
    for (var x = 0; x < f.width; x++) {
      final o = (row * f.width + x) * 4;
      if (f.data[o] < 80 && f.data[o + 1] < 80 && f.data[o + 2] < 80) {
        sum += x;
        n++;
      }
    }
    expect(n, greaterThan(3), reason: 'row=$row 应命中暗色竖条');
    return sum / n;
  }

  EffectConfig std(List<EffectKind> kinds, {double duration = 2, int seed = 41}) =>
      EffectConfig(
          effects: kinds,
          fps: 8,
          durationSec: duration,
          seed: seed,
          quality: const QualityParams(tier: RenderTier.standard));

  EffectConfig leg(List<EffectKind> kinds, {double duration = 2, int seed = 41}) =>
      EffectConfig(
          effects: kinds,
          fps: 8,
          durationSec: duration,
          seed: seed,
          quality: const QualityParams(tier: RenderTier.legacy));

  // ---------- 1) standard 与 legacy 渲染不同（snapWave 只在 standard 生效） ----------

  group('Task 3.4：standard≠legacy 粗判（四通道）', () {
    test('mangaShake / speedLines / impactRings / parallax 同刻渲染跨档不同', () {
      final img = grad2D();
      for (final k in [
        EffectKind.mangaShake,
        EffectKind.speedLines,
        EffectKind.impactRings,
        EffectKind.parallax,
      ]) {
        for (final t in [0.3, 0.61]) {
          final a = render(img, leg([k]), t);
          final b = render(img, std([k]), t);
          expect(changedPixels(a, b), greaterThan(0),
              reason: '${k.name} 在 t=$t 两档渲染完全相同——standard 路径可能没接上');
        }
      }
    });

    test('breathing 不受影响：两档呼吸帧仍走同一正弦（无 snapWave）', () {
      // 规格 §6.2：呼吸不允许有冲击感。breathing 的缩放驱动若被换成
      // snapWave，t=0 会出现静态偏移——用同刻同档双次渲染钉不住，改为
      // 钉「standard 档 breathing-only 在 t=0 与旧行为一致的位移中性」：
      // 与 0 位移基线（effects 空）的差只来自 zoom 的 sin 项，t=0 时 sin=0。
      final img = grad2D();
      final b = render(img, std([EffectKind.parallax, EffectKind.breathing]),
          0.0);
      // parallax 的 snapWave(0)=0.3387 偏移会改变画面，但 breathing 自身在
      // t=0 仍为 sin(0)=0：单独开 breathing（关视差）时 standard t=0 必须与
      // 空效果 standard t=0 逐字节一致。
      final plain = render(img, std([EffectKind.breathing]), 0.0);
      final off = render(img, std([]), 0.0);
      expect(plain.data, equals(off.data),
          reason: 'breathing 应保持纯正弦、t=0 中性（§6.2 不得有 snap 感）');
      expect(changedPixels(b, off), greaterThan(0));
    });
  });

  // ---------- 2) standard 档无缝循环 ----------

  group('Task 3.4：standard 无缝循环', () {
    test('mangaShake standard：f(0)==f(durationSec) 逐字节', () {
      // 故意取非默认时长：循环闭合只依赖 u 的整数周期（_shakeRattle·shakes）。
      final img = grad2D();
      final c = EffectConfig(
          effects: const [EffectKind.mangaShake],
          fps: 8,
          durationSec: 2.4,
          seed: 41,
          mangaShake: const MangaShakeParams(amplitude: 0.05),
          quality: const QualityParams(tier: RenderTier.standard));
      expect(render(img, c, 0.0).data, equals(render(img, c, 2.4).data),
          reason: '_shakeRattle·shakes 为整数 → snapWave 每循环整数周期');
    });

    test('speedLines standard：f(0)==f(durationSec) 逐字节', () {
      final img = grad2D();
      final cfg = EffectConfig(
          effects: const [EffectKind.speedLines],
          fps: 8,
          durationSec: 2,
          seed: 41,
          speedLines: const SpeedLinesParams(pulses: 3),
          quality: const QualityParams(tier: RenderTier.standard));
      expect(render(img, cfg, 0.0).data, equals(render(img, cfg, 2.0).data),
          reason: 'pulses 整数 → snapWave(pulses·u+phase) 首尾同值');
    });

    test('parallax standard：periodSec 整除 durationSec 时 f(0)==f(duration)', () {
      // 竖向 dy 的 phase*0.8 每循环推进 1.6π（非整周），dyDir≠0 时不闭合是
      // Task 3.5 的既有范围；这里按 3.2 的口径钉水平轴（directionDeg 默认 0
      // ⇒ dyDir=sin(0)=0 精确）在 snapWave 下依然整周期闭合。
      final img = grad2D();
      final cfg = EffectConfig(
          effects: const [EffectKind.parallax],
          fps: 8,
          durationSec: 4,
          seed: 41,
          parallax: const ParallaxParams(amplitude: 0.05, periodSec: 1),
          quality: const QualityParams(tier: RenderTier.standard));
      expect(render(img, cfg, 0.0).data, equals(render(img, cfg, 4.0).data),
          reason: 'phase 每循环推进 2π 整数倍 → snapWave(u) 的 u 推进整数');
    });
  });

  // ---------- 3) standard 确定性 ----------

  test('Task 3.4：standard 四通道同配置两次渲染逐字节一致', () {
    final img = grad2D();
    final cfg = std([
      EffectKind.mangaShake,
      EffectKind.speedLines,
      EffectKind.impactRings,
      EffectKind.parallax,
    ]);
    expect(render(img, cfg, 0.83).data, equals(render(img, cfg, 0.83).data));
  });

  // ---------- 4) snapWave 真正接到了站点（同档隔离，排除 AA 混扰） ----------

  group('Task 3.4：t=0 非中性 = snapWave(0)·幅度（standard），legacy 恒 0', () {
    // 200×150 浅灰底 + 枢轴列(x=100)上的暗竖条：水平平移直接读出为质心差。
    RgbaImage barScene() {
      final img = RgbaImage(width: 200, height: 150);
      for (var y = 0; y < 150; y++) {
        for (var x = 0; x < 200; x++) {
          img.setPixel(x, y, 200, 200, 200);
        }
      }
      for (var y = 40; y < 110; y++) {
        for (var x = 89; x < 112; x++) {
          img.setPixel(x, y, 20, 20, 20);
        }
      }
      return img;
    }

    final img = barScene();

    test('mangaShake：standard t=0 位移 ≈ 0.3387·amplitude·w，legacy t=0 逐字节=未启用', () {
      // shakes=1、rotJitDeg=0 → 爆点方向恒 (cos0, sin0)=(1,0)，位移严格水平。
      EffectConfig cfg(RenderTier tier) => EffectConfig(
          effects: const [EffectKind.mangaShake],
          fps: 8,
          durationSec: 2,
          seed: 41,
          mangaShake: const MangaShakeParams(
              shakes: 1, amplitude: 0.12, decay: 0.72, rotJitDeg: 0),
          quality: QualityParams(tier: tier));
      EffectConfig plain(RenderTier tier) => EffectConfig(
          effects: const [],
          fps: 8,
          durationSec: 2,
          seed: 41,
          quality: QualityParams(tier: tier));

      // legacy：sin(2π·3·0)=0 精确 → t=0 帧与不启用震屏逐字节一致（冻结证据）。
      expect(render(img, cfg(RenderTier.legacy), 0.0).data,
          equals(render(img, plain(RenderTier.legacy), 0.0).data),
          reason: 'legacy t=0 必须保持 0 位移（R6 算法冻结）');

      final base = render(img, plain(RenderTier.standard), 0.0);
      final f = render(img, cfg(RenderTier.standard), 0.0);
      // 绘制偏移与内容位移反号（_drawLayer 把目标原点放在 +offset ⇒ 画面内容
      // 移动 −offset；legacy 侧同约定，只是 legacy 恒 0）。
      final shift = barCentroidCol(f, 75) - barCentroidCol(base, 75);
      final expect0 = -0.12 * 200 * snapWave(0); // = −24·0.3387 ≈ −8.13px
      expect(shift, lessThan(-4.0),
          reason: 'standard t=0 应带 snapWave(0) 静态偏移（R17 接受的行为差）');
      expect(shift, closeTo(expect0, 1.5),
          reason: '偏移量应≈−amplitude·w·snapWave(0)=$expect0');
    });

    test('parallax：standard t=0 各层有 0.3387·ampPx 静态偏移，legacy t=0 逐字节=无视差', () {
      // bandBar 场景（同 3.2 判别式）：三根色条分居层，枢轴列 x=150。
      const w = 300, h = 300, amp = 0.1, period = 3.0;
      RgbaImage bandBarScene() {
        final img = RgbaImage(width: w, height: h);
        for (var y = 0; y < h; y++) {
          final g = y < 126 ? 210 : (y < 210 ? 200 : 190);
          for (var x = 0; x < w; x++) {
            img.setPixel(x, y, g, g, g);
          }
        }
        for (var y = 84; y < 116; y++) {
          for (var x = 134; x < 166; x++) {
            img.setPixel(x, y, 235, 25, 35); // far
          }
        }
        for (var y = 180; y < 210; y++) {
          for (var x = 134; x < 166; x++) {
            img.setPixel(x, y, 30, 200, 60); // mid
          }
        }
        for (var y = 240; y < 290; y++) {
          for (var x = 134; x < 166; x++) {
            img.setPixel(x, y, 40, 70, 235); // near
          }
        }
        return img;
      }

      DepthMap bandDepth() {
        final dm = DepthMap(w, h);
        for (var y = 0; y < h; y++) {
          final d = y < 126
              ? 0.05
              : (y < 210 ? 0.45 : 0.85 + 0.15 * (y - 210) / 89);
          for (var x = 0; x < w; x++) {
            dm.set(x, y, d);
          }
        }
        return dm;
      }

      double colCentroid(RgbaImage f, int row) {
        var sum = 0, n = 0;
        for (var x = 0; x < w; x++) {
          final o = (row * w + x) * 4;
          final r = f.data[o], g = f.data[o + 1], b = f.data[o + 2];
          final hit = (row == 100 && r > 150 && g < 90 && b < 90) ||
              (row == 195 && g > 150 && r < 90 && b < 90) ||
              (row == 270 && b > 150 && r < 90 && g < 120);
          if (hit) {
            sum += x;
            n++;
          }
        }
        expect(n, greaterThan(3));
        return sum / n;
      }

      final img = bandBarScene();
      final layers = LayerSplitter(layerCount: 3).split(img, bandDepth());
      EffectConfig cfg(RenderTier tier) => EffectConfig(
          effects: const [EffectKind.parallax],
          fps: 8,
          durationSec: period,
          seed: 41,
          parallax: ParallaxParams(amplitude: amp, periodSec: period),
          quality: QualityParams(tier: tier));
      EffectConfig plain(RenderTier tier) => EffectConfig(
          effects: const [],
          fps: 8,
          durationSec: period,
          seed: 41,
          quality: QualityParams(tier: tier));

      // legacy：sin(li·π)≈1e-16 → t=0 与「无 parallax」逐字节一致（3.2 记录 7a）。
      expect(
          FrameCompositor(layers, img, cfg(RenderTier.legacy))
              .renderFrame(0.0).data,
          equals(FrameCompositor(layers, img, plain(RenderTier.legacy))
              .renderFrame(0.0).data),
          reason: 'legacy t=0 视差必须为 0（冻结）');

      final sCfg = cfg(RenderTier.standard);
      final sPlain = plain(RenderTier.standard);
      final f = FrameCompositor(layers, img, sCfg).renderFrame(0.0);
      final b = FrameCompositor(layers, img, sPlain).renderFrame(0.0);
      // 每层 mult=0.25/0.625/1.0，ampPx=amp·w·mult，偏移=ampPx·snapWave(0)。
      const mults = [0.25, 0.625, 1.0];
      const rows = [100, 195, 270];
      for (var li = 0; li < 3; li++) {
        final shift = colCentroid(f, rows[li]) - colCentroid(b, rows[li]);
        // 绘制偏移与内容位移反号（同 mangaShake 用例注释）。
        final expectPx = -amp * w * mults[li] * snapWave(0);
        expect(shift, lessThan(-1.0),
            reason: 'li=$li standard t=0 应有 snapWave(0) 静态偏移');
        expect(shift, closeTo(expectPx, 1.5),
            reason: 'li=$li 偏移应≈$expectPx px');
      }
    });
  });

  // ---------- 5) impactRings 端点窗（R17 回归护栏） ----------

  group('Task 3.4：impactRings standard 窗口包络', () {
    // rings=1、pulses=1 ⇒ ph = _loopU(t)·1 = t/duration，可用 t 直接扫 ph。
    RgbaImage ringScene() {
      final img = RgbaImage(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final lum = (70 + x * 150 ~/ 95).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    final img = ringScene();
    const duration = 2.0;

    EffectConfig rcfg(RenderTier tier) => EffectConfig(
        effects: const [EffectKind.impactRings],
        fps: 8,
        durationSec: duration,
        seed: 41,
        impactRings: const ImpactRingsParams(rings: 1, pulses: 1),
        quality: QualityParams(tier: tier));

    EffectConfig plain(RenderTier tier) => EffectConfig(
        effects: const [],
        fps: 8,
        durationSec: duration,
        seed: 41,
        quality: QualityParams(tier: tier));

    /// 单帧最大亮度差 ≈ 环的峰值 alpha（env 的单调像）：半径/周长不影响峰值。
    double inkAt(RenderTier tier, double ph) {
      final t = ph * duration;
      final f = render(img, rcfg(tier), t);
      final b = render(img, plain(tier), t);
      var m = 0.0;
      for (var i = 0; i < f.pixelCount; i++) {
        final d = (f.luminance(i) - b.luminance(i)).abs();
        if (d > m) m = d.toDouble();
      }
      return m;
    }

    test('standard：ph→0 与 ph→1 端点落墨归零（裸 snapWave 替换会在此红），峰前移且快起慢落', () {
      // 端点：裸 snapWave(ph)≥0.3387 ⇒ 端点仍有大 alpha（环永不淡出、环间叠死）
      // ——本断言正是 R17 窗口存在的理由。
      expect(inkAt(RenderTier.standard, 0.0005), 0.0,
          reason: 'ph→0 必须无墨（窗口端点归零）');
      expect(inkAt(RenderTier.standard, 0.9995), 0.0,
          reason: 'ph→1 必须无墨（窗口端点归零）');

      var peak = 0.0, peakPh = 0.0;
      for (var i = 1; i < 100; i++) {
        final ph = i / 100.0;
        final ink = inkAt(RenderTier.standard, ph);
        if (ink > peak) {
          peak = ink;
          peakPh = ph;
        }
      }
      expect(peak, greaterThan(20.0), reason: 'standard 环闪峰值应可见');
      // 端点附近显著弱于峰值（≤15%）。
      expect(inkAt(RenderTier.standard, 0.02), lessThanOrEqualTo(0.15 * peak));
      expect(inkAt(RenderTier.standard, 0.98), lessThanOrEqualTo(0.15 * peak));
      // 非对称：峰在 ph<0.5（实测窗峰≈0.416；对称 sin(π·ph) 峰在 0.5），
      // 上升段(0→peakPh)短于下降段(peakPh→1) ⇒ 攻击更陡、余韵更长（快起慢落）。
      expect(peakPh, greaterThanOrEqualTo(0.30));
      expect(peakPh, lessThan(0.5),
          reason: '峰应前移（snapWave 正瓣偏前），sin 窗对称会在 0.5');
      expect(peakPh, lessThan(1.0 - peakPh),
          reason: '攻击段应短于回落到端点 0 的段（不对称）');

      // 同网格跑 legacy：峰仍在 0.5±0.01（sin(π·ph) 对称，冻结证据），
      // 且 standard 的峰严格早于 legacy 的峰。
      var lPeak = 0.0, lPeakPh = 0.0;
      for (var i = 1; i < 100; i++) {
        final ph = i / 100.0;
        final ink = inkAt(RenderTier.legacy, ph);
        if (ink > lPeak) {
          lPeak = ink;
          lPeakPh = ph;
        }
      }
      expect((lPeakPh - 0.5).abs(), lessThanOrEqualTo(0.02),
          reason: 'legacy 包络必须保持 sin(π·ph) 的对称峰 0.5'
              '（0.49/0.50 舍入平台并列，首过点即 argmax，容差 0.02）');
      expect(peakPh, lessThan(lPeakPh),
          reason: 'standard 峰应比 legacy 更靠前（snapWave 已接线）');
    });

    test('impactRings standard 确定性 + 整循环 f(0)==f(duration) 逐字节', () {
      expect(render(img, rcfg(RenderTier.standard), 0.7).data,
          equals(render(img, rcfg(RenderTier.standard), 0.7).data));
      expect(render(img, rcfg(RenderTier.standard), 0.0).data,
          equals(render(img, rcfg(RenderTier.standard), duration).data));
    });
  });
}
