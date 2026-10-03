import 'dart:math' as math;

import 'image_model.dart';
import 'part_motion.dart';

/// Plan B §2.1：把「哪块像素像一只会挥的手」抽象成可替换接口。
///
/// 与 [DepthEstimator] 同性质：**运行期依赖，不参与 configHash**。三期 AI 侧车
/// 产出 `part_motion.json` 时走另一条路（直接给多边形，见 `part_motion.dart`），
/// 本接口的默认实现负责在没有侧车时给出纯代码候选。
abstract class HandLocator {
  const HandLocator();

  /// 输入一张**已经按格裁好**的图（多部件页必须逐格喂，否则所有封闭区共用一个
  /// 背景连通域，第二只手会被判成背景）。返回按 score 降序、score 相同按 y/x 升序。
  List<HandCandidate> locate(RgbaImage img);
}

/// 一个高置信手形候选。坐标全部是**相对传入图**的归一化 0..1。
class HandCandidate {
  /// 区域轮廓（[HeuristicHandLocator] 下是 72 点径向多边形），供 contained 羽化。
  final List<PartPoint> outline;

  /// 旋转根点：手+前臂作为整体时的**不跟着动的那一端**（掌根/肘侧）。
  final double rootX, rootY;

  /// 最远指尖：taper 权重 1 的位置。
  final double tipX, tipY;

  /// 0..1 置信度。低于 [HeuristicHandLocator.confidenceFloor] 的候选根本不会
  /// 出现在返回值里 —— 半置信的手最容易被看成穿帮，宁可不动。
  final double score;

  const HandCandidate({
    required this.outline,
    required this.rootX,
    required this.rootY,
    required this.tipX,
    required this.tipY,
    required this.score,
  });
}

/// 纯代码启发式定位器：墨线围出的封闭亮区 → 径向轮廓 → 指状突出计数。
///
/// 为什么不用肤色：实测 4 张含手语料，两张黑白漫画页的 skinness 覆盖率是
/// **0.00%**（灰阶页 `r<=g` 恒成立），彩色动画静帧里灰调的手也是 0.00%。肤色在
/// 本产品的输入分布上没有信号，几何才有。
///
/// 全程确定性：行优先扫描 + 迭代式 4 邻域洪泛（同 `SaliencyAnalyzer.subjectBox`
/// 的写法），无随机、无时钟。
class HeuristicHandLocator extends HandLocator {
  /// 墨线上限亮度：低于它视为描线（漫画线稿）。
  final int inkLuma;

  /// 部件包围盒最小边长（像素）。小于它就画不出可分辨的手指。
  final int minSidePx;

  /// 部件面积占整图上限：超过多半是整页背景框或大留白。
  final double maxAreaFrac;

  const HeuristicHandLocator({
    this.inkLuma = 90,
    this.minSidePx = 24,
    this.maxAreaFrac = 0.35,
  });

  /// 置信门：低于此值不产出候选。
  static const double confidenceFloor = 0.55;

  static const int _rays = 72; // 5° 一步
  static const int _rayProbeStep = 2; // 0.5px 一步（坐标 ×2 定点）
  static const double _peakOverMedian = 1.55;
  static const double _valleyOverMedian = 1.20;
  static const int _valleySearch = 14;
  static const int _maxHalfWidth = 6; // 30°
  static const double _minLenOverPalm = 0.50;
  static const int _minLobes = 3;
  static const int _maxLobes = 5;

