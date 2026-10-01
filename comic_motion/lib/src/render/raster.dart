/// 抗锯齿光栅原语（standard+ 档专用）。
///
/// 全部是纯函数：输入栅格 + 几何参数，就地写入像素，可脱离合成器单测。
/// 覆盖度（coverage）统一为 0..255：像素中心到形状边界的解析距离经 1px 过渡
/// 带折算，因此斜线不再有点状阶梯、圆不再有硬边。legacy 档不调用本文件，
/// 回滚承诺由「旧路径原样保留」保证。
library;

import 'dart:math' as math;

import '../apng_writer.dart' show PixelRect;
import '../image_model.dart';

/// 光照叠加方式。
///
/// v1.2 的提亮是截断加法 `min(255, d + s·a/255)`：两处不同的近白高光会同时撞
/// 到 255 而失去层次（光晕把高光糊成一片死白）。[BlendOp.screen] 用
/// `255 - (255-d)(255-s·a/255)/255` 渐近到白，任何亮度下都严格单调，高光内部
/// 的落差得以保留。legacy 档必须留在 [BlendOp.additive]（逐字节回滚承诺）。
///
/// Task 2.4（spec §5「极性自适应」）补两个**压暗**算子，用来治「白线叠白纸」：
/// [BlendOp.darken] 取逐通道最小值（白纸压墨，绝不提亮），[BlendOp.multiply]
/// 按 `d·(s·a + 255·(1-a))/255` 等比压暗（保住底图自身的明暗落差）。
enum BlendOp { over, additive, screen, darken, multiply }

/// 一笔该压墨还是爆白（spec §5：白纸（lum>200）→ 深墨，暗区（lum<80）→ 白线）。
enum Polarity { toInk, toLight }

/// 墨色 `#1a1a1a`：白纸上的深墨线，比纯黑更像印刷油墨、也不会把网点压死。
const int inkRgb = 0x1a1a1a;

/// 亮度 → 极性。
///
/// `lum > 200` 判白纸走 [Polarity.toInk]，`lum < 80` 判暗区走
/// [Polarity.toLight]，中段按到中点 `(200+80)/2 = 140` 的距离取最近一档
/// （[PolarityBrush] 再对中段补一次幅度放大，见 [PolarityBrush.bump]）。
Polarity samplePolarity(int lum) => lum > 200
    ? Polarity.toInk
    : (lum < 80
        ? Polarity.toLight
        : (lum >= 140 ? Polarity.toInk : Polarity.toLight));

/// 极性自适应画笔：将「该点底图亮度」折成「颜色 + 算子」的查表器。
///
/// 只读**静态底图**（[base]），输入是像素坐标、输出是纯函数结果：无时钟、
/// 无随机、无跨帧可变量，所以确定性与「t=0 ≡ t=durationSec」的无缝承诺天然
/// 保持（R12）。落在合成器的 `_aa` 门控之后，legacy 档根本不构造它。
class PolarityBrush {
  const PolarityBrush(this.base, {this.ink = inkRgb});

  /// 被采样底图。绘制目标 frame 与它同尺寸（合成器以 `base.width/height`
  /// 建帧），因此像素索引可直接复用。
  final RgbaImage base;

  /// 压墨一极的墨色（爆白一极沿用调用方传入的亮色）。
  final int ink;

  int get inkR => (ink >> 16) & 0xff;
  int get inkG => (ink >> 8) & 0xff;
  int get inkB => ink & 0xff;

  /// 该点底图亮度。越界坐标钳回边缘取样：这类点随后会被 [blendPixel] 的边界
  /// 检查拒掉，取到什么亮度都不影响像素，只是防止索引抛 RangeError。
  int lumaAt(int x, int y) {
    final b = base;
    final cx = x < 0 ? 0 : (x >= b.width ? b.width - 1 : x);
    final cy = y < 0 ? 0 : (y >= b.height ? b.height - 1 : y);
    return b.luminance(cy * b.width + cx);
  }

  Polarity at(int x, int y) => samplePolarity(lumaAt(x, y));

  /// 白纸压墨走 [BlendOp.darken]（恒不提亮、墨色实打实盖住纸白）。
  static const BlendOp inkOp = BlendOp.darken;

  /// 暗区爆白走 [BlendOp.screen]（渐近到白，保住暗部层次）。
  static const BlendOp lightOp = BlendOp.screen;

