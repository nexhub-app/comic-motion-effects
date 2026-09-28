import 'dart:math' as math;
import 'dart:typed_data';

import 'apng_writer.dart' show PixelRect;
import 'image_model.dart';
import 'render/quality.dart';

/// Estimated per-pixel depth proxy in [0,1]: high = likely foreground.
class DepthMap {
  DepthMap(this.width, this.height)
      : data = List<double>.filled(width * height, 0);

  final int width;
  final int height;
  final List<double> data;

  double at(int x, int y) => data[y * width + x];
  void set(int x, int y, double v) => data[y * width + x] = v.clamp(0.0, 1.0);

  /// 双线性取样，边界钳位（像素中心约定，与 [DepthEstimator] 的降采样一致）。
  ///
  /// 深度场是在 0.5× 工作分辨率上算的，最近邻放大到原尺寸会留下 2× 的方块
  /// 台阶，层掩码因此呈阶梯状；双线性放大让成员度在相邻像素间连续变化。
  double sampleBilinear(double x, double y) {
    final fx = x.clamp(0.0, width - 1.0), fy = y.clamp(0.0, height - 1.0);
    final x0 = fx.floor(), y0 = fy.floor();
    final x1 = math.min(x0 + 1, width - 1), y1 = math.min(y0 + 1, height - 1);
    final tx = fx - x0, ty = fy - y0;
    final r0 = y0 * width, r1 = y1 * width;
    return (data[r0 + x0] * (1 - tx) + data[r0 + x1] * tx) * (1 - ty) +
        (data[r1 + x0] * (1 - tx) + data[r1 + x1] * tx) * ty;
  }
}

/// Layer index per pixel (0 = far background, N-1 = near foreground).
class LayerMap {
  LayerMap(this.width, this.height, this.layerCount)
      : index = List<int>.filled(width * height, 0);

  final int width;
  final int height;
  final int layerCount;
  final List<int> index;

  /// Fraction of pixels per layer, far-to-near.
  List<double> get coverage {
    final counts = List<int>.filled(layerCount, 0);
    for (final v in index) {
      counts[v]++;
    }
    return counts.map((c) => c / index.length).toList();
  }
}

/// A rendered layer: full-canvas RGBA where pixels not belonging to this layer
/// are transparent. The near layer (last) is filled opaque so edges never show
/// holes during parallax.
class LayerImage {
  LayerImage(this.image, this.depthRank, {this.clip});
  final RgbaImage image;
  final int depthRank; // 0 = far ... layerCount-1 = near

  /// 分格感知裁剪（W5，画布坐标）：层内容只允许写入该矩形（格边界裁剪，
  /// 根除跨格串色）；null = 全画布（既有路径零变化）。
  final PixelRect? clip;
}

/// 深度估算接口（W6 接口化）：抽象 `estimate(RgbaImage) → DepthMap`。
///
/// 内置启发式实现为默认（[HeuristicDepthEstimator]）；外部 ML（App 侧
/// tflite 深度模型等）实现本接口后经 `MotionPipeline(depthEstimator:)`
/// 注入——核心包保持零原生依赖，模型运行在嵌入方。适配指南见
/// `doc/external-depth.md`。
abstract class DepthEstimator {
  const DepthEstimator();

  /// 估算深度图：返回值各像素 ∈ [0,1]（0 = 远，1 = 近），尺寸任意
  /// （合成时按 [DepthMap.at]/sampleBilinear 映射回工作分辨率）。
  DepthMap estimate(RgbaImage img);
}

/// 默认启发式深度估算，针对漫画/线稿调优：
///  - salient dark ink strokes and high local contrast read as foreground
///  - faces/characters: skin-tone and high-saturation blobs read as foreground
///  - flat low-detail areas read as background
/// The result is smoothed with a separable box blur (approximating Gaussian).
///
/// 接口化前的具体实现原样搬入 —— 默认路径像素输出逐字节不变（测试锁定）。
class HeuristicDepthEstimator implements DepthEstimator {
  const HeuristicDepthEstimator({this.workScale = 0.5});

  final double workScale;

  @override
  DepthMap estimate(RgbaImage img) {
    final w = img.width, h = img.height;
    final dw = math.max(8, (w * workScale).round());
    final dh = math.max(8, (h * workScale).round());
    final small = _downscale(img, dw, dh);

    final raw = List<double>.filled(dw * dh, 0);
    // 1) ink density: darkness = foreground cue
    // 2) local contrast: edge density = foreground cue
    // 3) saturation/skin: character cue
    for (var y = 0; y < dh; y++) {
      for (var x = 0; x < dw; x++) {
        final i = y * dw + x;
        final lum = small.luminance(i);
        final ink = 1.0 - lum / 255.0;
        final contrast = _localContrast(small, x, y, dw, dh);
        final sat = _saturation(small, i);
        final skin = _skinness(small, i);
        raw[i] = 0.45 * ink + 0.35 * contrast + 0.12 * sat + 0.30 * skin;
      }
    }
    // Smooth to a coherent depth field.
    final smoothed = _boxBlur3(raw, dw, dh, passes: 2);
    final dm = DepthMap(dw, dh);
    final minV = smoothed.reduce(math.min);
    final maxV = smoothed.reduce(math.max);
    final range = (maxV - minV) <= 1e-6 ? 1.0 : (maxV - minV);
    for (var i = 0; i < dm.data.length; i++) {
      dm.data[i] = ((smoothed[i] - minV) / range).clamp(0.0, 1.0);
    }
    return dm;
  }

