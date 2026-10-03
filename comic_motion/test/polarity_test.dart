import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:comic_motion/comic_motion.dart';

/// Task 2.4 —— 亮度自适应墨极性（治「白叠白」）。
///
/// 运动叠加层是白线/白光，漫画纸面本身多为白，白叠白等于没画。standard+ 档
/// 起，线/闪光/扫光按**该点底图亮度**选极性：白纸压深墨（`#1a1a1a` + darken
/// /multiply），暗区爆白（white + screen）。本文件钉住四层契约：
///  1. `BlendOp.darken` / `BlendOp.multiply` 的整数算式（只压暗、零覆盖恒等、
///     单调、不碰 alpha）—— 口径照 test/render_test.dart 的 screen/additive 测试；
///  2. `samplePolarity` / `PolarityBrush` 的阈值（spec §5：>200 墨、<80 白、
///     中段最近档 + 幅度放大）；
///  3. 端到端：gradient-luma 场景上 speedLines / impactFlash / lightSweep 在
///     standard 档「亮区变暗 + 暗区变亮」，legacy 档逐字节等于基线（R10），
///     standard 档仍确定性且整循环无缝（R12）。
///
/// 极性只读静态底图、不碰任何效果的属性 RNG 流，所以 RNG 抽取顺序与次数逐字
/// 不变 —— 这正是 legacy 字节冻结与无缝循环同时成立的前提。

// ---------- 场景与小工具 ----------

/// x 方向 0..255 的亮度渐变：暗区（x≤37，lum<80）与白纸（x≥95，lum>200）共存，
/// 一帧里同时能验证两极。
RgbaImage gradientPage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final lum = (x * 255 / (w - 1)).round();
      img.setPixel(x, y, lum, lum, lum);
    }
  }
  return img;
}

RgbaImage solidPage(int v, int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var i = 0; i < img.pixelCount; i++) {
    img.data[i * 4] = v;
    img.data[i * 4 + 1] = v;
    img.data[i * 4 + 2] = v;
    img.data[i * 4 + 3] = 255;
  }
  return img;
}