  /// 中段亮度（80 < lum < 200）：两档极性都不算「白纸」也不算「暗区」，对比
  /// 最弱，spec §5 要求此处放大幅度。连续 lerp 会让同一笔内相邻像素的 op 混序
  /// 变得难以复现，这里用「离散最近档 + 固定 1/4 增幅」近似那一格 lerp。
  static bool midLuma(int lum) => lum > 80 && lum < 200;

  /// 中段幅度放大后的 alpha（`>>2` 保持本文件的整型风格，上限 256）。
  static int bump(int a) {
    final b = a + (a >> 2);
    return b > 256 ? 256 : b;
  }
}

/// 1px 过渡带的解析覆盖度。[distToEdge] > 0 表示像素中心在形状内部，
/// 值在 [band] 内线性衰减到 0。
int coverage(double distToEdge, {double band = 1.0}) {
  if (distToEdge <= 0) return 0;
  if (distToEdge >= band) return 255;
  return (distToEdge * 255 / band).round().clamp(0, 255);
}

/// Task 2.3（R7）：分格裁剪矩形命中判定。null = 不裁剪（现有全画布行为逐字节不变）；
/// 非 null 时落在 `[clip.x, clip.x+clip.width) × [clip.y, clip.y+clip.height)` 之外
/// 的像素一律拒绝，用于把叠加粒子约束在其所属本格内、不跨白带串味。
bool _outsideClip(PixelRect? clip, int x, int y) =>
    clip != null &&
    (x < clip.x ||
        x >= clip.x + clip.width ||
        y < clip.y ||
        y >= clip.y + clip.height);

/// 覆盖度合成。[cov] 已把「形状覆盖度 × 元不透明度」合成一维。
///
/// source-over 用精确的 `~/255`（不用 `>>8`，后者有 1/256 系统偏亮）；
/// [BlendOp.additive]/[BlendOp.screen] 走提亮，供光效类元（星光、火光、扫光）使用；
/// [BlendOp.darken]/[BlendOp.multiply] 走压暗，供 Task 2.4 的极性自适应「白纸压墨」
/// 一极使用。四个非常用分支都不碰 alpha，也不改动 over 的整数表达式。
void blendPixel(RgbaImage f, int x, int y, int r, int g, int b, int cov,
    {BlendOp op = BlendOp.over, PixelRect? clip}) {
  if (cov <= 0 || x < 0 || y < 0 || x >= f.width || y >= f.height) return;
  if (_outsideClip(clip, x, y)) return;
  if (cov > 255) cov = 255;
  final o = (y * f.width + x) * 4;
  final d = f.data;
  if (op == BlendOp.darken || op == BlendOp.multiply) {
    // Task 2.4 的两个压暗算子：先按 cov 预混出「该落的颜色」，再与底图取
    // min / 相乘。两者都只会让像素变暗或不变，且都不碰 alpha。
    if (op == BlendOp.darken) {
      final inv = 255 - cov;
      final sr = (r * cov + d[o] * inv) ~/ 255;
      final sg = (g * cov + d[o + 1] * inv) ~/ 255;
      final sb = (b * cov + d[o + 2] * inv) ~/ 255;
      d[o] = math.min(d[o], sr);
      d[o + 1] = math.min(d[o + 1], sg);
      d[o + 2] = math.min(d[o + 2], sb);
    } else {
      //  cov=255 时退化成 `d·src/255`；src=0 时与黑色 source-over（以及
      //  focusLines 的 `d·(255-a)/255`）逐字节同式。
      final fr = (r * cov + 255 * (255 - cov)) ~/ 255;
      final fg = (g * cov + 255 * (255 - cov)) ~/ 255;
      final fb = (b * cov + 255 * (255 - cov)) ~/ 255;
      d[o] = (d[o] * fr) ~/ 255;
      d[o + 1] = (d[o + 1] * fg) ~/ 255;
      d[o + 2] = (d[o + 2] * fb) ~/ 255;
    }
    return;
  }
  if (op != BlendOp.over) {
    final lr = (r * cov) ~/ 255, lg = (g * cov) ~/ 255, lb = (b * cov) ~/ 255;
    if (op == BlendOp.screen) {
      // 全整数：与截断加法在小亮度处几乎重合，只有近白区才拉开差距。
      d[o] = 255 - ((255 - d[o]) * (255 - lr)) ~/ 255;
      d[o + 1] = 255 - ((255 - d[o + 1]) * (255 - lg)) ~/ 255;
      d[o + 2] = 255 - ((255 - d[o + 2]) * (255 - lb)) ~/ 255;
    } else {
      d[o] = math.min(255, d[o] + lr);
      d[o + 1] = math.min(255, d[o + 1] + lg);
      d[o + 2] = math.min(255, d[o + 2] + lb);
    }
    return;
  }
  final inv = 255 - cov;
  d[o] = (r * cov + d[o] * inv) ~/ 255;
  d[o + 1] = (g * cov + d[o + 1] * inv) ~/ 255;
  d[o + 2] = (b * cov + d[o + 2] * inv) ~/ 255;
}