  double _localContrast(RgbaImage img, int x, int y, int w, int h) {
    final c = img.luminance(y * w + x);
    var sum = 0, n = 0;
    for (var dy = -2; dy <= 2; dy += 2) {
      for (var dx = -2; dx <= 2; dx += 2) {
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        sum += (img.luminance(ny * w + nx) - c).abs();
        n++;
      }
    }
    return n == 0 ? 0 : (sum / n / 64).clamp(0.0, 1.0);
  }

  double _saturation(RgbaImage img, int i) {
    final r = img.red(i), g = img.green(i), b = img.blue(i);
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    return mx == 0 ? 0 : (mx - mn) / mx;
  }

  double _skinness(RgbaImage img, int i) {
    final r = img.red(i).toDouble(),
        g = img.green(i).toDouble(),
        b = img.blue(i).toDouble();
    // crude skin-tone detection, adequate as a depth proxy for character art
    if (r < 95 || g < 40 || b < 20 || r <= g || r <= b) return 0;
    final d = (r - g).abs();
    if (d < 15 || d > 120 || r > 250 || g > 220) return 0;
    return ((r - g) / 120).clamp(0.0, 1.0);
  }

  RgbaImage _downscale(RgbaImage img, int dw, int dh) {
    final out = RgbaImage(width: dw, height: dh);
    final sx = img.width / dw, sy = img.height / dh;
    final tmp = List<int>.filled(4, 0);
    for (var y = 0; y < dh; y++) {
      for (var x = 0; x < dw; x++) {
        img.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, tmp);
        out.setPixel(x, y, tmp[0], tmp[1], tmp[2], tmp[3]);
      }
    }
    return out;
  }

  List<double> _boxBlur3(List<double> src, int w, int h, {int passes = 1}) {
    var cur = List<double>.from(src);
    for (var p = 0; p < passes; p++) {
      final tmp = List<double>.filled(cur.length, 0);
      // horizontal
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final l = cur[y * w + math.max(0, x - 1)];
          final c = cur[y * w + x];
          final r = cur[y * w + math.min(w - 1, x + 1)];
          tmp[y * w + x] = (l + c + r) / 3;
        }
      }
      // vertical
      final out = List<double>.filled(cur.length, 0);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final u = tmp[math.max(0, y - 1) * w + x];
          final c = tmp[y * w + x];
          final d = tmp[math.min(h - 1, y + 1) * w + x];
          out[y * w + x] = (u + c + d) / 3;
        }
      }
      cur = out;
    }
    return cur;
  }
}

/// Splits the depth map into N ordered layers with soft alpha edges
/// (feathering) so parallax does not show hard cut lines.
///
/// [RenderTier.legacy] 走 v1.2 的原样通路：深度最近邻放大、不羽化、不外扩，
/// 保证层掩码逐字节一致（回滚承诺）。standard+ 三件事全开：双线性深度放大、
/// `[1 2 1]/4` 可分离羽化、层边缘色外扩。
class LayerSplitter {
  LayerSplitter({
    this.layerCount = 3,
    this.featherPx = 6,
    this.tier = RenderTier.legacy,
    this.edgeStretchPx = 0,
  });

  final int layerCount;
  final int featherPx;
  final RenderTier tier;

  /// standard+ 档把层的不透明色向外推这么多像素（0 = 关闭）。
  final int edgeStretchPx;

  List<LayerImage> split(RgbaImage img, DepthMap depth) {
    // Thresholds chosen so background dominates flat areas and near layer
    // covers salient subjects; guarantee every layer is non-empty by falling
    // back to quantiles when a band would be empty.
    final sorted = List<double>.from(depth.data)..sort();
    double q(double p) => sorted[(p * (sorted.length - 1)).round()];
    final t1 = math.max(q(0.35), 0.30); // far | mid boundary
    final t2 = math.max(q(0.72), t1 + 0.05); // mid | near boundary

    final smooth = tier.atLeastStandard;
    final featherPasses =
        smooth && featherPx > 0 ? (featherPx / 3).ceil().clamp(1, 4) : 0;
    final stretch = smooth ? edgeStretchPx.clamp(0, 16) : 0;
    final layers = <LayerImage>[];
    for (var li = 0; li < layerCount; li++) {
      final layer = _extract(img, depth, li, t1, t2, smooth: smooth);
      if (featherPasses > 0) _featherAlpha(layer, featherPasses);
      if (stretch > 0) _stretchEdges(layer, stretch);
      layers.add(LayerImage(layer, li));
    }
    return layers;
  }

