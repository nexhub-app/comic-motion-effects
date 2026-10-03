/// 分级重采样（Q4）。
///
/// 两条通路：
///  * [boxDownscale] —— 一次性把工作分辨率压到 `maxDimension`，用可分离面积
///    平均替代 v1.2 的双线性，细线稿不再因欠采样产生锯齿与摩尔纹。
///  * [drawLayer] —— 每帧的层贴图。legacy 档逐字节沿用 v1.2 的逆映射双线性；
///    standard+ 档改走 Catmull-Rom 4×4：视差/呼吸带来的**分数位移**才是每帧
///    发虚的主因（半像素位移=两纹素各 50% 混合），Catmull-Rom 的负瓣能把
///    这条曲线拉回接近原始锐度，抽点成本靠可分离滤波压到约 8 个。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../apng_writer.dart' show PixelRect;
import '../image_model.dart';
import 'quality.dart';

// ---------- 面积平均降采样 ----------

/// 等比降到最长边 <= [maxDim]；已在范围内时原样返回。
RgbaImage boxDownscale(RgbaImage src, int maxDim) {
  final maxSide = src.width > src.height ? src.width : src.height;
  if (maxSide <= maxDim) return src;
  final ratio = maxDim / maxSide;
  final nw = (src.width * ratio).round().clamp(1, maxDim);
  final nh = (src.height * ratio).round().clamp(1, maxDim);
  final rowPass = _areaAxisX(src.data, src.width, src.height, nw);
  return RgbaImage.fromBytes(
      width: nw, height: nh, data: _areaAxisY(rowPass, nw, src.height, nh));
}