/// FNV-1a 64 位摘要：legacy 逐字节冻结契约用一行 hex 钉死，比逐像素断言省内存。
///
/// 依赖 Dart VM 的 64 位整型回绕乘法和 `dart test` 的默认 vm 平台（本包无
/// dart_test.yaml），高位被置时 hex 会带一个 `-` 前缀——那是同一串字节的稳定
/// 指纹，只要平台不变就一直对得上。
String _fnv(Uint8List d) {
  var h = 0xcbf29ce484222325;
  for (final b in d) {
    h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

void main() {
  group('BlendOp.darken / multiply 算子', () {
    test('darken 恒不提亮、零覆盖恒等、且 alpha 永不参与', () {
      for (var d = 0; d <= 255; d++) {
        for (final a in [0, 1, 37, 128, 254, 255]) {
          final f = RgbaImage(width: 1, height: 1)
            ..data.setRange(0, 4, [d, 255 - d, d ^ 0x5a, 200]);
          blendPixel(f, 0, 0, 26, 26, 26, a, op: BlendOp.darken);
          expect(f.data[0] <= d, isTrue, reason: 'd=$d a=$a 被提亮了');
          expect(f.data[1] <= 255 - d, isTrue, reason: 'd=$d a=$a 被提亮了');
          expect(f.data[2] <= (d ^ 0x5a), isTrue);
          expect(f.data[3], 200); // alpha 位原样保留
        }
      }
      final same = RgbaImage(width: 1, height: 1)
        ..data.setRange(0, 4, [250, 123, 77, 255]);
      blendPixel(same, 0, 0, 26, 26, 26, 0, op: BlendOp.darken);
      expect(same.data[0], 250); // 零覆盖 = 恒等（cov<=0 短路）
      expect(same.data[1], 123);
    });

    test('darken 在纸白上真正压出墨量，且随覆盖度单调递减', () {
      final f = solidPage(250, 1, 1);
      blendPixel(f, 0, 0, 26, 26, 26, 255, op: BlendOp.darken);
      expect(f.data[0], 26); // 满覆盖：直接落到墨色
      var prev = 256;
      for (final a in [1, 8, 32, 64, 128, 200, 255]) {
        final g = solidPage(250, 1, 1);
        blendPixel(g, 0, 0, 26, 26, 26, a, op: BlendOp.darken);
        expect(g.data[0] < prev, isTrue, reason: 'a=$a 处覆盖度不再压暗');
        prev = g.data[0];
      }
    });

    test('darken 逐字复现 source-over 落黑（0 色）的代数式', () {
      // src=0 时 min(d, d·(255-a)/255) == d·(255-a)/255 == 黑色 source-over，
      // 这就是 focusLines 的黑楔形可以整体视作「压墨」一极的依据。
      for (var d = 0; d <= 255; d++) {
        for (final a in [1, 5, 60, 128, 250, 255]) {
          final dk = RgbaImage(width: 1, height: 1)
            ..data.setRange(0, 4, [d, d, d, 255]);
          blendPixel(dk, 0, 0, 0, 0, 0, a, op: BlendOp.darken);
          final ov = RgbaImage(width: 1, height: 1)
            ..data.setRange(0, 4, [d, d, d, 255]);
          blendPixel(ov, 0, 0, 0, 0, 0, a);
          expect(dk.data[0], ov.data[0], reason: 'd=$d a=$a');
        }
      }
    });

    test('multiply 恒不高于 source-over（白纸落墨）、零覆盖恒等、单调', () {
      for (var d = 0; d <= 255; d++) {
        for (final a in [1, 32, 128, 254, 255]) {
          final m = RgbaImage(width: 1, height: 1)
            ..data.setRange(0, 4, [d, d, d, 211]);
          blendPixel(m, 0, 0, 26, 26, 26, a, op: BlendOp.multiply);
          expect(m.data[0] <= d, isTrue, reason: 'd=$d a=$a 被提亮了');
          expect(m.data[3], 211);
          final o = RgbaImage(width: 1, height: 1)
            ..data.setRange(0, 4, [d, d, d, 255]);
          blendPixel(o, 0, 0, 26, 26, 26, a);
          expect(m.data[0] <= o.data[0], isTrue, reason: 'd=$d a=$a 比 over 亮');
        }
      }
      final same = RgbaImage(width: 1, height: 1)
        ..data.setRange(0, 4, [200, 99, 33, 255]);
      blendPixel(same, 0, 0, 26, 26, 26, 0, op: BlendOp.multiply);
      expect(same.data[0], 200); // 零覆盖 = 恒等
      // 满覆盖黑 = 黑色 source-over（focusLines 注释里的同一条代数式）
      for (var d = 0; d <= 255; d++) {
        final m = RgbaImage(width: 1, height: 1)
          ..data.setRange(0, 4, [d, d, d, 255]);
        blendPixel(m, 0, 0, 0, 0, 0, 128, op: BlendOp.multiply);
        final o = RgbaImage(width: 1, height: 1)
          ..data.setRange(0, 4, [d, d, d, 255]);
        blendPixel(o, 0, 0, 0, 0, 0, 128);
        expect(m.data[0], o.data[0], reason: 'd=$d');
      }
      var prev = 256;
      for (final a in [1, 16, 64, 128, 192, 255]) {
        final g = solidPage(240, 1, 1);
        blendPixel(g, 0, 0, 26, 26, 26, a, op: BlendOp.multiply);
        expect(g.data[0] < prev, isTrue, reason: 'a=$a 不再单调');
        prev = g.data[0];
      }
    });

    test('新算子不越界、不吃 clip：与 over/additive 一样拒绝裁剪框外像素', () {
      final f = solidPage(250, 8, 8);
      final clip = PixelRect(2, 2, 2, 2);
      blendPixel(f, 0, 0, 26, 26, 26, 255, op: BlendOp.darken, clip: clip);
      blendPixel(f, 3, 3, 26, 26, 26, 255, op: BlendOp.darken, clip: clip);
      blendPixel(f, 0, 0, 26, 26, 26, 255, op: BlendOp.multiply, clip: clip);
      blendPixel(f, 3, 3, 26, 26, 26, 255, op: BlendOp.multiply, clip: clip);
      expect(f.luminance(0), 250); // 框外逐字节不变
      expect(f.luminance(3 * 8 + 3), lessThan(250));
      blendPixel(f, 99, 99, 26, 26, 26, 255, op: BlendOp.darken);
      blendPixel(f, -1, 4, 26, 26, 26, 255, op: BlendOp.multiply);
    });
  });

  group('samplePolarity / PolarityBrush 阈值（spec §5）', () {
    test('白纸 → toInk，暗区 → toLight，中段取最近档', () {
      expect(samplePolarity(255), Polarity.toInk);
      expect(samplePolarity(201), Polarity.toInk);
      expect(samplePolarity(40), Polarity.toLight);
      expect(samplePolarity(79), Polarity.toLight);
      expect(samplePolarity(200), Polarity.toInk); // 边界：>200 不成立但 ≥140
      expect(samplePolarity(140), Polarity.toInk);
      expect(samplePolarity(139), Polarity.toLight);
      expect(samplePolarity(0), Polarity.toLight);
    });

    test('中段幅度放大：1/4 增幅且封顶 256，两极不放大', () {
      expect(PolarityBrush.midLuma(81), isTrue);
      expect(PolarityBrush.midLuma(199), isTrue);
      expect(PolarityBrush.midLuma(80), isFalse);
      expect(PolarityBrush.midLuma(200), isFalse);
      expect(PolarityBrush.bump(200), 250);
      expect(PolarityBrush.bump(100), 125);
      expect(PolarityBrush.bump(0), 0);
      // 上限 256：`d + (255-d)·k/256` 一侧不会溢出回绕成负值。
      expect(PolarityBrush.bump(256), 256);
      expect(PolarityBrush.bump(255), 256);
    });

    test('brush 按像素坐标查底图亮度，越界钳边不抛', () {
      final page = gradientPage(120, 60);
      final b = PolarityBrush(page);
      expect(b.at(0, 0), Polarity.toLight);
      expect(b.at(119, 59), Polarity.toInk);
      expect(b.at(60, 30), anyOf(Polarity.toInk, Polarity.toLight));
      expect(b.at(-400, 9999), Polarity.toLight); // 钳到左上暗角
      expect(b.at(9999, -7), Polarity.toInk);
      expect(b.inkR, 26); // #1a1a1a
      expect(b.inkG, 26);
      expect(b.inkB, 26);
    });
  });

  group('drawSegmentAA 极性画笔（standard 档速度线的画法内核）', () {
    test('纸白页面落墨、黑页爆白，同一几何同一 alpha', () {
      // 极性一律从**静态底图**采样（合成器里就是 `base`，与绘制目标 frame 同
      // 尺寸但互不写入），所以画笔对象与目标栅格分开传。
      final paper = solidPage(250, 24, 8);
      final white = paper.clone();
      drawSegmentAA(white, 2, 4.5, 21, 4.5, 255, 255, 255, 200, 1.0,
          polarity: PolarityBrush(paper));
      expect(white.luminance(4 * 24 + 12), lessThan(100),
          reason: '白纸上画不出墨 = 白叠白没被治好（应压进 #1a1a1a 的墨量）');
      expect(white.data[(4 * 24 + 12) * 4 + 3], 255); // alpha 不动

      final inkPage = solidPage(8, 24, 8);
      final dark = inkPage.clone();
      drawSegmentAA(dark, 2, 4.5, 21, 4.5, 255, 255, 255, 200, 1.0,
          polarity: PolarityBrush(inkPage));
      expect(dark.luminance(4 * 24 + 12), greaterThan(8),
          reason: '暗区仍走 screen 提亮');

      // 不传 polarity ⇒ 逐字节旧行为：白纸上只会把纸画得更白（正是「白叠白」
      // 这个老毛病），一个压暗像素都不该出现。
      final plain = paper.clone();
      final withPolarity = paper.clone();
      drawSegmentAA(plain, 2, 4.5, 21, 4.5, 255, 255, 255, 200, 1.0);
      drawSegmentAA(withPolarity, 2, 4.5, 21, 4.5, 255, 255, 255, 200, 1.0,
          polarity: PolarityBrush(paper));
      for (var i = 0; i < plain.pixelCount; i++) {
        expect(plain.luminance(i) >= 250, isTrue,
            reason: '默认画笔不该改动 legacy/其他效果的提亮语义');
      }
      expect(withPolarity.luminance(4 * 24 + 12),
          lessThan(plain.luminance(4 * 24 + 12)),
          reason: '同几何同 alpha 下极性画笔必须把纸白压下去');
    });

    test('同输入两次绘制逐字节相同（极性纯函数、无跨帧状态）', () {
      final base = gradientPage(64, 64);
      final a = base.clone();
      final b = base.clone();
      for (final f in [a, b]) {
        drawSegmentAA(f, 4, 60, 60, 6, 255, 255, 255, 180, 2.0,
            polarity: PolarityBrush(base));
      }
      expect(a.data, equals(b.data));
    });
  });

  group('端到端极性：speedLines / impactFlash / lightSweep', () {
    const w = 120, h = 120;
    final img = gradientPage(w, h);
    final layers = LayerSplitter(layerCount: 3)
        .split(img, HeuristicDepthEstimator().estimate(img));

    EffectConfig cfg(List<EffectKind> kinds, RenderTier tier) => EffectConfig(
          effects: kinds,
          fps: 8,
          durationSec: 2,
          seed: 77,
          quality: QualityParams(tier: tier),
        );

    RgbaImage render(List<EffectKind> kinds, RenderTier tier, double t) =>
        FrameCompositor(layers, img, cfg(kinds, tier)).renderFrame(t);

    /// 相对同档基线（只有 parallax）：纸白/暗区两半各被压暗、提亮了多少像素。
    ({int lightDarker, int lightLighter, int darkDarker, int darkLighter}) dirs(
        List<EffectKind> kinds, RenderTier tier, double t) {
      final base = render([EffectKind.parallax], tier, t);
      final f = render(kinds, tier, t);
      var ld = 0, ll = 0, dd = 0, dl = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = y * w + x;
          final d = f.luminance(i) - base.luminance(i);
          if (d == 0) continue;
          final light = x >= 95; // 底图 lum>200 的纸白一侧
          final darkSide = x <= 37; // 底图 lum<80 的暗区一侧
          if (light && d < 0) ld++;
          if (light && d > 0) ll++;
          if (darkSide && d < 0) dd++;
          if (darkSide && d > 0) dl++;
        }
      }
      return (
        lightDarker: ld,
        lightLighter: ll,
        darkDarker: dd,
        darkLighter: dl
      );
    }

    test('speedLines standard：白纸压墨、暗区爆白（两极都有）', () {
      final s = dirs([EffectKind.parallax, EffectKind.speedLines],
          RenderTier.standard, 0.5);
      expect(s.lightDarker, greaterThan(0),
          reason: '白纸上依然只画白线 = 白叠白没修好');
      expect(s.lightLighter, 0, reason: '纸白一极只准压暗');
      expect(s.darkLighter, greaterThan(0), reason: '暗区应继续爆白');
      expect(s.darkDarker, 0, reason: '暗区一极只准提亮');
    });

    test('impactFlash standard：双向对比冲击，白区不再是 no-op', () {
      // t=0.05 落在 dutyFrac=0.12 的闪光沿内（k≈124）。
      final s = dirs([EffectKind.parallax, EffectKind.impactFlash],
          RenderTier.standard, 0.05);
      expect(s.lightDarker, greaterThan(1000), reason: '白纸没被压黑');
      expect(s.darkLighter, greaterThan(1000), reason: '暗区没被爆白');
      expect(s.lightLighter + s.darkDarker, 0);
    });

    test('lightSweep standard：光带过纸面时压灰、过暗区时提亮', () {
      final s = dirs([EffectKind.parallax, EffectKind.lightSweep],
          RenderTier.standard, 1.5);
      expect(s.lightDarker, greaterThan(0), reason: '扫光在白纸上又叠了白');
      expect(s.darkLighter, greaterThan(0));
      expect(s.lightLighter + s.darkDarker, 0);
    });

    test('显式 legacy 档逐字节不变（R10 冻结契约）', () {
      // R28（Task 3.6）：默认档已升到 standard ⇒「含默认档」的前提死了，本条
      // 只保留**显式 tier: legacy** 的五个冻结用例（金标准一字未改），它们才是
      // 「legacy 仍供显式选择且字节冻结」的证据；默认档那一半拆到下一条测试。
      // 摘要取自**改动前的 HEAD**（把 BASE 的三个 lib 文件复制进临时包跑同一
      // 份脚本），这里逐条对上 ⇒ 「新极性只活在 standard+」是可执行证明，
      // 而不只是口头承诺；改动后再跑一次同脚本报数完全一致。
      final cases = <String, (List<EffectKind>, RenderTier, double, String)>{
        'speedLines@legacy': (
          [EffectKind.parallax, EffectKind.speedLines],
          RenderTier.legacy,
          0.5,
          _BASE_SPEED_LEGACY
        ),
        'impactFlash@legacy': (
          [EffectKind.parallax, EffectKind.impactFlash],
          RenderTier.legacy,
          0.05,
          _BASE_FLASH_LEGACY
        ),
        'lightSweep@legacy': (
          [EffectKind.parallax, EffectKind.lightSweep],
          RenderTier.legacy,
          1.5,
          _BASE_SWEEP_LEGACY
        ),
        'focusLines@legacy': (
          [EffectKind.parallax, EffectKind.focusLines],
          RenderTier.legacy,
          0.5,
          _BASE_FOCUS_LEGACY
        ),
        'all-four@legacy': (
          [
            EffectKind.parallax,
            EffectKind.speedLines,
            EffectKind.impactFlash,
            EffectKind.lightSweep,
            EffectKind.focusLines
          ],
          RenderTier.legacy,
          0.05,
          _BASE_ALL_LEGACY
        ),
      };
      for (final e in cases.entries) {
        final (kinds, tier, t, want) = e.value;
        expect(_fnv(render(kinds, tier, t).data), equals(want),
            reason: '${e.key} 的 legacy 产物被改动了');
      }
    });

    test('默认档已是 standard：行为门 + 绝对 digest 已锚定 v1.4.0', () {
      // R24/R28（Task 3.6）：不写 quality 段的配置现在解析成 standard，
      // 「默认档也逐字节冻结成 legacy」的前提已经不存在。
      // 行为半（本轮就能绿，且是真的门）：默认档产物必须**等于**显式 standard、
      // **不等于**显式 legacy ⇒ 默认档确实翻到了 standard，legacy 只剩显式选择。
      const kinds = [
        EffectKind.parallax,
        EffectKind.speedLines,
        EffectKind.impactFlash
      ];
      final def = FrameCompositor(layers, img,
              EffectConfig(
                  effects: kinds, fps: 8, durationSec: 2, seed: 77))
          .renderFrame(0.05);
      expect(EffectConfig(effects: kinds, fps: 8, durationSec: 2, seed: 77).quality.tier,
          RenderTier.standard,
          reason: '默认 quality.tier 必须是 standard（R24）');
      expect(def.data,
          equals(render(kinds, RenderTier.standard, 0.05).data),
          reason: '默认档（不写 quality）应与显式 standard 逐字节一致');
      expect(def.data,
          isNot(equals(render(kinds, RenderTier.legacy, 0.05).data)),
          reason: '默认档不应再等于 legacy 字节');
      // 绝对半：锚点原存的是 v1.3.2 的 **legacy 默认档**字节 ⇒ 3.6 把默认档升到
      // standard 后必然对不上（R31 的授权预期红），Task 3.7 已把它改锚到
      // standard 默认档自己的摘要。上面三条行为门一字未动，才是本轮的门。
      expect(_fnv(def.data), equals(_BASE_DEFAULT_TIER),
          reason: '默认档 digest 必须等于 v1.4.0 standard 默认档锚点');
    });

    test('standard 档与 legacy 档确实不同（极性生效）', () {
      for (final k in [
        EffectKind.speedLines,
        EffectKind.impactFlash,
        EffectKind.lightSweep,
        EffectKind.focusLines,
      ]) {
        final l = render([EffectKind.parallax, k], RenderTier.legacy, 0.5);
        final s = render([EffectKind.parallax, k], RenderTier.standard, 0.5);
        var diff = 0;
        for (var i = 0; i < l.data.length; i++) {
          if (l.data[i] != s.data[i]) diff++;
        }
        expect(diff, greaterThan(0), reason: '${k.name} 的 standard 极性没落地');
      }
    });

    test('standard 档保持确定性与整循环无缝（R12）', () {
      // 只启用叠加类效果：parallax 的相位周期与时长不成整倍数，首尾本就只
      // 近似相等（同 test/engine_test.dart 的 seamless 口径）。
      const kinds = [
        EffectKind.speedLines,
        EffectKind.impactFlash,
        EffectKind.lightSweep,
        EffectKind.focusLines,
      ];
      expect(render(kinds, RenderTier.standard, 0.7).data,
          equals(render(kinds, RenderTier.standard, 0.7).data),
          reason: '极性采样引入了跨帧状态？');
      expect(render(kinds, RenderTier.standard, 0.0).data,
          equals(render(kinds, RenderTier.standard, 2.0).data),
          reason: 'standard 档首尾帧必须逐字节一致');
      // legacy 同步钉住：证明各效果的属性 RNG 抽取顺序/次数一处都没动。
      expect(render(kinds, RenderTier.legacy, 0.0).data,
          equals(render(kinds, RenderTier.legacy, 2.0).data));
    });

    test('godRays / shimmer / fireflies / embers / starlight 仍是纯提亮（R11）',
        () {
      // 这些效果被明确排除在极性改造之外：给它们加压暗会打断
      // engine_test 的「光效只提亮」不变式，这里反向钉住其 standard 产物。
      for (final k in [
        EffectKind.godRays,
        EffectKind.shimmer,
        EffectKind.fireflies,
        EffectKind.embers,
        EffectKind.starlight,
      ]) {
        final s = dirs([EffectKind.parallax, k], RenderTier.standard, 0.5);
        expect(s.lightDarker + s.darkDarker, 0,
            reason: '${k.name} 不该出现压暗像素（R11 范围外）');
      }
    });
  });
}

