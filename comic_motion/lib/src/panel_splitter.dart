/// 分格感知分层（W5）：白带扫描检测漫画分格边界。
///
/// v1.5（X4）起为**两级检测**：先横向白带切出行带，再在每条行带内做纵向
/// 白带细分。此前的版本只有横向扫描（文件头注释明说「纵向细分列为进阶，
/// 本 MVP 不做」），2×2 网格页只会被切成 2 条全宽横条；纵向细分补上后，
/// 单行多列（1×2）与网格（2×2、2×3）页都能切到真格。行带内检不出纵向
/// 白带时该行原样保留（返回与旧版完全相同的全宽矩形），因此**单列页的
/// 检出结果与旧版逐字节一致**。
///
/// 检测算法（均衡档参数，经方案确认）：
///
/// 1. 逐行统计「近白占比」：行内亮度 ≥ [whiteLum]（默认 245）的像素占比
///    ≥ [whiteRatio]（默认 0.90）即记为白带行；
/// 2. 连续白带行成带，带厚 ≥ [minGutterFrac] × 页高（默认 0.5%）才算
///    分隔带（过滤笔触噪声与行间距）；
/// 3. 相邻分隔带之间（含页顶/页底与首末分隔带之间）为候选行带，行带高
///    ≥ [minPanelFrac] × 页高（默认 6%）才保留（过滤页边距碎屑；过矮候选
///    并入上一行带）；
/// 4. 每条保留的行带内重复 1-3 的列向版本：列内「该行带像素的近白占比」
///    ≥ [whiteRatio] 记为白带列，带厚 ≥ [minGutterFrac] × 页宽，候选列
///    宽 ≥ [minPanelFrac] × 页宽；检不出纵向白带的行带原样返回；
/// 5. 全部格子数 < 2 → 视为单格/无白带图，返回整页矩形（调用方据此回退
///    整页分层，与 panelAware 关闭时逐字节等价）。
///
/// 格序为行主序（上→下、行内左→右），确定性。纯函数：无随机、无时钟，
/// 同输入同输出（确定性契约）。层级刻意止于两级：真正的递归细分（任意
/// 镶嵌布局）需要按子格面积重判阈值，收益不成比例，见 roadmap。
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

  /// 近白判定亮度阈值（行/列内像素亮度 ≥ 此值记为白）。
  final int whiteLum;

  /// 行/列内近白像素占比 ≥ 此值记为白带。
  final double whiteRatio;

  /// 白带最小厚度（横向 × 页高、纵向 × 页宽），低于此不算分隔带。
  final double minGutterFrac;

  /// 格子最小尺寸（横向 × 页高、纵向 × 页宽），低于此的候选被并入相邻格
  /// （丢弃边界）。
  final double minPanelFrac;

  /// 检测分格。返回格子矩形列表（画布坐标，行主序）；无白带/单格时返回
  /// `[整页]`（恰好一个矩形，等于全画布）。
  List<PixelRect> split(RgbaImage img) {
    final h = img.height;
    final w = img.width;
    if (h < 2 || w < 2) return [PixelRect(0, 0, w, h)];

    // 1) 逐行近白占比。
    final rowWhite = List<bool>.filled(h, false);
    final rowThreshold = (w * whiteRatio).ceil();
    for (var y = 0; y < h; y++) {
      rowWhite[y] = _runWhiteRatio(img, 0, y, w) >= rowThreshold;
    }

    // 2) 连续白带行 → 分隔带（厚度达标才计入）。
    final gutters = _whiteRuns(rowWhite, h,
        minRun: (h * minGutterFrac).round().clamp(1, h));

    // 3) 分隔带之间为候选行带；过滤顶部/底部整页白边与过矮候选。
    final minPanelH = (h * minPanelFrac).round();
    var rows = _candidates(rowWhite, h, gutters, minPanelH);
    // 横向只切出 0-1 条行带（单行多列页、无白带页）时，把整页当作唯一行带
    // 继续走纵向细分——纵向白带仍可能给出真分格；之后统一按「格子数 < 2 →
    // 整页」回退，单列/无白带图的最终结果仍是整页矩形（等价旧版）。
    if (rows.isEmpty) rows = [(0, h)];

    // 4) 每条行带内做纵向细分；检不出纵向白带的行带原样保留（与旧版的
    //    全宽矩形逐字节一致，单列页因此不受本次改动影响）。
    final panels = <PixelRect>[];
    for (final b in rows) {
      panels.addAll(_splitRowVertical(img, PixelRect(0, b.$1, w, b.$2 - b.$1), w));
    }
    if (panels.length < 2) return [PixelRect(0, 0, w, h)];
    return panels;
  }

  /// 统计 `[x0, x0 + span)` 内、第 [y] 行的近白像素数（亮度用
  /// (r*2 + g*3 + b)/6 近似——引擎输出为不透明白底漫画）。
  int _runWhiteRatio(RgbaImage img, int x0, int y, int span) {
    var count = 0;
    final base = y * img.width * 4;
    for (var x = x0; x < x0 + span; x++) {
      final o = base + x * 4;
      final lum =
          (img.data[o] * 2 + img.data[o + 1] * 3 + img.data[o + 2]) ~/ 6;
      if (lum >= whiteLum) count++;
    }
    return count;
  }

  /// 第 [x] 列在 `[y0, y1)` 行区间内的近白像素数。与 [_runWhiteRatio] 同一
  /// 亮度口径，保证横纵两向对「白」的判定一致。
  int _columnWhiteRatio(RgbaImage img, int x, int y0, int y1) {
    var count = 0;
    for (var y = y0; y < y1; y++) {
      final o = (y * img.width + x) * 4;
      final lum =
          (img.data[o] * 2 + img.data[o + 1] * 3 + img.data[o + 2]) ~/ 6;
      if (lum >= whiteLum) count++;
    }
    return count;
  }

  /// 把布尔行/列标记折成「厚度达标的白带」区间列表（`[start, end)`）。
  /// 首部白边不算分隔带（页顶留白不是分格边界）；尾部白边仅在起点 > 0 时
  /// 计入——与横向检测的既有口径一致（页底留白不是分格边界）。
  List<(int, int)> _whiteRuns(List<bool> marks, int total,
      {required int minRun}) {
    final runs = <(int, int)>[];
    var runStart = -1;
    for (var i = 0; i < total; i++) {
      if (marks[i]) {
        if (runStart < 0) runStart = i;
      } else {
        if (runStart >= 0 && i - runStart >= minRun) {
          runs.add((runStart, i));
        }
        runStart = -1;
      }
    }
    if (runStart >= 0 && total - runStart >= minRun && runStart > 0) {
      runs.add((runStart, total));
    }
    return runs;
  }

  /// 白带之间的候选区间：厚度达 [minSize] 的保留；过矮/过窄候选并入上一格
  /// （避免格间碎屑丢失内容），首格之前的过矮候选直接丢弃（页边距）。
  /// 横向行带与纵向列带共用同一过滤（与 v1.4 横向检测的既有口径一致）。
  List<(int, int)> _candidates(
      List<bool> marks, int total, List<(int, int)> runs, int minSize) {
    final bands = <(int, int)>[];
    var contentStart = 0;
    for (final g in runs) {
      if (g.$1 > contentStart) bands.add((contentStart, g.$1));
      contentStart = g.$2;
    }
    if (contentStart < total) bands.add((contentStart, total));

    final kept = <(int, int)>[];
    for (final b in bands) {
      if (b.$2 - b.$1 >= minSize) {
        kept.add(b);
      } else if (kept.isNotEmpty) {
        final prev = kept.last;
        kept[kept.length - 1] = (prev.$1, b.$2);
      }
    }
    return kept;
  }

  /// 在一条行带内做纵向白带细分。检不出 ≥2 个候选列时原样返回
  /// `[row]`（全宽矩形，与旧版逐字节一致）。
  List<PixelRect> _splitRowVertical(RgbaImage img, PixelRect row, int w) {
    final colWhite = List<bool>.filled(w, false);
    final colThreshold = (row.height * whiteRatio).ceil();
    for (var x = 0; x < w; x++) {
      colWhite[x] =
          _columnWhiteRatio(img, x, row.y, row.y + row.height) >= colThreshold;
    }
    final gutters = _whiteRuns(colWhite, w,
        minRun: (w * minGutterFrac).round().clamp(1, w));
    final minPanelW = (w * minPanelFrac).round();
    final columns = _candidates(colWhite, w, gutters, minPanelW);
    if (columns.length < 2) return [row];
    return [
      for (final c in columns)
        PixelRect(c.$1, row.y, c.$2 - c.$1, row.height)
    ];
  }
}