  @override
  List<HandCandidate> locate(RgbaImage img) {
    final w = img.width, h = img.height;
    if (w < 4 || h < 4) return const [];

    final ink = List<bool>.filled(w * h, false);
    for (var i = 0; i < w * h; i++) {
      ink[i] = img.luminance(i) <= inkLuma;
    }

    final out = <HandCandidate>[];
    final visited = List<bool>.filled(w * h, false);
    final stack = <int>[];
    for (var seed = 0; seed < w * h; seed++) {
      if (ink[seed] || visited[seed]) continue;
      final comp = _flood(ink, visited, stack, seed, w, h);
      if (comp == null) continue; // 触边 = 背景
      final c = _classify(comp, w, h, ink);
      if (c != null && c.score >= confidenceFloor) out.add(c);
    }

    out.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      final y = a.rootY.compareTo(b.rootY);
      return y != 0 ? y : a.rootX.compareTo(b.rootX);
    });
    return List.unmodifiable(out);
  }

  /// 洪泛一个非墨连通域。**触边即弃**（返回 null），因为触边的区域是背景。
  List<int>? _flood(
      List<bool> ink, List<bool> visited, List<int> stack, int seed, int w, int h) {
    stack.clear();
    stack.add(seed);
    visited[seed] = true;
    final pixels = <int>[];
    var touchesBorder = false;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      final x = p % w, y = p ~/ w;
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1) touchesBorder = true;
      if (!touchesBorder) pixels.add(p); // 背景域只标 visited，不攒像素
      for (var d = 0; d < 4; d++) {
        final nx = x + (d == 0 ? 1 : d == 1 ? -1 : 0);
        final ny = y + (d == 2 ? 1 : d == 3 ? -1 : 0);
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final q = ny * w + nx;
        if (ink[q] || visited[q]) continue;
        visited[q] = true;
        stack.add(q);
      }
    }
    return touchesBorder ? null : pixels;
  }

  static double _r(List<double> rays, int k, double fallback) {
    final v = rays[k];
    return v.isNaN ? fallback : v;
  }

  static double _n01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

  HandCandidate? _classify(List<int> comp, int w, int h, List<bool> ink) {
    var minX = w, maxX = -1, minY = h, maxY = -1;
    for (final p in comp) {
      final x = p % w, y = p ~/ w;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    if (bw < minSidePx || bh < minSidePx) return null;
    if (comp.length > maxAreaFrac * w * h) return null;

    final maxR = math.sqrt((bw * bw + bh * bh).toDouble()) + 2;
    // 径向原点取**内切圆心**（掌心的等价物）而非质心：手指偏在一侧时质心被拽向
    // 指尖，峰/中位数比从 1.8 塌到 1.3，突出就数不出来了。
    final palm = _palmCenter(comp, w, h, ink, maxR);
    if (palm == null) return null;
    final cx = palm[0], cy = palm[1];

    // 径向轮廓：从掌心沿 72 条射线走到第一条墨线。
    final rays = List<double>.filled(_rays, double.nan);
    var leaks = 0;
    for (var k = 0; k < _rays; k++) {
      final th = 2 * math.pi * k / _rays;
      final ux = math.cos(th), uy = math.sin(th);
      var hit = double.nan;
      for (var t = 2; t <= maxR * _rayProbeStep; t++) {
        final r = t / _rayProbeStep;
        final px = (cx + ux * r).round(), py = (cy + uy * r).round();
        if (px < 0 || py < 0 || px >= w || py >= h) break;
        if (ink[py * w + px]) {
          hit = r;
          break;
        }
      }
      if (hit.isNaN) leaks++;
      rays[k] = hit;
    }
    if (leaks > _rays ~/ 4) return null; // 轮廓有缺口：不是封闭部件

    final valid = [for (final r in rays) if (!r.isNaN) r]..sort();
    final median = valid[valid.length ~/ 2];
    if (median < 2) return null;

    final lobes = _lobes(rays, median);
    if (lobes.length < _minLobes || lobes.length > _maxLobes) return null;

    var lenSum = 0.0, widthSum = 0;
    for (final l in lobes) {
      lenSum += (l.radius - median) / median;
      widthSum += l.halfWidth;
    }
    final lenRatio = lenSum / lobes.length;
    if (lenRatio < _minLenOverPalm) return null;
    final meanHalfWidth = widthSum / lobes.length;
    if (meanHalfWidth > _maxHalfWidth) return null;

    // 旋转根/尖：指尖簇的重心对面 = 根，最远突出 = 尖。
    var tvx = 0.0, tvy = 0.0;
    for (final l in lobes) {
      tvx += math.cos(l.theta);
      tvy += math.sin(l.theta);
    }
    final tipCx = cx + tvx / lobes.length * median * 1.6;
    final tipCy = cy + tvy / lobes.length * median * 1.6;
    var rootK = 0, tipK = 0;
    var farFromTip = -1.0, farFromCentroid = -1.0;
    for (var k = 0; k < _rays; k++) {
      if (rays[k].isNaN) continue;
      final th = 2 * math.pi * k / _rays;
      final bx = cx + math.cos(th) * rays[k], by = cy + math.sin(th) * rays[k];
      final dt = (bx - tipCx) * (bx - tipCx) + (by - tipCy) * (by - tipCy);
      if (dt > farFromTip) {
        farFromTip = dt;
        rootK = k;
      }
      if (rays[k] > farFromCentroid) {
        farFromCentroid = rays[k];
        tipK = k;
      }
    }
    final rootTh = 2 * math.pi * rootK / _rays;
    final tipTh = 2 * math.pi * tipK / _rays;

    final score = (0.30 +
            0.30 * (1 - (lobes.length - 4).abs() / 2) +
            0.20 * math.min(1.0, lenRatio / 0.9) +
            0.20 * math.min(1.0, math.min(bw, bh) / minSidePx / 3))
        .clamp(0.0, 1.0)
        .toDouble();

    final outline = <PartPoint>[
      for (var k = 0; k < _rays; k++)
        PartPoint(
            _n01((cx + math.cos(2 * math.pi * k / _rays) * _r(rays, k, median)) / w),
            _n01((cy + math.sin(2 * math.pi * k / _rays) * _r(rays, k, median)) / h))
    ];

    return HandCandidate(
      outline: List.unmodifiable(outline),
      rootX: _n01((cx + math.cos(rootTh) * rays[rootK]) / w),
      rootY: _n01((cy + math.sin(rootTh) * rays[rootK]) / h),
      tipX: _n01((cx + math.cos(tipTh) * rays[tipK]) / w),
      tipY: _n01((cy + math.sin(tipTh) * rays[tipK]) / h),
      score: score,
    );
  }

  /// 内切圆心 = 域内离墨线最远的点（掌心）。每 2px 采样，行优先，平手取先者 ⇒
  /// 与像素遍历顺序一样确定。
  List<double>? _palmCenter(
      List<int> comp, int w, int h, List<bool> ink, double maxR) {
    var bestX = 0.0, bestY = 0.0, bestD = -1.0;
    for (final p in comp) {
      final x = p % w, y = p ~/ w;
      if ((x & 1) != 0 || (y & 1) != 0) continue;
      final d = _distanceToInk(x.toDouble(), y.toDouble(), w, h, ink, maxR);
      if (d > bestD) {
        bestD = d;
        bestX = x.toDouble();
        bestY = y.toDouble();
      }
    }
    if (bestD < 2) return null;
    return [bestX, bestY];
  }

  double _distanceToInk(
      double ox, double oy, int w, int h, List<bool> ink, double maxR) {
    var nearest = maxR;
    for (var k = 0; k < 16; k++) {
      final th = 2 * math.pi * k / 16;
      final ux = math.cos(th), uy = math.sin(th);
      for (var t = 1; t <= nearest * _rayProbeStep; t++) {
        final r = t / _rayProbeStep;
        final px = (ox + ux * r).round(), py = (oy + uy * r).round();
        if (px < 0 || py < 0 || px >= w || py >= h) {
          nearest = r < nearest ? r : nearest;
          break;
        }
        if (ink[py * w + px]) {
          nearest = r < nearest ? r : nearest;
          break;
        }
      }
    }
    return nearest;
  }

  /// 局部极大 + 两侧必须回落到谷底 = 一个指状突出。
  List<_Lobe> _lobes(List<double> rays, double median) {
    final peakMin = median * _peakOverMedian;
    final valleyMax = median * _valleyOverMedian;
    final got = <_Lobe>[];
    for (var k = 0; k < _rays; k++) {
      final r = rays[k];
      if (r.isNaN || r < peakMin) continue;
      if (r < rays[(k - 1 + _rays) % _rays] || r < rays[(k + 1) % _rays]) continue;
      if (r == rays[(k + 1) % _rays] && rays[(k - 1 + _rays) % _rays] > r) continue;
      final left = _fallsToValley(rays, k, -1, valleyMax);
      final right = _fallsToValley(rays, k, 1, valleyMax);
      if (left == 0 || right == 0) continue;
      var hw = 0;
      final mid = median + 0.5 * (r - median);
      for (var d = -left; d <= right; d++) {
        final v = rays[(k + d + _rays) % _rays];
        if (!v.isNaN && v >= mid) hw++;
      }
      got.add(_Lobe(2 * math.pi * k / _rays, r, (hw + 1) ~/ 2));
    }
    // 相邻样本同为极大值时合并，避免一根手指数两次。
    final merged = <_Lobe>[];
    for (final l in got) {
      if (merged.isNotEmpty &&
          (l.theta - merged.last.theta).abs() * _rays / (2 * math.pi) <= 1.5) {
        if (l.radius > merged.last.radius) merged[merged.length - 1] = l;
        continue;
      }
      merged.add(l);
    }
    return merged;
  }

  /// 沿 dir 方向走到 ≤valleyMax 的步数；0 = 走不到（不是突出）。
  int _fallsToValley(List<double> rays, int k, int dir, double valleyMax) {
    for (var s = 1; s <= _valleySearch; s++) {
      final v = rays[(k + dir * s + _rays) % _rays];
      if (v.isNaN) return 0;
      if (v <= valleyMax) return s;
      if (v > rays[(k + dir * (s - 1) + _rays) % _rays]) return 0; // 还在爬升
    }
    return 0;
  }
}

class _Lobe {
  final double theta;
  final double radius;
  final int halfWidth;
  const _Lobe(this.theta, this.radius, this.halfWidth);
}
