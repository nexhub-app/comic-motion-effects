/// Plan B §2.3：`part_motion.json` 数据契约与解析器。
///
/// 这是**三期 AI 侧车与引擎之间唯一的接口**：侧车产出这份 JSON，引擎按本契约
/// 消费；`kind` 枚举一次列全，表外的名字视为未知，但引擎侧当前只实现 [PartKind.hand]（[PartKind.isImplemented]），其余
/// kind 解析通过、渲染跳过。加新 kind 时本枚举扩一项，JSON schema 不变。
///
/// 三条硬约束：
/// 1. **永不抛异常** —— 任何坏输入都降级为 [PartMotionParse.spec] == null 或
///    丢弃单个部件，管线照旧出图；
/// 2. **不静默** —— 每个丢弃/修正决定都产一条 warning，经
///    `EffectConfig.warnings` → `PipelineResult.warnings` → 台账 → HTTP 回显；
/// 3. **确定性** —— 纯函数，无随机、无时钟、无 I/O，同文本必得同结果。
///
/// 本契约是**运行期输入**（与栅格图同级），不参与 `configHash`——性质同
/// `DepthEstimator` 注入（见 `test/depth_interface_test.dart`）。
library;

import 'dart:convert';

/// 部位类型。JSON 里用小写字符串名（[PartKind.fromName]）。
enum PartKind {
  head,

  /// 当前唯一有渲染实现（`mesh_warper` 衰减旋转）的 kind。
  hand,
  arm,
  torso,
  hair,
  garment;

  bool get isImplemented => this == PartKind.hand;

  static PartKind? fromName(String name) => PartKind.values
      .cast<PartKind?>()
      .firstWhere((k) => k!.name == name, orElse: () => null);
}

/// 多边形顶点，归一化画布坐标（0..1）。
class PartPoint {
  final double x;
  final double y;
  const PartPoint(this.x, this.y);
}

/// 单个可动部件。[anchorX]/[anchorY] 是旋转根点（手腕），已保证落在多边形内或
/// 被钳到最近顶点；[joint] 原样透传，供三期按关节选波形。
class PartMotion {
  final PartKind kind;
  final List<PartPoint> polygon;
  final double anchorX;
  final double anchorY;
  final String joint;

  /// extended 模式的补片路径：三期契约预留位。当前渲染侧**只做 contained**，
  /// 本字段被解析并原样保留，但没有任何消费方（因此也不会为此发告警）。
  final String? inpaintPath;

  const PartMotion({
    required this.kind,
    required this.polygon,
    required this.anchorX,
    required this.anchorY,
    required this.joint,
    this.inpaintPath,
  });

