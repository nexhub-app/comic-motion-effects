import 'dart:math' as math;
import 'dart:typed_data';

import '../image_model.dart';
import '../part_motion.dart';

/// Plan B §7.2：部位网格形变通道 —— **衰减旋转**（taper-rotation）。
///
/// 语义：绕根点旋转，角度沿「根→尖」轴线性增大：`θ(p) = angleDeg · w(p)`，
/// 根平面 `w=0`、尖平面 `w=1`。挥手/示意就是这个形状 —— 掌根几乎不动，指尖带走
/// 最大位移。逆映射 + [RgbaImage.sampleBilinear] 采样，只碰 bbox 内像素。
///
/// 拆成「建表 + 应用」两半，是为了守住本仓库的确定性契约（同 v1.4 的极性表
/// `_starSamples` 那套）：[buildPlan] 在**构造期**跑一次（含昂贵的逐像素多边形
/// 距离），[apply] 每帧只做「查表 → 旋转 → 采样 → 混合」，无跨帧状态。
class MeshWarper {
  /// contained 模式的边缘羽化带宽（像素）。0 = 硬边。
  final int featherPx;

  const MeshWarper({this.featherPx = 2});

  /// 建一次形变表。[target] 只提供画布尺寸（多边形是归一化坐标）。
  /// 退化输入（面积≈0 / 完全在画布外）返回空 plan，[apply] 对空 plan 无操作。
  WarpPlan buildPlan(RgbaImage target, PartShape shape) {
    final w = target.width, h = target.height;
    final pts = <List<double>>[
      for (final p in shape.polygon) [p.x * w, p.y * h]
    ];
    if (pts.length < 3 || _polygonArea(pts) < 1.0) return WarpPlan.empty();

    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in pts) {
      if (p[0] < minX) minX = p[0];
      if (p[0] > maxX) maxX = p[0];
      if (p[1] < minY) minY = p[1];
      if (p[1] > maxY) maxY = p[1];
    }
    final pad = math.max(1, featherPx) + 1;
    final x0 = math.max(0, (minX - pad).floor());
    final y0 = math.max(0, (minY - pad).floor());
    final x1 = math.min(w, (maxX + pad).ceil() + 1);
    final y1 = math.min(h, (maxY + pad).ceil() + 1);
    final pw = x1 - x0, ph = y1 - y0;
    if (pw <= 0 || ph <= 0) return WarpPlan.empty();

    final rx = shape.rootX * w, ry = shape.rootY * h;
    final ax = shape.tipX * w - rx, ay = shape.tipY * h - ry;
    final axisLen2 = ax * ax + ay * ay;
    if (axisLen2 < 1e-9) return WarpPlan.empty();

