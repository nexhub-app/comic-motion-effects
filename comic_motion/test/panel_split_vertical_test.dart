import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// X4（v1.5）：PanelSplitter 纵向白带细分 —— 单行多列与网格页检测。
///
/// 红线锚点：单列页（检不出纵向白带）的检出结果与 v1.4 横向-only 版本
/// **一致**（行带原样保留，同为全宽矩形）；纵向阈值与横向同构（白带厚
/// × 页宽、格宽 ≥ minPanelFrac × 页宽）；格序行主序；纯函数确定性。
/// PixelRect 无 == 覆写，相等断言一律逐字段（[rectEq]）。
void main() {
  bool rectEq(PixelRect a, int x, int y, int w, int h) =>
      a.x == x && a.y == y && a.width == w && a.height == h;

  /// 2×2 网格：四块彩色内容 + 横纵白带（20px）。
  RgbaImage grid2x2Raster() {
    const w = 300, h = 400;
    final im = RgbaImage(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        im.data[o + 3] = 255;
        final inBand = (y >= 190 && y < 210) || (x >= 140 && x < 160);
        if (inBand) {
          im.data[o] = 255;
          im.data[o + 1] = 255;
          im.data[o + 2] = 255;
          continue;
        }
        final top = y < 190;
        final left = x < 140;
        im.data[o] = top ? (left ? 220 : 40) : (left ? 40 : 220);
        im.data[o + 1] = top == left ? 60 : 200;
        im.data[o + 2] = top ? 30 : 90;
      }
    }
    return im;
  }

  /// 单行左右两格：只有一条纵向白带，无横向白带（v1.4 只会返回整页）。
  RgbaImage sideBySideRaster() {
    const w = 300, h = 200;
    final im = RgbaImage(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        im.data[o + 3] = 255;
        if (x >= 140 && x < 160) {
          im.data[o] = 255;
          im.data[o + 1] = 255;
          im.data[o + 2] = 255;
        } else {
          im.data[o] = x < 140 ? 200 : 40;
          im.data[o + 1] = 60;
          im.data[o + 2] = x < 140 ? 30 : 120;
        }
      }
    }
    return im;
  }

  /// 单列上下两格（v1.4 时代即检出的形态，回归锚）。
  RgbaImage stackedRaster() {
    const w = 200, h = 300;
    final im = RgbaImage(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        im.data[o + 3] = 255;
        if (y >= 140 && y < 160) {
          im.data[o] = 255;
          im.data[o + 1] = 255;
          im.data[o + 2] = 255;
        } else {
          im.data[o] = y < 140 ? 200 : 40;
          im.data[o + 1] = 60;
          im.data[o + 2] = 30;
        }
      }
    }
    return im;
  }

  group('PanelSplitter：纵向白带细分（X4）', () {
    test('2×2 网格检出 4 格，行主序', () {
      final panels = const PanelSplitter().split(grid2x2Raster());
      expect(panels, hasLength(4));
      // 行主序：上左、上右、下左、下右。
      expect(panels[0].y, lessThan(panels[2].y), reason: '前两格在上行');
      expect(panels[0].x, lessThan(panels[1].x), reason: '上行内左在右前');
      expect(panels[2].x, lessThan(panels[3].x), reason: '下行内左在右前');
      expect(rectEq(panels[0], 0, 0, 140, 190), isTrue, reason: '上左格');
      expect(rectEq(panels[1], 160, 0, 140, 190), isTrue, reason: '上右格');
      expect(rectEq(panels[2], 0, 210, 140, 190), isTrue, reason: '下左格');
      expect(rectEq(panels[3], 160, 210, 140, 190), isTrue, reason: '下右格');
    });

    test('单行左右两格检出 2 格（v1.4 只会返回整页）', () {
      final panels = const PanelSplitter().split(sideBySideRaster());
      expect(panels, hasLength(2));
      expect(panels[0].y, 0);
      expect(panels[0].height, 200, reason: '同一行带内格子等高');
      expect(rectEq(panels[0], 0, 0, 140, 200), isTrue, reason: '左格');
      expect(rectEq(panels[1], 160, 0, 140, 200), isTrue, reason: '右格');
    });

    test('单列两格与 v1.4 横向-only 结果一致（全宽行带，回归锚）', () {
      final panels = const PanelSplitter().split(stackedRaster());
      expect(panels, hasLength(2));
      expect(rectEq(panels[0], 0, 0, 200, 140), isTrue);
      expect(rectEq(panels[1], 0, 160, 200, 140), isTrue);
    });

    test('纵白带过窄（低于 minGutterFrac × 页宽）不触发细分', () {
      const w = 300, h = 200;
      // 1px 白列 = 笔触/扫描噪声（1 < 0.5%×300 = 1.5px），不构成分隔带。
      final narrow = RgbaImage(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          narrow.data[o] = 30;
          narrow.data[o + 1] = 60;
          narrow.data[o + 2] = 30;
          narrow.data[o + 3] = 255;
          if (x == 150) {
            narrow.data[o] = 255;
            narrow.data[o + 1] = 255;
            narrow.data[o + 2] = 255;
          }
        }
      }
      final panels = const PanelSplitter().split(narrow);
      expect(panels, hasLength(1), reason: '1px 白列低于最小白带厚度，不细分');
      expect(rectEq(panels.single, 0, 0, w, h), isTrue);
    });

    test('右缘留白不是分隔带（页边白不算格边界）', () {
      const w = 300, h = 200;
      final im = RgbaImage(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          im.data[o + 3] = 255;
          final white = x >= 250; // 右缘 50px 全白
          im.data[o] = white ? 255 : 30;
          im.data[o + 1] = white ? 255 : 60;
          im.data[o + 2] = white ? 255 : 30;
        }
      }
      final panels = const PanelSplitter().split(im);
      expect(panels, hasLength(1), reason: '尾部白列不算分隔带');
      expect(rectEq(panels.single, 0, 0, w, h), isTrue);
    });

    test('确定性：同输入两次调用结果一致', () {
      final a = const PanelSplitter().split(grid2x2Raster());
      final b = const PanelSplitter().split(grid2x2Raster());
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(rectEq(a[i], b[i].x, b[i].y, b[i].width, b[i].height), isTrue);
      }
    });
  });
}
