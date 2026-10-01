import 'dart:math' as math;
import 'dart:typed_data';

import 'apng_writer.dart' show PixelRect;
import 'image_model.dart';

/// A weighted point of interest in normalized [0,1] page coordinates.
class Anchor {
  const Anchor(this.nx, this.ny, this.weight);
  final double nx, ny, weight;
}

/// Content-analysis result for a page: an absolute activity field, the
/// subject bounding box, focal anchors, and detected panels.
class AnchorMap {
  AnchorMap(this.width, this.height, this.activity, this.subjectBox,
      this.anchors, this.panels);
  final int width, height;
  final Float64List activity;
  final PixelRect subjectBox;
  final List<Anchor> anchors;
  final List<PixelRect> panels;

  /// Bilinear-free lookup of the activity field at normalized coords.
  ///
  /// Defensive: an empty grid (width or height 0) returns 0.0 rather than
  /// throwing on the clamp bounds.
  double activityAt(double nx, double ny) {
    if (width == 0 || height == 0) return 0.0;
    final x = (nx * (width - 1)).round().clamp(0, width - 1);
    final y = (ny * (height - 1)).round().clamp(0, height - 1);
    return activity[y * width + x];
  }
}

/// Computes a saliency/activity field from page pixels, reusing the
/// `HeuristicDepthEstimator` signal mix (ink, local contrast, saturation,
/// skin — `depth_splitter.dart:113, 128-158`) plus its coherent-field
/// smoothing (`_boxBlur3`, 2 passes). Activity stays in ABSOLUTE units: a
/// dense dark blob center lands ~0.40-0.45 and a pure-white blank margin
/// lands ~0.01. There is deliberately NO min/max ramp — later tasks rely on
/// a low-absolute-value / blank page naturally falling back to a uniform
/// particle distribution, which a global rescale would destroy (it would
/// amplify blank-page noise to the full 0..1 range).
class SaliencyAnalyzer {
  const SaliencyAnalyzer({this.workScale = 0.5});
  final double workScale;

  /// Returns a row-major `outW x outH` activity field with values in [0,1].
  Float64List activity(RgbaImage img, int outW, int outH) {
    final w = img.width, h = img.height;
    final sx = w / outW, sy = h / outH;
    final raw = Float64List(outW * outH);
    int lumAt(int x, int y) {
      final tmp = List<int>.filled(4, 0);
      img.sampleBilinear(x * sx, y * sy, tmp);
      return (0.299 * tmp[0] + 0.587 * tmp[1] + 0.114 * tmp[2]).round();
    }
    for (var y = 0; y < outH; y++) {
      for (var x = 0; x < outW; x++) {
        final lum = lumAt(x, y);
        final ink = 1.0 - lum / 255.0;
        final contrast = _localContrast(lumAt, x, y, outW, outH);
        final tmp = List<int>.filled(4, 0);
        img.sampleBilinear(x * sx, y * sy, tmp);
        final sat = _saturation(tmp[0], tmp[1], tmp[2]);
        final skin = _skinness(tmp[0], tmp[1], tmp[2]);
        raw[y * outW + x] =
            (0.45 * ink + 0.35 * contrast + 0.12 * sat + 0.30 * skin)
                .clamp(0.0, 1.0);
      }
    }
    // Smooth to a coherent activity field. A box blur is mean-preserving, so
    // it does NOT change the absolute scale: activity stays in absolute units
    // (a blob center ~0.40-0.45, a blank margin ~0.01). Deliberately NO
    // min/max rescale — the raw absolute magnitudes are what placement
    // weighting and the blank-page uniform fallback need.
    final smoothed = _boxBlur3(raw, outW, outH, passes: 2);
    final out = Float64List(outW * outH);
    for (var i = 0; i < out.length; i++) {
      out[i] = smoothed[i].clamp(0.0, 1.0);
    }
    return out;
  }