    final alpha = Uint8List(pw * ph);
    final taper = Float32List(pw * ph);
    final feather = math.max(1, featherPx).toDouble();
    for (var ly = 0; ly < ph; ly++) {
      final py = y0 + ly + 0.5;
      for (var lx = 0; lx < pw; lx++) {
        final px = x0 + lx + 0.5;
        final inside = _contains(pts, px, py);
        final d = _distanceToEdge(pts, px, py);
        final coverage = inside
            ? math.min(1.0, d / feather)
            : math.max(0.0, 1.0 - d / feather);
        final i = ly * pw + lx;
        alpha[i] = (coverage * 255).round().clamp(0, 255);
        final t = ((px - rx) * ax + (py - ry) * ay) / axisLen2;
        taper[i] = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
      }
    }
    return WarpPlan(
        originX: x0, originY: y0, width: pw, height: ph, alpha: alpha, taper: taper, rootPxX: rx, rootPxY: ry);
  }

  /// 把 [src] 按 [plan] 旋转 `angleDeg`（度，尖侧最大）后混合写进 [dst]。
  /// [dst] 与 [src] 可以是同一张图之外的任意目标；本函数只读 src、只写 dst。
  void apply(RgbaImage dst, RgbaImage src, WarpPlan plan, double angleDeg) {
    if (plan.isEmpty) return;
    final out = List<int>.filled(4, 0);
    for (var ly = 0; ly < plan.height; ly++) {
      final py = plan.originY + ly + 0.5;
      for (var lx = 0; lx < plan.width; lx++) {
        final i = ly * plan.width + lx;
        final a = plan.alpha[i];
        if (a == 0) continue;
        final px = plan.originX + lx + 0.5;
        final th = angleDeg * plan.taper[i] * math.pi / 180;
        final dx = px - plan.rootPxX, dy = py - plan.rootPxY;
        double sx, sy;
        if (th == 0) {
          sx = px;
          sy = py;
        } else {
          final c = math.cos(-th), s = math.sin(-th);
          sx = plan.rootPxX + c * dx - s * dy;
          sy = plan.rootPxY + s * dx + c * dy;
        }
        src.sampleBilinear(sx - 0.5, sy - 0.5, out);
        final o = ((py - 0.5).floor() * dst.width + (px - 0.5).floor()) * 4;
        final mix = a / 255.0;
        for (var ch = 0; ch < 3; ch++) {
          final base = dst.data[o + ch];
          dst.data[o + ch] = (base + (out[ch] - base) * mix).round().clamp(0, 255);
        }
      }
    }
  }

  static double _polygonArea(List<List<double>> p) {
    var s = 0.0;
    for (var i = 0; i < p.length; i++) {
      final a = p[i], b = p[(i + 1) % p.length];
      s += a[0] * b[1] - b[0] * a[1];
    }
    return s.abs() / 2;
  }

  static bool _contains(List<List<double>> p, double x, double y) {
    var inside = false;
    for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
      final xi = p[i][0], yi = p[i][1], xj = p[j][0], yj = p[j][1];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  static double _distanceToEdge(List<List<double>> p, double x, double y) {
    var best = double.infinity;
    for (var i = 0; i < p.length; i++) {
      final a = p[i], b = p[(i + 1) % p.length];
      final ex = b[0] - a[0], ey = b[1] - a[1];
      final len2 = ex * ex + ey * ey;
      var t = len2 == 0 ? 0.0 : ((x - a[0]) * ex + (y - a[1]) * ey) / len2;
      t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
      final dx = x - (a[0] + t * ex), dy = y - (a[1] + t * ey);
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < best) best = d;
    }
    return best;
  }
}

/// 形变目标几何：归一化多边形 + 根/尖两点。
///
/// 两个来源都能落到它上面：[HandCandidate]（启发式定位）与 `part_motion.json`
/// 的 `PartMotion`（三期侧车，anchor 即根点）。
class PartShape {
  final List<PartPoint> polygon;
  final double rootX, rootY, tipX, tipY;

  const PartShape({
    required this.polygon,
    required this.rootX,
    required this.rootY,
    required this.tipX,
    required this.tipY,
  });
}

/// [MeshWarper.buildPlan] 的产物：bbox + 覆盖率 + taper 权重，逐帧只查表。
class WarpPlan {
  final int originX, originY, width, height;
  final Uint8List alpha;
  final Float32List taper;
  final double rootPxX, rootPxY;

  const WarpPlan({
    required this.originX,
    required this.originY,
    required this.width,
    required this.height,
    required this.alpha,
    required this.taper,
    required this.rootPxX,
    required this.rootPxY,
  });

  WarpPlan.empty()
      : originX = 0,
        originY = 0,
        width = 0,
        height = 0,
        alpha = Uint8List(0),
        taper = Float32List(0),
        rootPxX = 0,
        rootPxY = 0;

  bool get isEmpty => width <= 0 || height <= 0;

  /// 绝对像素坐标 -> 覆盖率 0..255；bbox 外为 0。
  int alphaAt(int x, int y) {
    if (isEmpty || x < originX || y < originY) return 0;
    final lx = x - originX, ly = y - originY;
    if (lx >= width || ly >= height) return 0;
    return alpha[ly * width + lx];
  }

  /// 绝对像素坐标 -> 旋转权重 0..1；bbox 外为 0。
  double taperAt(int x, int y) {
    if (isEmpty || x < originX || y < originY) return 0;
    final lx = x - originX, ly = y - originY;
    if (lx >= width || ly >= height) return 0;
    return taper[ly * width + lx];
  }
}
