import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// 合成画面构造器（确定性，无随机）：
/// - 文字格：白底 + **去格点化**小暗斑（气泡文字的结构代理：密集小暗连
///   通域、白底可见、边缘方向散乱；位置/行长/行距确定性行内抖动——真实
///   字形不是等距点阵，格点化夹具会被网点周期性特征否决）。
/// - 动作格：灰底 + 平行斜线族（速度线/集中线的结构代理：单方向长笔触，
///   方向一致性高）。
/// - 模糊格：均匀灰底（无强特征——「模糊→动」语义的锁）。
RgbaImage textPanel(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, 255, 255, 255);
    }
  }
  // 确定性伪随机（LCG，与 tool/synthetic_pages.dart 同族常数）。
  var state = 20261025;
  int next(int max) {
    state = (state * 6364136223846793005 + 1442695040888963407) &
        0x7fffffffffffffff;
    return (state >> 33) % max;
  }

  var gy = 2;
  while (gy < h - 3) {
    var gx = 2 + next(5);
    while (gx < w - 4) {
      final runLen = 1 + next(4);
      final thick = 2 + next(2);
      final jx = next(3);
      for (var dy = 0; dy < thick; dy++) {
        for (var dx = 0; dx < runLen; dx++) {
          final px = gx + dx + jx, py = gy + dy;
          if (px < w - 2 && py < h - 2) img.setPixel(px, py, 30, 30, 30);
        }
      }
      gx += runLen + 3 + next(3);
    }
    gy += 6 + next(4);
  }
  return img;
}

RgbaImage actionPanel(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, 200, 200, 200);
    }
  }
  // 45° 平行长线族（速度线），间隔 6px。
  for (var s = -h; s < w + h; s += 6) {
    for (var t = 0; t < h; t++) {
      final x = s + t;
      if (x < 0 || x >= w) continue;
      img.setPixel(x, t, 20, 20, 20);
    }
  }
  return img;
}

RgbaImage flatPanel(int w, int h, [int v = 160]) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, v, v, v);
    }
  }
  return img;
}

void main() {
  group('特征提取（extractPanelMotionFeatures）', () {
    test('纯白图：speck=0、white=1、dirCoh=0', () {
      final f = extractPanelMotionFeatures(flatPanel(64, 64, 255));
      expect(f.speckDensity, 0.0);
      expect(f.whiteFrac, 1.0);
      expect(f.dirCoherence, 0.0);
    });

    test('文字格：speck 高（>kTextSpeckMin）、white 高、dirCoh 低', () {
      final f = extractPanelMotionFeatures(textPanel(120, 120));
      expect(f.speckDensity, greaterThan(kTextSpeckMin));
      expect(f.whiteFrac, greaterThan(kTextWhiteMin));
      expect(f.dirCoherence, lessThan(kMaxDirCoh));
    });

    test('动作格（平行斜线族）：dirCoh 高（>kMaxDirCoh），不可判静', () {
      final f = extractPanelMotionFeatures(actionPanel(120, 120));
      expect(f.dirCoherence, greaterThan(kMaxDirCoh));
      expect(f.speckDensity, lessThan(kTextSpeckMin),
          reason: '长线是大连通域，不产生文字斑点');
    });

    test('棋盘格（大暗连通域）：speck≈0（面积上限滤掉色块，语义护栏防误伤）', () {
      final img = RgbaImage(width: 120, height: 120);
      for (var y = 0; y < 120; y++) {
        for (var x = 0; x < 120; x++) {
          final dark = (x ~/ 12 + y ~/ 12).isEven;
          img.setPixel(x, y, dark ? 40 : 220, dark ? 40 : 220, 40);
        }
      }
      final f = extractPanelMotionFeatures(img);
      expect(f.speckDensity, 0.0);
    });
  });

  group('校准常量（分布勘察定值区间，防手滑）', () {
    test('kTextSpeckMin ∈ [3.0, 4.0]（47 格分布自然谷 2.8–4.4）', () {
      expect(kTextSpeckMin, inInclusiveRange(3.0, 4.0));
    });

    test('kTextWhiteMin ∈ [0.10, 0.15]（语义护栏：气泡白底可见性下限）', () {
      expect(kTextWhiteMin, inInclusiveRange(0.10, 0.15));
    });

    test('kMaxDirCoh ∈ [0.24, 0.30]（47 格分布自然谷 0.24–0.30）', () {
      expect(kMaxDirCoh, inInclusiveRange(0.24, 0.30));
    });
  });

  group('HeuristicPanelMotionJudge（模糊→动）', () {
    const judge = HeuristicPanelMotionJudge();

    test('文字主导格 → 0.0（不需要动效）', () {
      final scales = judge.panelScales(
          textPanel(120, 120), [const PixelRect(0, 0, 120, 120)]);
      expect(scales, [0.0]);
    });

    test('动作格（方向笔触族）→ 1.0（需要动效）', () {
      final scales = judge.panelScales(
          actionPanel(120, 120), [const PixelRect(0, 0, 120, 120)]);
      expect(scales, [1.0]);
    });

    test('模糊格（无特征灰底）→ 1.0：拿不准就保持动', () {
      final scales = judge.panelScales(
          flatPanel(120, 120), [const PixelRect(0, 0, 120, 120)]);
      expect(scales, [1.0]);
    });

    test('混合页逐格裁决：文字格静、动作格动', () {
      // 上 60px 文字格 + 下 60px 动作格，两格矩形由调用方给出。
      final img = RgbaImage(width: 120, height: 120);
      final text = textPanel(120, 60);
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 120; x++) {
          final o = (y * 120 + x) * 4;
          img.setPixel(x, y, text.data[o], text.data[o + 1], text.data[o + 2]);
        }
      }
      for (var s = -60; s < 120 + 60; s += 6) {
        for (var t = 60; t < 120; t++) {
          final x = s + (t - 60);
          if (x < 0 || x >= 120) continue;
          img.setPixel(x, t, 20, 20, 20);
        }
      }
      final scales = judge.panelScales(img, [
        const PixelRect(0, 0, 120, 60),
        const PixelRect(0, 60, 120, 60),
      ]);
      expect(scales, [0.0, 1.0]);
    });

    test('逐格裁剪：判断只看格内像素（跨格不串）', () {
      // 整图左半文字右半灰底；两格矩形各取半边。
      final img = RgbaImage(width: 120, height: 60);
      final text = textPanel(60, 60);
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 120; x++) {
          if (x < 60) {
            final o = (y * 60 + x) * 4;
            img.setPixel(
                x, y, text.data[o], text.data[o + 1], text.data[o + 2]);
          } else {
            img.setPixel(x, y, 160, 160, 160);
          }
        }
      }
      final scales = judge.panelScales(img, [
        const PixelRect(0, 0, 60, 60),
        const PixelRect(60, 0, 60, 60),
      ]);
      expect(scales, [0.0, 1.0]);
    });
  });
}