/// 横向：w -> nw，逐行独立做重叠加权平均。
Uint8List _areaAxisX(Uint8List src, int w, int h, int nw) {
  final out = Uint8List(nw * h * 4);
  final scale = w / nw;
  final acc = List<double>.filled(4, 0);
  for (var y = 0; y < h; y++) {
    final rowIn = y * w * 4;
    final rowOut = y * nw * 4;
    for (var x = 0; x < nw; x++) {
      final a = x * scale;
      final i0 = a.floor().clamp(0, w - 1);
      final i1 = ((a + scale).ceil() - 1).clamp(0, w - 1);
      _spanSums(src, rowIn + i0 * 4, i0, i1, a, a + scale, 4, acc);
      final o = rowOut + x * 4;
      for (var c = 0; c < 4; c++) {
        out[o + c] = (acc[c] / scale).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// 纵向：h -> nh，纹素间字节跨度为一整行。
Uint8List _areaAxisY(Uint8List src, int w, int h, int nh) {
  final out = Uint8List(w * nh * 4);
  final scale = h / nh;
  final stride = w * 4;
  final acc = List<double>.filled(4, 0);
  for (var y = 0; y < nh; y++) {
    final a = y * scale;
    final j0 = a.floor().clamp(0, h - 1);
    final j1 = ((a + scale).ceil() - 1).clamp(0, h - 1);
    for (var x = 0; x < w; x++) {
      _spanSums(src, x * 4 + j0 * stride, j0, j1, a, a + scale, stride, acc);
      final o = (y * w + x) * 4;
      for (var c = 0; c < 4; c++) {
        out[o + c] = (acc[c] / scale).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// 一维区间 [a,b) 覆盖的整型纹素 [i0,i1] 的重叠加权求和（4 通道），写入 [acc]。
/// [step] 为相邻纹素的字节跨度（横向 4，纵向一整行）。
void _spanSums(Uint8List src, int base, int i0, int i1, double a, double b,
    int step, List<double> acc) {
  for (var c = 0; c < 4; c++) {
    acc[c] = 0;
  }
  for (var i = i0; i <= i1; i++) {
    final lo = i > a ? i.toDouble() : a;
    final hi = (i + 1) < b ? (i + 1).toDouble() : b;
    final wt = hi - lo;
    if (wt <= 0) continue;
    final o = base + (i - i0) * step;
    for (var c = 0; c < 4; c++) {
      acc[c] += src[o + c] * wt;
    }
  }
}

// ---------- 每帧层贴图 ----------

/// 把 [srcData]（sw×sh 的 RGBA 栅格）按 [scale] 与位移 (dx,dy) 逆映射贴进 [dst]。
///
/// [tier] 为 legacy 时沿用 v1.2 的重采样算法（双线性/最近邻，取整逐字节不变）；
/// standard+ 走 Catmull-Rom。
/// [clip]（画布坐标）：目标像素钳制矩形——只有矩形内的画布像素会被
/// 写入（分格感知层的格边界裁剪）；null = 全画布，循环范围与旧实现相同
/// （既有路径逐字节零变化）。
/// 注意：scale 远小于 0.5 时 Catmull-Rom 会欠采样——本引擎的 scale 恒在
/// `1±呼吸幅度` 与 `cover(>=1)` 区间，真正的降采样由 [boxDownscale] 一次性完成。
void drawLayer(RgbaImage dst, Uint8List srcData, int sw, int sh, double dx,
    double dy, double scale, double anchorY,
    {required RenderTier tier, PixelRect? clip}) {
  if (scale <= 0) return;
  if (tier.atLeastStandard) {
    _drawCatmullRom(dst, srcData, sw, sh, dx, dy, scale, anchorY, clip: clip);
    return;
  }
  _drawBilinear(dst, srcData, sw, sh, dx, dy, scale, anchorY, clip: clip);
}

/// v1.2 原样通路（逆映射双线性 + 越界抽点按权重 0 跳过）。
void _drawBilinear(RgbaImage dst, Uint8List srcData, int sw, int sh, double dx,
    double dy, double scale, double anchorY,
    {PixelRect? clip}) {
  final w = dst.width, h = dst.height;
  final cx = sw / 2.0, cy = sh * anchorY;
  final inv = 1.0 / scale;
  final dstData = dst.data;
  final sxStep = inv;
  // 画布坐标钳制：clip 非空时只遍历矩形内的目标像素。
  final yStart = clip?.y ?? 0;
  final yEnd = clip == null ? h : math.min(h, clip.y + clip.height);
  final xStart = clip?.x ?? 0;
  final xEnd = clip == null ? w : math.min(w, clip.x + clip.width);
  for (var y = yStart; y < yEnd; y++) {
    final sy = (y + 0.5 - (h * anchorY)) * inv + cy + dy - 0.5;
    final sy0 = sy.floor();
    final ty = sy - sy0;
    final y0Ok = sy0 >= 0 && sy0 < sh;
    final y1 = sy0 + 1;
    final y1Ok = y1 >= 0 && y1 < sh;
    if (!y0Ok && !y1Ok) continue;
    var sx = (xStart + 0.5 - (w * 0.5)) * inv + cx + dx - 0.5;
    for (var x = xStart; x < xEnd; x++, sx += sxStep) {
      final sx0 = sx.floor();
      final tx = sx - sx0;
      final x1 = sx0 + 1;
      final x0Ok = sx0 >= 0 && sx0 < sw;
      final x1Ok = x1 >= 0 && x1 < sw;
      if (!x0Ok && !x1Ok) continue;
      final dOff = (y * w + x) * 4;
      // Gather 4 taps (out-of-range taps are skipped via weight 0).
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      if (x0Ok && y0Ok) {
        final o = (sy0 * sw + sx0) * 4;
        final wgt = (1 - tx) * (1 - ty);
        r += srcData[o] * wgt;
        g += srcData[o + 1] * wgt;
        b += srcData[o + 2] * wgt;
        a += srcData[o + 3] * wgt;
      }
      if (x1Ok && y0Ok) {
        final o = (sy0 * sw + x1) * 4;
        final wgt = tx * (1 - ty);
        r += srcData[o] * wgt;
        g += srcData[o + 1] * wgt;
        b += srcData[o + 2] * wgt;
        a += srcData[o + 3] * wgt;
      }
      if (x0Ok && y1Ok) {
        final o = (y1 * sw + sx0) * 4;
        final wgt = (1 - tx) * ty;
        r += srcData[o] * wgt;
        g += srcData[o + 1] * wgt;
        b += srcData[o + 2] * wgt;
        a += srcData[o + 3] * wgt;
      }
      if (x1Ok && y1Ok) {
        final o = (y1 * sw + x1) * 4;
        final wgt = tx * ty;
        r += srcData[o] * wgt;
        g += srcData[o + 1] * wgt;
        b += srcData[o + 2] * wgt;
        a += srcData[o + 3] * wgt;
      }
      _composite(dst, dstData, dOff, r, g, b, a);
    }
  }
}

/// Catmull-Rom 4×4：分数位移下保持线稿锐度（standard+ 专用）。
///
/// 张量积可分离，所以拆成「横向 4 抽点 + 纵向 4 抽点」，比二维的 16 抽点省一半；
/// 关键在于列向映射 `sx(x)` 与 y 无关，于是同一源行的横向结果能被相邻输出行反复
/// 复用（本引擎 scale≈1，每个源行实际只滤一次）。边界语义与逐点版一致：
/// 越界抽点权重记 0，越界源行整条跳过。
void _drawCatmullRom(RgbaImage dst, Uint8List srcData, int sw, int sh,
    double dx, double dy, double scale, double anchorY,
    {PixelRect? clip}) {
  final w = dst.width, h = dst.height;
  final inv = 1.0 / scale;
  final dstData = dst.data;
  final rowBytes = sw * 4;
  // 画布坐标钳制。
  final yStart = clip?.y ?? 0;
  final yEnd = clip == null ? h : math.min(h, clip.y + clip.height);
  final xStart = clip?.x ?? 0;
  final xEnd = clip == null ? w : math.min(w, clip.x + clip.width);

  // sx 随 x 单调递增 => 命中源区的列是一段连续区间，区间外整列跳过。
  final colOff = Int32List(w * 4);
  final colW = Float64List(w * 4);
  final wt = Float64List(4);
  var xFirst = -1, xLast = -1;
  for (var x = xStart; x < xEnd; x++) {
    final sx = (x + 0.5 - (w * 0.5)) * inv + sw / 2.0 + dx - 0.5;
    final sx0 = sx.floor();
    _fillCrWeights(sx - sx0, wt);
    final ox0 = sx0 - 1;
    if (ox0 >= sw || ox0 + 3 < 0) continue;
    final b = x * 4;
    for (var i = 0; i < 4; i++) {
      final xx = ox0 + i;
      final inside = xx >= 0 && xx < sw;
      colOff[b + i] = inside ? xx * 4 : 0;
      colW[b + i] = inside ? wt[i] : 0.0;
    }
    if (xFirst < 0) xFirst = x;
    xLast = x;
  }
  if (xFirst < 0) return;

  // 槽数只要盖住滑动窗口即可；被挤出的行会重滤一遍，结果不变，只是少一次复用。
  const slots = 8;
  final ring = Float64List(slots * w * 4);
  final ringRow = Int32List(slots)..fillRange(0, slots, -1);
  final acc = Float64List(w * 4);
  final from = xFirst * 4, to = (xLast + 1) * 4;

  for (var y = yStart; y < yEnd; y++) {
    final sy = (y + 0.5 - (h * anchorY)) * inv + sh * anchorY + dy - 0.5;
    final sy0 = sy.floor();
    _fillCrWeights(sy - sy0, wt);
    final oy0 = sy0 - 1;
    if (oy0 >= sh || oy0 + 3 < 0) continue;
    acc.fillRange(from, to, 0.0);
    for (var j = 0; j < 4; j++) {
      final wj = wt[j];
      final row = oy0 + j;
      if (wj == 0 || row < 0 || row >= sh) continue;
      final slot = row % slots;
      if (ringRow[slot] != row) {
        _filterRow(srcData, row * rowBytes, colOff, colW, xFirst, xLast, ring,
            slot * w * 4);
        ringRow[slot] = row;
      }
      final hb = slot * w * 4;
      for (var o = from; o < to; o++) {
        acc[o] += ring[hb + o] * wj;
      }
    }
    for (var x = xFirst; x <= xLast; x++) {
      final b = x * 4;
      _composite(dst, dstData, (y * w + x) * 4, acc[b], acc[b + 1], acc[b + 2],
          acc[b + 3]);
    }
  }
}

/// 单个源行的横向 4 抽点，结果写进 [dst] 的 [dbase] 起的 dst 列位置。
void _filterRow(Uint8List src, int rowBase, Int32List colOff, Float64List colW,
    int xFirst, int xLast, Float64List dst, int dbase) {
  for (var x = xFirst; x <= xLast; x++) {
    final b = x * 4;
    final o0 = rowBase + colOff[b];
    final o1 = rowBase + colOff[b + 1];
    final o2 = rowBase + colOff[b + 2];
    final o3 = rowBase + colOff[b + 3];
    final w0 = colW[b];
    final w1 = colW[b + 1];
    final w2 = colW[b + 2];
    final w3 = colW[b + 3];
    dst[dbase + b] = src[o0] * w0 + src[o1] * w1 + src[o2] * w2 + src[o3] * w3;
    dst[dbase + b + 1] = src[o0 + 1] * w0 +
        src[o1 + 1] * w1 +
        src[o2 + 1] * w2 +
        src[o3 + 1] * w3;
    dst[dbase + b + 2] = src[o0 + 2] * w0 +
        src[o1 + 2] * w1 +
        src[o2 + 2] * w2 +
        src[o3 + 2] * w3;
    dst[dbase + b + 3] = src[o0 + 3] * w0 +
        src[o1 + 3] * w1 +
        src[o2 + 3] * w2 +
        src[o3 + 3] * w3;
  }
}

/// Catmull-Rom 在 t∈[0,1) 处对 [-1,0,1,2] 四个抽点的权重。
void _fillCrWeights(double t, List<double> out) {
  final t2 = t * t, t3 = t2 * t;
  out[0] = (-0.5 * t3 + t2 - 0.5 * t);
  out[1] = (1.5 * t3 - 2.5 * t2 + 1.0);
  out[2] = (-1.5 * t3 + 2.0 * t2 + 0.5 * t);
  out[3] = (0.5 * t3 - 0.5 * t2);
}

/// 采样结果按 alpha 合成到目标像素（两条通路共用，算式与 v1.2 逐字一致）。
void _composite(RgbaImage dst, Uint8List dstData, int dOff, double r, double g,
    double b, double a) {
  final sa = a / 255.0;
  if (sa <= 0.004) return;
  if (sa >= 0.996) {
    dstData[dOff] = r.round().clamp(0, 255);
    dstData[dOff + 1] = g.round().clamp(0, 255);
    dstData[dOff + 2] = b.round().clamp(0, 255);
    dstData[dOff + 3] = 255;
  } else {
    final da = dstData[dOff + 3] / 255.0;
    final outA = sa + da * (1 - sa);
    dstData[dOff] =
        ((r * sa + dstData[dOff] * da * (1 - sa)) / outA).round().clamp(0, 255);
    dstData[dOff + 1] = ((g * sa + dstData[dOff + 1] * da * (1 - sa)) / outA)
        .round()
        .clamp(0, 255);
    dstData[dOff + 2] = ((b * sa + dstData[dOff + 2] * da * (1 - sa)) / outA)
        .round()
        .clamp(0, 255);
    dstData[dOff + 3] = (outA * 255).round().clamp(0, 255);
  }
}
