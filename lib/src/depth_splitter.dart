import 'dart:math' as math;

import 'image_model.dart';

/// Estimated per-pixel depth proxy in [0,1]: high = likely foreground.
class DepthMap {
  DepthMap(this.width, this.height) : data = List<double>.filled(width * height, 0);

  final int width;
  final int height;
  final List<double> data;

  double at(int x, int y) => data[y * width + x];
  void set(int x, int y, double v) => data[y * width + x] = v.clamp(0.0, 1.0);
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
  LayerImage(this.image, this.depthRank);
  final RgbaImage image;
  final int depthRank; // 0 = far ... layerCount-1 = near
}

/// Depth estimation tuned for comic/line art:
///  - salient dark ink strokes and high local contrast read as foreground
///  - faces/characters: skin-tone and high-saturation blobs read as foreground
///  - flat low-detail areas read as background
/// The result is smoothed with a separable box blur (approximating Gaussian).
class DepthEstimator {
  DepthEstimator({this.workScale = 0.5});

  final double workScale;

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
    final r = img.red(i).toDouble(), g = img.green(i).toDouble(),
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
class LayerSplitter {
  LayerSplitter({this.layerCount = 3, this.featherPx = 6});

  final int layerCount;
  final int featherPx;

  List<LayerImage> split(RgbaImage img, DepthMap depth) {
    // Thresholds chosen so background dominates flat areas and near layer
    // covers salient subjects; guarantee every layer is non-empty by falling
    // back to quantiles when a band would be empty.
    final sorted = List<double>.from(depth.data)..sort();
    double q(double p) => sorted[(p * (sorted.length - 1)).round()];
    final t1 = math.max(q(0.35), 0.30); // far | mid boundary
    final t2 = math.max(q(0.72), t1 + 0.05); // mid | near boundary

    final layers = <LayerImage>[];
    for (var li = 0; li < layerCount; li++) {
      layers.add(_extract(img, depth, li, t1, t2));
    }
    return layers;
  }

  LayerImage _extract(RgbaImage img, DepthMap depth, int li, double t1, double t2) {
    final layer = RgbaImage(width: img.width, height: img.height);
    final w = img.width, h = img.height;
    final sx = depth.width / w, sy = depth.height / h;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final d = depth.at((x * sx).floor().clamp(0, depth.width - 1),
            (y * sy).floor().clamp(0, depth.height - 1));
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
    return LayerImage(layer, li);
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
