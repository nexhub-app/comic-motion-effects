/// 分格感知分层（W5）：横向白带扫描检测漫画分格边界。
///
/// 漫画单页的分格以**水平白带**分隔为主（含纵向细分格的递归检测列为
/// 进阶，本 MVP 不做）。检测算法（均衡档参数，经方案确认）：
///
/// 1. 逐行统计「近白占比」：行内亮度 ≥ [whiteLum]（默认 245）的像素占比
///    ≥ [whiteRatio]（默认 0.90）即记为白带行；
/// 2. 连续白带行成带，带厚 ≥ [minGutterFrac] × 页高（默认 0.5%）才算
///    分隔带（过滤笔触噪声与行间距）；
/// 3. 相邻分隔带之间（含页顶/页底与首末分隔带之间）为候选格，格高
///    ≥ [minPanelFrac] × 页高（默认 6%）才保留（过滤页边距碎屑）；
/// 4. 检出格数 < 2 → 视为单格/无白带图，返回整页矩形（调用方据此回退
///    整页分层，与 panelAware 关闭时逐字节等价）。
///
/// 纯函数：无随机、无时钟，同输入同输出（确定性契约）。
library;

import 'image_model.dart';
import 'apng_writer.dart' show PixelRect;

class PanelSplitter {
  const PanelSplitter({
    this.whiteLum = 245,
    this.whiteRatio = 0.90,
    this.minGutterFrac = 0.005,
    this.minPanelFrac = 0.06,
  });

  /// 近白判定亮度阈值（行内像素亮度 ≥ 此值记为白）。
  final int whiteLum;

  /// 行内近白像素占比 ≥ 此值记为白带行。
  final double whiteRatio;

  /// 白带最小厚度（× 页高），低于此不算分隔带。
  final double minGutterFrac;

  /// 格子最小高度（× 页高），低于此的候选格被并入相邻格（丢弃边界）。
  final double minPanelFrac;

  /// 检测分格。返回格子矩形列表（画布坐标）；无白带/单格时返回
  /// `[整页]`（恰好一个矩形，等于全画布）。
  List<PixelRect> split(RgbaImage img) {
    final h = img.height;
    final w = img.width;
    if (h < 2 || w < 2) return [PixelRect(0, 0, w, h)];

    // 1) 逐行近白占比。
    final rowWhite = List<bool>.filled(h, false);
    final threshold = (w * whiteRatio).ceil();
    for (var y = 0; y < h; y++) {
      var count = 0;
      final base = y * w * 4;
      for (var x = 0; x < w; x++) {
        final o = base + x * 4;
        // 亮度 = (r*2 + g*3 + b) / 6 近似（引擎输出为不透明白底漫画）。
        final lum = (img.data[o] * 2 + img.data[o + 1] * 3 + img.data[o + 2]) ~/ 6;
        if (lum >= whiteLum) count++;
      }
      rowWhite[y] = count >= threshold;
    }

    // 2) 连续白带行 → 分隔带（厚度达标才计入）。
    final minGutter = (h * minGutterFrac).round().clamp(1, h);
    final gutters = <(int, int)>[]; // [start, end) 行区间
    var runStart = -1;
    for (var y = 0; y < h; y++) {
      if (rowWhite[y]) {
        if (runStart < 0) runStart = y;
      } else {
        if (runStart >= 0 && y - runStart >= minGutter) {
          gutters.add((runStart, y));
        }
        runStart = -1;
      }
    }
    // 尾部白边不算分隔带（页底留白不是分格边界）。
    if (runStart >= 0 && h - runStart >= minGutter && runStart > 0) {
      gutters.add((runStart, h));
    }

    // 3) 分隔带之间为候选格；过滤顶部/底部整页白边与过矮候选。
    final bands = <(int, int)>[]; // 内容行区间 [top, bottom)
    var contentStart = 0;
    for (final g in gutters) {
      if (g.$1 > contentStart) bands.add((contentStart, g.$1));
      contentStart = g.$2;
    }
    if (contentStart < h) bands.add((contentStart, h));
    // 页顶/页底若整段是白边（没有内容），上面循环自然不产生对应 band。

    final minPanel = (h * minPanelFrac).round();
    final panels = <PixelRect>[];
    for (final b in bands) {
      if (b.$2 - b.$1 >= minPanel) {
        panels.add(PixelRect(0, b.$1, w, b.$2 - b.$1));
      } else if (panels.isNotEmpty) {
        // 过矮候选：扩展上一格底边吞掉（避免格间碎屑丢失内容）。
        final prev = panels.last;
        panels[panels.length - 1] =
            PixelRect(prev.x, prev.y, prev.width, prev.height + (b.$2 - b.$1));
      }
      // 首格之前的过矮候选直接丢弃（页顶页边距）。
    }

    // 4) 单格回退：无白带或仅一条内容带 → 整页（调用方等价回退）。
    if (panels.length < 2) return [PixelRect(0, 0, w, h)];
    return panels;
  }
}