/// 胶囊（线段 + 半宽）距离场画线，代价 O(主轴像素 × 厚度)，每像素至多写一次。
///
/// [tailFade] 沿参数 t 把 alpha 从 1 线性拉到 `1-tailFade`（雨丝的尾端渐隐），
/// [tailPow] 再对这条包络取幂（星芒的 `fade²`）。
///
/// [polarity] 非 null 时启用 Task 2.4 的极性自适应：**像素行走与 alpha 完全
/// 不变**，只把「颜色 + 算子」换成该点底图亮度的函数（白纸压墨、暗区爆白），
/// 传入的 `r/g/b/op` 只在暗区一极沿用。null = 逐字节旧行为。
void drawSegmentAA(RgbaImage f, double x0, double y0, double x1, double y1,
    int r, int g, int b, int alpha, double thickness,
    {BlendOp op = BlendOp.over,
    double tailFade = 0,
    double tailPow = 1,
    bool aa = true,
    PixelRect? clip,
    PolarityBrush? polarity}) {
  if (alpha <= 0) return;
  final half = (thickness < 1 ? 1.0 : thickness) / 2.0;
  final band = half + 0.5;
  final vx = x1 - x0, vy = y1 - y0;
  final l2 = vx * vx + vy * vy;
  if (l2 < 1e-9) {
    drawDiscAA(f, x0, y0, half, r, g, b, alpha, op: op, exponent: 1.0, clip: clip);
    return;
  }
  // 主轴 = 跨度大的那一侧：斜率 ≤ 1，副轴只需扫过 [xc-band', xc+band']。
  final yMajor = vy.abs() >= vx.abs();
  final pad = band * 1.5 + 1.0; // 45° 时行内交线宽度约 1.41×band
  final lo = ((yMajor ? math.min(y0, y1) : math.min(x0, x1)) - pad).floor();
  final hi = ((yMajor ? math.max(y0, y1) : math.max(x0, x1)) + pad).ceil();
  for (var m = lo; m <= hi; m++) {
    final pm = m + 0.5;
    final t = yMajor ? (pm - y0) / vy : (pm - x0) / vx;
    final tc = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    final center = yMajor ? x0 + vx * tc : y0 + vy * tc;
    final s = (center - pad).floor(), e = (center + pad).ceil();
    for (var k = s; k <= e; k++) {
      final pk = k + 0.5;
      final px = yMajor ? pk : pm;
      final py = yMajor ? pm : pk;
      final dx = px - x0, dy = py - y0;
      final along = (dx * vx + dy * vy) / l2;
      final at = along < 0 ? 0.0 : (along > 1 ? 1.0 : along);
      final ex = px - (x0 + vx * at), ey = py - (y0 + vy * at);
      final dist = math.sqrt(ex * ex + ey * ey);
      final cov = aa ? coverage(band - dist) : (dist <= half ? 255 : 0);
      if (cov == 0) continue;
      var a = alpha * (cov / 255.0);
      if (tailFade > 0) {
        a *= math.pow(1.0 - tailFade * at, tailPow);
      }
      final cx = yMajor ? k : m, cy = yMajor ? m : k;
      if (polarity == null) {
        blendPixel(f, cx, cy, r, g, b, a.round(), op: op, clip: clip);
        continue;
      }
      // 极性只改「落什么颜色、用什么算子」，几何与 cov 链路一字未动。
      final lum = polarity.lumaAt(cx, cy);
      var alpha8 = a.round();
      if (PolarityBrush.midLuma(lum)) alpha8 = PolarityBrush.bump(alpha8);
      if (samplePolarity(lum) == Polarity.toInk) {
        blendPixel(f, cx, cy, polarity.inkR, polarity.inkG, polarity.inkB,
            alpha8,
            op: PolarityBrush.inkOp, clip: clip);
      } else {
        blendPixel(f, cx, cy, r, g, b, alpha8,
            op: PolarityBrush.lightOp, clip: clip);
      }
    }
  }
}

