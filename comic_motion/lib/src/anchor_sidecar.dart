/// X3（v1.5）：`anchors.json` 侧车数据契约与解析器——外部 AI 显著性/焦点
/// 识别产出方与引擎之间的注入接口（与 `part_motion.json` 同族：**运行期
/// 输入，不参与 configHash**；优先级高于 `SaliencyEstimator` 接口注入与
/// 内置启发式）。
///
/// JSON schema（version 1）：
/// ```json
/// {
///   "version": 1,
///   "anchors": [
///     {"x": 0.32, "y": 0.41, "weight": 0.93}
///   ],
///   "subjectBox": {"x": 0.10, "y": 0.20, "w": 0.50, "h": 0.60},
///   "activity": {"width": 64, "height": 80, "values": [0.01, ...]}
/// }
/// ```
/// - `anchors`（必需，≤16 条）：归一化 [0,1] 画布坐标的兴趣点；weight ∈
///   [0,1]，越高越优先成为焦点类效果的落点。引擎按 weight 降序消费，
///   `anchors.first` 即权重最高点（并列按输入序）。
/// - `subjectBox`（可选）：归一化矩形，主体包围盒。
/// - `activity`（可选）：行主序活动度网格（绝对口径，空白 ≈ 0.01、墨块
///   中心 ≈ 0.40-0.45，与内置 [SaliencyAnalyzer] 同尺度）。宽高 ≥ 2 且
///   长度吻合时驱动粒子播种的密度加权；缺省/非法 ⇒ 粒子回落均匀分布。
///
/// 三条硬约束与 `PartMotionParser` 一致：
/// 1. **永不抛异常**——坏输入降级为 spec == null / 丢弃单条 + warning；
/// 2. **不静默**——每个丢弃/修正都产 warning，经 `PipelineResult.warnings`
///    → 台账 → HTTP 回显；
/// 3. **确定性**——纯函数，无随机、无时钟、无 I/O，同文本必得同结果。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'apng_writer.dart' show PixelRect;
import 'image_model.dart';
import 'saliency_anchors.dart';

/// 单条侧车锚点（归一化坐标）。
class SidecarAnchor {
  const SidecarAnchor(this.x, this.y, this.weight);
  final double x, y, weight;
}

/// 归一化矩形（[PixelRect] 的字段是画布整数像素，侧车口径是 [0,1] 浮点，
/// 两者不混用；换算到画布在 [AnchorsSpec.toAnchorMap] 一处完成）。
class SidecarRect {
  const SidecarRect(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
}

/// 解析产物：anchors 侧车的一页数据（归一化口径，与栅格分辨率无关）。
class AnchorsSpec {
  const AnchorsSpec(
      this.version, this.anchors, this.subjectBox, this.activity, this.aw,
      this.ah);

  static const int supportedVersion = 1;

  /// 条数上限：焦点类效果只消费前几条，16 条足够任何一页的标注密度。
  static const int maxAnchors = 16;

  final int version;
  final List<SidecarAnchor> anchors;

  /// 归一化主体框（null = 未提供）。
  final SidecarRect? subjectBox;

  /// 活动度网格（null = 未提供/非法）。[aw]×[ah]，行主序，值 ∈ [0,1]。
  final Float64List? activity;
  final int aw;
  final int ah;

  /// 换算成引擎的 [AnchorMap]（画布像素口径）。无网格时 activity 为空表
  /// ——合成器的粒子加权检测（width ≥ 2 且 maxAct > 1e-6）自然回落均匀
  /// 分布，anchors 列表仍驱动焦点类效果。
  AnchorMap toAnchorMap(int canvasW, int canvasH) {
    PixelRect box;
    final sb = subjectBox;
    if (sb == null) {
      box = PixelRect(0, 0, canvasW, canvasH);
    } else {
      final gx0 = (sb.x * canvasW).round().clamp(0, canvasW - 1);
      final gy0 = (sb.y * canvasH).round().clamp(0, canvasH - 1);
      final gx1 = ((sb.x + sb.w) * canvasW).round().clamp(gx0 + 1, canvasW);
      final gy1 = ((sb.y + sb.h) * canvasH).round().clamp(gy0 + 1, canvasH);
      box = PixelRect(gx0, gy0, gx1 - gx0, gy1 - gy0);
    }
    return AnchorMap(
      aw,
      ah,
      activity ?? Float64List(0),
      box,
      [for (final a in anchors) Anchor(a.x, a.y, a.weight)],
      List<PixelRect>.unmodifiable([PixelRect(0, 0, canvasW, canvasH)]),
    );
  }
}

/// 解析结果：[spec] 为 null 表示整份不可用；[warnings] 恒非 null、顺序稳定。
class AnchorsParse {
  const AnchorsParse(this.spec, this.warnings);
  final AnchorsSpec? spec;
  final List<String> warnings;
}

class AnchorsSpecParser {
  static AnchorsParse parse(String text) {
    final warnings = <String>[];

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      return AnchorsParse(
          null, ['anchors JSON 无法解析，整份忽略：${e.message}']);
    }
    if (decoded is! Map) {
      return AnchorsParse(
          null, ['anchors 顶层不是对象（缺 version/anchors），整份忽略']);
    }
    final root = decoded.cast<Object?, Object?>();

    final rawVersion = root['version'];
    if (rawVersion == null) {
      return AnchorsParse(null,
          ['anchors 缺 version 字段（期望 ${AnchorsSpec.supportedVersion}），整份忽略']);
    }
    if (rawVersion is! num ||
        rawVersion.round() != AnchorsSpec.supportedVersion) {
      return AnchorsParse(null, [
        'anchors version=$rawVersion 不受支持（本引擎支持 version '
            '${AnchorsSpec.supportedVersion}），整份忽略'
      ]);
    }