  /// 摆动轴的另一端：多边形里离锚点最远的顶点，等距时取列表最靠前者。
  ///
  /// 契约只给 polygon + anchor（手腕），衰减旋转需要一个杠杆方向，这里把它
  /// 确定性地推出来（无时钟、无随机、tie-break 按顶点序）——同一份 JSON 永远
  /// 得到同一根轴。轴长恒 > 0：[PartMotionParser] 已拒绝面积 ≈ 0 的多边形。
  PartPoint get tipPoint {
    var best = polygon.first;
    var bestD = double.negativeInfinity;
    for (final p in polygon) {
      final dx = p.x - anchorX, dy = p.y - anchorY;
      final d = dx * dx + dy * dy;
      if (d > bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }
}

class PartMotionSpec {
  final int version;
  final List<PartMotion> parts;

  const PartMotionSpec(this.version, this.parts);
}

/// 解析结果：[spec] 为 null 表示整份不可用；[warnings] 恒非 null、顺序稳定。
class PartMotionParse {
  final PartMotionSpec? spec;
  final List<String> warnings;

  const PartMotionParse(this.spec, this.warnings);
}

class PartMotionParser {
  /// 本引擎唯一能读懂的契约版本；更高版本整份拒绝（而不是猜着渲染）。
  static const int supportedVersion = 1;

  /// 部件数上限：形变成本按部件线性增长，且一页里不可能有 8 只**高置信**的手。
  static const int maxParts = 8;

  static const double _eps = 1e-9;

  static PartMotionParse parse(String text) {
    final warnings = <String>[];

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      return PartMotionParse(
          null, ['part_motion JSON 无法解析，整份忽略：${e.message}']);
    }

    if (decoded is! Map) {
      return PartMotionParse(
          null, ['part_motion 顶层不是对象（缺 version/parts），整份忽略']);
    }
    final root = decoded.cast<Object?, Object?>();

    final rawVersion = root['version'];
    if (rawVersion == null) {
      return PartMotionParse(null,
          ['part_motion 缺 version 字段（期望 $supportedVersion），整份忽略']);
    }
    if (rawVersion is! num || rawVersion.round() != supportedVersion) {
      return PartMotionParse(null, [
        'part_motion version=$rawVersion 不受支持（本引擎支持 version $supportedVersion），整份忽略'
      ]);
    }

    final rawParts = root['parts'];
    if (rawParts is! List) {
      return PartMotionParse(null,
          ['part_motion.parts 不是数组（收到 ${rawParts.runtimeType}），整份忽略']);
    }

    final kept = <PartMotion>[];
    for (var i = 0; i < rawParts.length; i++) {
      if (kept.length >= maxParts) {
        warnings.add('part_motion 部件数超上限 $maxParts，丢弃后 ${rawParts.length - i} 个');
        break;
      }
      final part = _parsePart(rawParts[i], i, warnings);
      if (part != null) kept.add(part);
    }

    return PartMotionParse(
        PartMotionSpec(supportedVersion, List.unmodifiable(kept)), warnings);
  }

  static PartMotion? _parsePart(
      Object? raw, int i, List<String> warnings) {
    final tag = 'part_motion[$i]';
    if (raw is! Map) {
      warnings.add('$tag 不是对象，该部件忽略');
      return null;
    }
    final m = raw.cast<Object?, Object?>();

    final rawKind = m['kind'];
    final kind = rawKind is String ? PartKind.fromName(rawKind) : null;
    if (kind == null) {
      warnings.add('$tag 未知 kind "$rawKind"，该部件忽略');
      return null;
    }

    final polygon = _parsePolygon(m['polygon'], tag, warnings);
    if (polygon == null) return null;

    final rawAnchor = m['anchor'];
    final anchor = _parseAnchor(rawAnchor, polygon, tag, warnings);
    if (anchor == null) return null;
    final rawJoint = rawAnchor is Map ? rawAnchor['joint'] : null;

    final rawInpaint = m['inpaint'];
    if (rawInpaint != null && rawInpaint is! String) {
      warnings.add('$tag.inpaint 不是字符串，按缺省（contained）处理');
    }

    return PartMotion(
      kind: kind,
      polygon: polygon,
      anchorX: anchor.x,
      anchorY: anchor.y,
      joint: rawJoint is String ? rawJoint : '',
      inpaintPath: rawInpaint is String && rawInpaint.isNotEmpty ? rawInpaint : null,
    );
  }

  static List<PartPoint>? _parsePolygon(
      Object? raw, String tag, List<String> warnings) {
    if (raw is! List || raw.length < 3) {
      warnings.add('$tag.polygon 少于 3 点，该部件忽略');
      return null;
    }
    final pts = <PartPoint>[];
    for (final v in raw) {
      if (v is! List || v.length < 2 || v[0] is! num || v[1] is! num) {
        warnings.add('$tag.polygon 存在非 [x,y] 数值点，该部件忽略');
        return null;
      }
      final x = (v[0] as num).toDouble();
      final y = (v[1] as num).toDouble();
      if (x < 0 || x > 1 || y < 0 || y > 1) {
        warnings.add('$tag.polygon 坐标 ($x,$y) 越界，契约要求归一化 0..1，该部件忽略');
        return null;
      }
      pts.add(PartPoint(x, y));
    }
    if (_shoelaceArea(pts).abs() < 1e-6) {
      warnings.add('$tag.polygon 面积≈0（退化/共线），该部件忽略');
      return null;
    }
    return List.unmodifiable(pts);
  }

  static PartPoint? _parseAnchor(
      Object? raw, List<PartPoint> polygon, String tag, List<String> warnings) {
    if (raw is! Map) {
      warnings.add('$tag.anchor 缺失或不是对象，该部件忽略');
      return null;
    }
    final a = raw.cast<Object?, Object?>();
    final x = a['x'], y = a['y'];
    if (x is! num || y is! num) {
      warnings.add('$tag.anchor 缺少数值 x/y，该部件忽略');
      return null;
    }
    final p = PartPoint(x.toDouble(), y.toDouble());
    if (_containsPoint(polygon, p)) return p;

    var nearest = polygon.first;
    var best = double.infinity;
    for (final v in polygon) {
      final d = (v.x - p.x) * (v.x - p.x) + (v.y - p.y) * (v.y - p.y);
      if (d < best) {
        best = d;
        nearest = v;
      }
    }
    warnings.add(
        '$tag.anchor (${p.x},${p.y}) 落在 polygon 外，钳到最近顶点 (${nearest.x},${nearest.y})');
    return nearest;
  }

  static double _shoelaceArea(List<PartPoint> pts) {
    var sum = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum / 2;
  }

  /// 射线法（偶奇）。边界点按「在内」处理，避免同一输入在阈值上抖动。
  static bool _containsPoint(List<PartPoint> pts, PartPoint p) {
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      if (_cross(a, b, p).abs() < _eps && _within(a, b, p)) return true;
    }
    var inside = false;
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      final a = pts[i], b = pts[j];
      if ((a.y > p.y) != (b.y > p.y) &&
          p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
        inside = !inside;
      }
    }
    return inside;
  }

  static double _cross(PartPoint a, PartPoint b, PartPoint p) =>
      (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);

  static bool _within(PartPoint a, PartPoint b, PartPoint p) =>
      p.x >= (a.x < b.x ? a.x : b.x) - _eps &&
      p.x <= (a.x > b.x ? a.x : b.x) + _eps &&
      p.y >= (a.y < b.y ? a.y : b.y) - _eps &&
      p.y <= (a.y > b.y ? a.y : b.y) + _eps;
}