/// 柔边圆盘：边缘走 [coverage]，内部保留 `0.35 + 0.65·(1-d/r)` 的软衰减。
/// [exponent] > 1 让中心更实、外圈收得更快（火苗、光点核心）。
void drawDiscAA(RgbaImage f, double cx, double cy, double rad, int r, int g,
    int b, int alpha,
    {BlendOp op = BlendOp.over, double exponent = 1.0, PixelRect? clip}) {
  if (alpha <= 0 || rad <= 0) return;
  final y0 = (cy - rad - 1).floor(), y1 = (cy + rad + 1).ceil();
  final x0 = (cx - rad - 1).floor(), x1 = (cx + rad + 1).ceil();
  for (var y = y0; y <= y1; y++) {
    final dy = y + 0.5 - cy;
    for (var x = x0; x <= x1; x++) {
      final dx = x + 0.5 - cx;
      final dist = math.sqrt(dx * dx + dy * dy);
      final cov = coverage(rad - dist);
      if (cov == 0) continue;
      final fall = (1 - dist / rad).clamp(0.0, 1.0);
      final soft =
          0.35 + 0.65 * (exponent == 1.0 ? fall : math.pow(fall, exponent));
      blendPixel(f, x, y, r, g, b, (alpha * soft * (cov / 255.0)).round(),
          op: op, clip: clip);
    }
  }
}

/// 圆环：半径 [rad] 处宽 [thickness] 的 AA 圈，用于冲击波、光晕环。
///
/// 只走「环形带」而不是外接方块：逐行解出带内 x 区间，代价 ~O(周长×带宽)。
/// 外接方块扫描在 1080p 的大半径环上单帧要百万次 sqrt，会直接顶破性能红线。
/// [aa] 为 false 时边缘取硬阈值（legacy 档），过渡带消失、笔画收窄到 `half`。
void drawRingAA(RgbaImage f, double cx, double cy, double rad, double thickness,
    int r, int g, int b, int alpha,
    {BlendOp op = BlendOp.over, bool aa = true, PixelRect? clip}) {
  if (alpha <= 0 || rad <= 0) return;
  final half = (thickness < 1 ? 1.0 : thickness) / 2.0;
  final band = half + 0.5;
  final reach = rad + band;
  final rIn = rad - band; // 内空半径（<=0 表示环心已被带覆盖）
  final y0 = (cy - reach).floor(), y1 = (cy + reach).ceil();
  for (var y = y0; y <= y1; y++) {
    if (y < 0 || y >= f.height) continue;
    if (clip != null && (y < clip.y || y >= clip.y + clip.height)) continue;
    final dy = y + 0.5 - cy;
    final ady = dy.abs();
    if (ady > reach) continue;
    final xo = math.sqrt(reach * reach - ady * ady);
    final xi = (rIn > 0 && ady < rIn) ? math.sqrt(rIn * rIn - ady * ady) : 0.0;
    // 左右两段带；xi=0 时左段上界取 ceil-1，保证中轴列只写一次。
    final rLo = (cx + xi).ceil(), rHi = (cx + xo).floor();
    for (var k = rLo; k <= rHi; k++) {
      _ringPixel(f, k, y, cx, dy, rad, band, half, r, g, b, alpha, op, aa,
          clip: clip);
    }
    final lLo = (cx - xo).floor(), lHi = (cx - xi).ceil() - 1;
    for (var k = lLo; k <= lHi; k++) {
      _ringPixel(f, k, y, cx, dy, rad, band, half, r, g, b, alpha, op, aa,
          clip: clip);
    }
  }
}

void _ringPixel(
    RgbaImage f,
    int x,
    int y,
    double cx,
    double dy,
    double rad,
    double band,
    double half,
    int r,
    int g,
    int b,
    int alpha,
    BlendOp op,
    bool aa,
    {PixelRect? clip}) {
  if (x < 0 || x >= f.width) return;
  final dx = x + 0.5 - cx;
  final dist = math.sqrt(dx * dx + dy * dy);
  final off = (dist - rad).abs();
  final cov = aa ? coverage(band - off) : (off <= half ? 255 : 0);
  if (cov == 0) return;
  blendPixel(f, x, y, r, g, b, (alpha * (cov / 255.0)).round(),
      op: op, clip: clip);
}