// 显式 tier:legacy 的帧摘要金标（R10 冻结契约的锚点）+ 默认档绝对摘要。
//
// Task 3.7 唯一一次 re-baseline（H2）——六个常量全部改锚到 v1.4.0：
//   * 移动的根因是**默认值**，不是 legacy 像素算法：3.1 抬高的振幅默认值与
//     3.5 的整周期对齐/timing snap 都进入 legacy 档的位移量。台账在
//     3.2/3.4/3.6/3.6b/3.6d/3.6e 每一轮都独立复测过 explicit-legacy actual
//     未动（speed 那条到 3.6d 仍是 -68ddcb969faac38c）⇒ legacy 算法一字未改。
//   * H2 正是为此而裁：`tier: legacy` 冻结**像素算法**，不冻结旧默认值。要旧
//     默认值请走 presets/legacy_v1.0.json（R40），那才是逐字节回滚开关。
//   * 后四条（flash/sweep/focus/all）在 3.1→3.6 期间从未被打印过：本条测试是
//     map 上的 fail-fast 循环，第一条红把后面四条全遮住了 ⇒ 各轮「只有 N 个
//     授权红」的普查数是**下界**；完整 census 见报告 TASK 3.7 节。
const String _BASE_SPEED_LEGACY = '-68ddcb969faac38c';
const String _BASE_FLASH_LEGACY = '-121bf1041d4a12bb';
const String _BASE_SWEEP_LEGACY = '-7a554b5bfb98e3e0';
const String _BASE_FOCUS_LEGACY = '-899a523d81898c8';
const String _BASE_ALL_LEGACY = '-53dbb870578e6226';
const String _BASE_DEFAULT_TIER = '-701dc2404f559e1b';