  RgbaImage _extract(
      RgbaImage img, DepthMap depth, int li, double t1, double t2,
      {required bool smooth}) {
    final layer = RgbaImage(width: img.width, height: img.height);
    final w = img.width, h = img.height;
    final sx = depth.width / w, sy = depth.height / h;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final double d;
        if (smooth) {
          d = depth.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5);
        } else {
          d = depth.at((x * sx).floor().clamp(0, depth.width - 1),
              (y * sy).floor().clamp(0, depth.height - 1));
        }
        final a = _membership(d, li, t1, t2).clamp(0.0, 1.0);
        if (a <= 0.01) continue;
        final i = (y * w + x) * 4;
        final o = (y * layer.width + x) * 4;
        layer.data[o] = img.data[i];
        layer.data[o + 1] = img.data[i + 1];
        layer.data[o + 2] = img.data[i + 2];
        layer.data[o + 3] = (a * 255).round();
      }
    }
    // NOTE: no opaque fill here — the compositor draws the full base image
    // beneath all layers, so layer gaps reveal the base, never black holes.
    return layer;
  }

  /// 真羽化：对 alpha 通道做 [passes] 次可分离 `[1 2 1]/4` 卷积，边界复制。
  ///
  /// 只碰 alpha：RGB 保持源色，合成时层与层之间的过渡带才不会混进灰边。
  static void _featherAlpha(RgbaImage layer, int passes) {
    final w = layer.width, h = layer.height, d = layer.data;
    final tmp = Uint8List(w * h);
    for (var p = 0; p < passes; p++) {
      for (var y = 0; y < h; y++) {
        final row = y * w * 4;
        for (var x = 0; x < w; x++) {
          final l = d[row + (x > 0 ? x - 1 : 0) * 4 + 3];
          final c = d[row + x * 4 + 3];
          final r = d[row + (x < w - 1 ? x + 1 : w - 1) * 4 + 3];
          tmp[y * w + x] = (l + 2 * c + r + 2) >> 2;
        }
      }
      for (var y = 0; y < h; y++) {
        final u = y > 0 ? y - 1 : 0;
        final dn = y < h - 1 ? y + 1 : h - 1;
        final row = y * w * 4;
        for (var x = 0; x < w; x++) {
          d[row + x * 4 + 3] =
              (tmp[u * w + x] + 2 * tmp[y * w + x] + tmp[dn * w + x] + 2) >> 2;
        }
      }
    }
  }

  /// 层边缘色外扩：每轮把「上一轮就不透明」的邻居颜色推进一格，alpha 逐轮衰减。
  ///
  /// 视差位移时层会移出画布，露出的两像素宽透明带会让底图重影（俗称露底双边）；
  /// 把边缘色提前推出去，位移后边缘处仍有正确颜色可贴。整轮同步推进（用上一轮的
  /// 存活掩码判定邻居），因此填充深度严格等于 [rounds]，且与扫描顺序无关。
  static void _stretchEdges(RgbaImage layer, int rounds) {
    final w = layer.width, h = layer.height, d = layer.data;
    final n = w * h;
    var live = Uint8List(n);
    for (var p = 0; p < n; p++) {
      if (d[p * 4 + 3] > 0) live[p] = 1;
    }
    for (var r = 0; r < rounds; r++) {
      final src = live;
      final next = Uint8List.fromList(src);
      var filled = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = y * w + x;
          if (src[p] == 1) continue;
          var best = -1, bestA = 0;
          // 固定次序（左上右下）取 alpha 最大的上一轮存活邻居，保证与扫描顺序无关。
          for (var k = 0; k < 4; k++) {
            final qx = k == 0 ? x - 1 : (k == 2 ? x + 1 : x);
            final qy = k == 1 ? y - 1 : (k == 3 ? y + 1 : y);
            if (qx < 0 || qy < 0 || qx >= w || qy >= h) continue;
            final q = qy * w + qx;
            if (src[q] == 0) continue;
            final a = d[q * 4 + 3];
            if (a > bestA) {
              bestA = a;
              best = q;
            }
          }
          if (best < 0) continue;
          final a = bestA - 24;
          if (a <= 0) continue;
          final o = p * 4, bo = best * 4;
          d[o] = d[bo];
          d[o + 1] = d[bo + 1];
          d[o + 2] = d[bo + 2];
          d[o + 3] = a;
          next[p] = 1;
          filled++;
        }
      }
      if (filled == 0) return;
      live = next;
    }
  }

  double _membership(double d, int li, double t1, double t2) {
    switch (li) {
      case 0: // far: below t1 with soft top edge
        return ((t1 - d) / 0.06 + 0.5).clamp(0.0, 1.0);
      case 1: // mid: between t1 and t2, soft both edges
        final lo = (d - t1) / 0.06 + 0.5;
        final hi = (t2 - d) / 0.06 + 0.5;
        return math.min(lo, hi).clamp(0.0, 1.0);
      default: // near: above t2 with soft bottom edge
        return ((d - t2) / 0.06 + 0.5).clamp(0.0, 1.0);
    }
  }
}