  /// Bounding rect of the largest 4-connected component of pixels whose
  /// activity clears `mean + 0.5 * stddev` of the whole [activity] grid.
  ///
  /// Coordinates are ANALYSIS-GRID pixels (not normalized): [w]/[h] are the
  /// grid dimensions the [activity] field was produced at. Scan order is
  /// deterministic (top-left to bottom-right, row-major); the largest
  /// component wins, first found wins on size ties. If no pixel clears the
  /// threshold the full-canvas rect `PixelRect(0, 0, w, h)` is returned.
  PixelRect subjectBox(Float64List activity, int w, int h) {
    if (w <= 0 || h <= 0 || activity.length < w * h) {
      return PixelRect(0, 0, math.max(0, w), math.max(0, h));
    }
    final n = w * h;
    var sum = 0.0, sumSq = 0.0;
    for (var i = 0; i < n; i++) {
      final v = activity[i];
      sum += v;
      sumSq += v * v;
    }
    final mean = sum / n;
    final std = math.sqrt(math.max(0.0, sumSq / n - mean * mean));
    final thr = mean + 0.5 * std;

    final visited = Uint8List(n);
    final stack = Int32List(n); // iterative flood fill, no recursion
    var bestX = 0, bestY = 0, bestX1 = -1, bestY1 = -1, bestSize = 0;
    for (var seed = 0; seed < n; seed++) {
      if (visited[seed] != 0 || activity[seed] < thr) continue;
      var top = 0;
      stack[top++] = seed;
      visited[seed] = 1;
      var minX = w, minY = h, maxX = -1, maxY = -1, size = 0;
      while (top > 0) {
        final p = stack[--top];
        final px = p % w, py = p ~/ w;
        if (px < minX) minX = px;
        if (px > maxX) maxX = px;
        if (py < minY) minY = py;
        if (py > maxY) maxY = py;
        size++;
        for (var d = 0; d < 4; d++) {
          final qx = px + (d == 0 ? -1 : d == 1 ? 1 : 0);
          final qy = py + (d == 2 ? -1 : d == 3 ? 1 : 0);
          if (qx < 0 || qy < 0 || qx >= w || qy >= h) continue;
          final q = qy * w + qx;
          if (visited[q] != 0 || activity[q] < thr) continue;
          visited[q] = 1;
          stack[top++] = q;
        }
      }
      if (size > bestSize) {
        bestSize = size;
        bestX = minX;
        bestY = minY;
        bestX1 = maxX;
        bestY1 = maxY;
      }
    }
    if (bestSize == 0) return PixelRect(0, 0, w, h);
    return PixelRect(bestX, bestY, bestX1 - bestX + 1, bestY1 - bestY + 1);
  }