    final rawAnchors = root['anchors'];
    if (rawAnchors is! List || rawAnchors.isEmpty) {
      return AnchorsParse(
          null, ['anchors.anchors 不是非空数组，整份忽略']);
    }

    final kept = <SidecarAnchor>[];
    for (var i = 0; i < rawAnchors.length && kept.length < AnchorsSpec.maxAnchors; i++) {
      final tag = 'anchors[$i]';
      final a = rawAnchors[i];
      if (a is! Map) {
        warnings.add('$tag 不是对象，该条忽略');
        continue;
      }
      final m = a.cast<Object?, Object?>();
      final x = m['x'], y = m['y'], w = m['weight'];
      if (x is! num || y is! num || w is! num) {
        warnings.add('$tag 缺少数值 x/y/weight，该条忽略');
        continue;
      }
      final dx = x.toDouble(), dy = y.toDouble(), dw = w.toDouble();
      if (!dx.isFinite || !dy.isFinite || !dw.isFinite) {
        warnings.add('$tag 含非有限数值，该条忽略');
        continue;
      }
      if (dx < 0 || dx > 1 || dy < 0 || dy > 1) {
        warnings.add(
            '$tag 坐标 ($dx,$dy) 越界，契约要求归一化 0..1，该条忽略');
        continue;
      }
      if (dw < 0 || dw > 1) {
        warnings.add('$tag weight $dw 越界，钳到 [0,1]');
      }
      kept.add(SidecarAnchor(dx, dy, dw.clamp(0.0, 1.0)));
    }
    if (rawAnchors.length > AnchorsSpec.maxAnchors) {
      warnings.add(
          'anchors 条数 ${rawAnchors.length} 超上限 ${AnchorsSpec.maxAnchors}，'
          '只保留前 ${AnchorsSpec.maxAnchors} 条');
    }
    if (kept.isEmpty) {
      return AnchorsParse(null, ['anchors 无有效条目，整份忽略']);
    }
    // weight 降序，精确并列按输入序（Dart sort 不稳定，必须显式 tie-break
    // ——确定性契约；引擎消费 anchors.first）。
    final indexed = [for (var i = 0; i < kept.length; i++) (i, kept[i])];
    indexed.sort((a, b) {
      final c = b.$2.weight.compareTo(a.$2.weight);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    final sorted = [for (final e in indexed) e.$2];

    // subjectBox（可选）。
    SidecarRect? box;
    final rawBox = root['subjectBox'];
    if (rawBox != null) {
      if (rawBox is Map) {
        final bm = rawBox.cast<Object?, Object?>();
        final bx = bm['x'], by = bm['y'], bw = bm['w'], bh = bm['h'];
        if (bx is num && by is num && bw is num && bh is num) {
          final fx = bx.toDouble(),
              fy = by.toDouble(),
              fw = bw.toDouble(),
              fh = bh.toDouble();
          if (fx >= 0 &&
              fy >= 0 &&
              fw > 0 &&
              fh > 0 &&
              fx + fw <= 1.0 + 1e-9 &&
              fy + fh <= 1.0 + 1e-9) {
            box = SidecarRect(fx, fy, fw, fh);
          } else {
            warnings.add('subjectBox 越界/宽高非正，整字段忽略');
          }
        } else {
          warnings.add('subjectBox 缺少数值 x/y/w/h，整字段忽略');
        }
      } else {
        warnings.add('subjectBox 不是对象，整字段忽略');
      }
    }

    // activity 网格（可选）。
    Float64List? act;
    var aw = 0, ah = 0;
    final rawAct = root['activity'];
    if (rawAct != null) {
      if (rawAct is Map) {
        final am = rawAct.cast<Object?, Object?>();
        final gw = am['width'], gh = am['height'], vals = am['values'];
        if (gw is num && gh is num && vals is List) {
          aw = gw.round();
          ah = gh.round();
          if (aw >= 2 && ah >= 2 && vals.length == aw * ah) {
            final grid = Float64List(aw * ah);
            var ok = true;
            for (var i = 0; i < grid.length; i++) {
              final v = vals[i];
              if (v is! num || !v.isFinite) {
                warnings.add('activity.values[$i] 非有限数值，整网格忽略');
                ok = false;
                break;
              }
              grid[i] = v.toDouble().clamp(0.0, 1.0);
            }
            if (ok) {
              act = grid;
            } else {
              aw = 0;
              ah = 0;
            }
          } else {
            warnings.add(
                'activity 网格尺寸非法（要求 width/height ≥ 2 且 '
                'values 长度吻合），整网格忽略');
            aw = 0;
            ah = 0;
          }
        } else {
          warnings.add('activity 缺少 width/height/values，整字段忽略');
        }
      } else {
        warnings.add('activity 不是对象，整字段忽略');
      }
    }

    return AnchorsParse(
        AnchorsSpec(AnchorsSpec.supportedVersion,
            List.unmodifiable(sorted), box, act, aw, ah),
        warnings);
  }
}

/// 侧车版 [SaliencyEstimator]：把已解析的 [AnchorsSpec] 适配成引擎的估算
/// 通道。侧车是**整页**口径（归一化坐标与栅格分辨率无关），[panels] 被
/// 忽略——外部 AI 若按格分析，直接产出页级锚点即可。
class SidecarSaliencyEstimator implements SaliencyEstimator {
  const SidecarSaliencyEstimator(this.spec);
  final AnchorsSpec spec;

  @override
  AnchorMap analyze(RgbaImage img, {List<PixelRect>? panels}) =>
      spec.toAnchorMap(img.width, img.height);
}