  /// Non-maximum-suppressed focal anchors inside [subjectBox].
  ///
  /// Candidates are grid pixels inside [subjectBox] (given in the same
  /// analysis-grid pixel coords as [activity]) whose value clears
  /// `mean + stddev` of the whole grid. Selection is greedy farthest-point
  /// NMS by descending activity with a minimum separation of
  /// `0.12 * min(subjectBox.width, subjectBox.height)` grid pixels, up to
  /// [maxN] anchors. `weight` is activity normalized over the candidate set
  /// to [0, 1]. Returned anchors are sorted by weight desc; an empty
  /// candidate set yields `[]`.
  ///
  /// [Anchor.nx]/[ny] are CANVAS-NORMALIZED [0,1]: analysis-grid coords
  /// divided by the grid size [w]/[h].
  List<Anchor> anchors(Float64List activity, int w, int h, PixelRect subjectBox,
      {int maxN = 4}) {
    if (w <= 0 || h <= 0 || maxN <= 0 || activity.length < w * h) return [];
    final n = w * h;
    var sum = 0.0, sumSq = 0.0;
    for (var i = 0; i < n; i++) {
      final v = activity[i];
      sum += v;
      sumSq += v * v;
    }
    final mean = sum / n;
    final std = math.sqrt(math.max(0.0, sumSq / n - mean * mean));
    final thr = mean + std;

    final bx0 = subjectBox.x.clamp(0, w);
    final by0 = subjectBox.y.clamp(0, h);
    final bx1 = (subjectBox.x + subjectBox.width).clamp(0, w);
    final by1 = (subjectBox.y + subjectBox.height).clamp(0, h);

    final candidates = <int>[];
    for (var y = by0; y < by1; y++) {
      for (var x = bx0; x < bx1; x++) {
        final i = y * w + x;
        if (activity[i] >= thr) candidates.add(i);
      }
    }
    if (candidates.isEmpty) return [];

    var minC = double.infinity, maxC = -double.infinity;
    for (final i in candidates) {
      final v = activity[i];
      if (v < minC) minC = v;
      if (v > maxC) maxC = v;
    }
    final range = maxC - minC;

    // Deterministic order: activity desc, scan order (index asc) on ties.
    candidates.sort((a, b) {
      final c = activity[b].compareTo(activity[a]);
      return c != 0 ? c : a.compareTo(b);
    });

    final sep = 0.12 * math.min(subjectBox.width, subjectBox.height);
    final pickedX = <int>[], pickedY = <int>[];
    final out = <Anchor>[];
    for (final i in candidates) {
      if (out.length >= maxN) break;
      final x = i % w, y = i ~/ w;
      var tooClose = false;
      for (var k = 0; k < pickedX.length; k++) {
        final dx = (x - pickedX[k]).toDouble();
        final dy = (y - pickedY[k]).toDouble();
        if (dx * dx + dy * dy < sep * sep) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;
      pickedX.add(x);
      pickedY.add(y);
      final weight = range == 0 ? 1.0 : (activity[i] - minC) / range;
      out.add(Anchor(x / w, y / h, weight));
    }
    // Greedy pass already visits by descending activity, so [out] is
    // weight-desc; re-sort defensively (weight desc, then scan order).
    out.sort((a, b) {
      final c = b.weight.compareTo(a.weight);
      return c != 0 ? c : (a.ny * w + a.nx).compareTo(b.ny * w + b.nx);
    });
    return out;
  }

  // Same math as HeuristicDepthEstimator._localContrast
  // (depth_splitter.dart:128-140), adapted to sample via [lumAt].
  double _localContrast(int Function(int, int) lumAt, int x, int y, int w,
      int h) {
    final c = lumAt(x, y);
    var sum = 0, n = 0;
    for (var dy = -2; dy <= 2; dy += 2) {
      for (var dx = -2; dx <= 2; dx += 2) {
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        sum += (lumAt(nx, ny) - c).abs();
        n++;
      }
    }
    return n == 0 ? 0 : (sum / n / 64).clamp(0.0, 1.0);
  }

  // Same math as HeuristicDepthEstimator._saturation (depth_splitter.dart:142-147).
  double _saturation(int r, int g, int b) {
    final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    return mx == 0 ? 0 : (mx - mn) / mx;
  }

  // Same math as HeuristicDepthEstimator._skinness (depth_splitter.dart:149-158).
  double _skinness(int r, int g, int b) {
    // crude skin-tone detection, adequate as a saliency proxy for character art
    if (r < 95 || g < 40 || b < 20 || r <= g || r <= b) return 0;
    final d = (r - g).abs();
    if (d < 15 || d > 120 || r > 250 || g > 220) return 0;
    return ((r - g) / 120).clamp(0.0, 1.0);
  }

  // Same math as HeuristicDepthEstimator._boxBlur3 (depth_splitter.dart:173-199).
  List<double> _boxBlur3(List<double> src, int w, int h, {int passes = 1}) {
    var cur = List<double>.from(src);
    for (var p = 0; p < passes; p++) {
      final tmp = List<double>.filled(cur.length, 0);
      // horizontal
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final l = cur[y * w + (x - 1).clamp(0, w - 1)];
          final c = cur[y * w + x];
          final r = cur[y * w + (x + 1).clamp(0, w - 1)];
          tmp[y * w + x] = (l + c + r) / 3;
        }
      }
      // vertical
      final out = List<double>.filled(cur.length, 0);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final u = tmp[(y - 1).clamp(0, h - 1) * w + x];
          final c = tmp[y * w + x];
          final d = tmp[(y + 1).clamp(0, h - 1) * w + x];
          out[y * w + x] = (u + c + d) / 3;
        }
      }
      cur = out;
    }
    return cur;
  }
}
