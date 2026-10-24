/// `scene.json` 侧车数据契约与解析器（v1.9 动效画面判断）——外部 AI/宿主
/// 逐格动效裁决的注入接口（与 `anchors.json`/`part_motion.json` 同族：
/// **运行期输入，不参与 configHash**）。
///
/// JSON schema（version 1）：
/// ```json
/// {
///   "version": 1,
///   "panels": [
///     {"x": 0.0, "y": 0.0, "w": 1.0, "h": 0.5, "motion": false},
///     {"x": 0.0, "y": 0.5, "w": 1.0, "h": 0.5, "motion": true, "scale": 0.5}
///   ]
/// }
/// ```
/// - `panels`（必需，≤[SceneMotionSpec.maxPanels] 条）：归一化 [0,1] 画布
///   坐标的格矩形；`motion:false` ⇒ scale 0（该格完全静止），`motion:true`
///   ⇒ scale 1（满幅）。显式 `scale` ∈ [0,1] 存在时优先于布尔映射
///   （越界钳到 [0,1] + warning）。
/// - 消费语义（引擎侧）：检测格与侧车条目按**像素空间 IoU** 匹配（≥
///   [SceneMotionSpec.minIou] 取最大者，并列取输入序在前者）；命中的格用
///   侧车 scale，未命中的格回落注入判断器（[PanelMotionJudge]）。这使
///   侧车可以做「全量逐格裁决」也可以只「特判个别格」。
///
/// 三条硬约束与 `AnchorsSpecParser`/`PartMotionParser` 一致：
/// 1. **永不抛异常**——坏输入降级为 spec == null / 丢弃单条 + warning；
/// 2. **不静默**——每个丢弃/修正都产 warning，经 `PipelineResult.warnings`
///    → 台账 → HTTP 回显；
/// 3. **确定性**——纯函数，无随机、无时钟、无 I/O，同文本必得同结果。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'apng_writer.dart' show PixelRect;

/// 单条侧车格裁决（归一化坐标 + 该格幅度乘数）。
class SidecarScenePanel {
  const SidecarScenePanel(this.x, this.y, this.w, this.h, this.scale,
      {this.tempo = 1.0, this.subjectBoost = 1.0});
  final double x, y, w, h;

  /// 该格视差幅度乘数 ∈ [0,1]：0 = 完全静止，1 = 满幅。
  final double scale;

  /// 该格节奏乘数（Phase E 加性字段，缺省 1.0 = 零变化；>1 加快、<1 放慢）。
  final double tempo;

  /// 该格主体层增强乘数（Phase E 加性字段，缺省 1.0 = 零变化）。
  final double subjectBoost;
}

/// 解析产物：scene 侧车的一页数据（归一化口径，与栅格分辨率无关）。
class SceneMotionSpec {
  const SceneMotionSpec(this.version, this.panels);

  static const int supportedVersion = 1;

  /// 条数上限：格级裁决一页几十格封顶，64 条足够。
  static const int maxPanels = 64;

  /// 格匹配的最小像素空间 IoU；低于此视为「不是同一格」，回落启发式。
  static const double minIou = 0.3;

  final int version;
  final List<SidecarScenePanel> panels;

  /// 画布像素格 [rect] 的侧车幅度；无命中返回 null（调用方回落判断器）。
  double? panelScaleFor(PixelRect rect, int canvasW, int canvasH) =>
      panelFor(rect, canvasW, canvasH)?.scale;

  /// 画布像素格 [rect] 的命中条目；无命中返回 null。
  SidecarScenePanel? panelFor(PixelRect rect, int canvasW, int canvasH) {
    final asPanel = SidecarScenePanel(rect.x / canvasW, rect.y / canvasH,
        rect.width / canvasW, rect.height / canvasH, 0);
    SidecarScenePanel? best;
    var bestIou = 0.0;
    for (final p in panels) {
      final iou = sceneIou(p, asPanel, canvasW.toDouble(),
          canvasH.toDouble());
      if (iou < minIou) continue;
      // 并列取输入序在前者（严格大于才替换——确定性契约）。
      if (best == null || iou > bestIou) {
        best = p;
        bestIou = iou;
      }
    }
    return best;
  }
}

/// 两个归一化矩形在 [canvasW]×[canvasH] 像素空间 的 IoU。
/// 像素空间口径：归一化坐标的面积比会因宽高比失真，交并比必须在像素
/// 尺度上算才与「视觉重合度」一致。相离/退化返回 0。
double sceneIou(
    SidecarScenePanel a, SidecarScenePanel b, double canvasW, double canvasH) {
  final ax0 = a.x * canvasW, ay0 = a.y * canvasH;
  final ax1 = (a.x + a.w) * canvasW, ay1 = (a.y + a.h) * canvasH;
  final bx0 = b.x * canvasW, by0 = b.y * canvasH;
  final bx1 = (b.x + b.w) * canvasW, by1 = (b.y + b.h) * canvasH;
  final iw = math.min(ax1, bx1) - math.max(ax0, bx0);
  final ih = math.min(ay1, by1) - math.max(ay0, by0);
  if (iw <= 0 || ih <= 0) return 0.0;
  final inter = iw * ih;
  final union = (ax1 - ax0) * (ay1 - ay0) +
      (bx1 - bx0) * (by1 - by0) -
      inter;
  return union <= 0 ? 0.0 : inter / union;
}

/// 解析结果：[spec] 为 null 表示整份不可用；[warnings] 恒非 null、顺序稳定。
class SceneMotionParse {
  const SceneMotionParse(this.spec, this.warnings);
  final SceneMotionSpec? spec;
  final List<String> warnings;
}

class SceneMotionParser {
  static SceneMotionParse parse(String text) {
    final warnings = <String>[];

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      return SceneMotionParse(
          null, ['scene JSON 无法解析，整份忽略：${e.message}']);
    }
    if (decoded is! Map) {
      return SceneMotionParse(
          null, ['scene 顶层不是对象（缺 version/panels），整份忽略']);
    }
    final root = decoded.cast<Object?, Object?>();

    final rawVersion = root['version'];
    if (rawVersion == null) {
      return SceneMotionParse(null,
          ['scene 缺 version 字段（期望 ${SceneMotionSpec.supportedVersion}），整份忽略']);
    }
    if (rawVersion is! num ||
        rawVersion.round() != SceneMotionSpec.supportedVersion) {
      return SceneMotionParse(null, [
        'scene version=$rawVersion 不受支持（本引擎支持 version '
            '${SceneMotionSpec.supportedVersion}），整份忽略'
      ]);
    }

    final rawPanels = root['panels'];
    if (rawPanels is! List || rawPanels.isEmpty) {
      return SceneMotionParse(null, ['scene.panels 不是非空数组，整份忽略']);
    }

    final kept = <SidecarScenePanel>[];
    for (var i = 0;
        i < rawPanels.length && kept.length < SceneMotionSpec.maxPanels;
        i++) {
      final tag = 'scene.panels[$i]';
      final a = rawPanels[i];
      if (a is! Map) {
        warnings.add('$tag 不是对象，该条忽略');
        continue;
      }
      final m = a.cast<Object?, Object?>();
      final x = m['x'], y = m['y'], w = m['w'], h = m['h'];
      if (x is! num || y is! num || w is! num || h is! num) {
        warnings.add('$tag 缺少数值 x/y/w/h，该条忽略');
        continue;
      }
      final dx = x.toDouble(),
          dy = y.toDouble(),
          dw = w.toDouble(),
          dh = h.toDouble();
      if (!dx.isFinite || !dy.isFinite || !dw.isFinite || !dh.isFinite) {
        warnings.add('$tag 含非有限数值，该条忽略');
        continue;
      }
      if (dx < 0 || dy < 0 || dw <= 0 || dh <= 0 ||
          dx + dw > 1.0 + 1e-9 || dy + dh > 1.0 + 1e-9) {
        warnings.add(
            '$tag 矩形 ($dx,$dy,$dw,$dh) 越界，契约要求归一化 0..1 且宽高为正，该条忽略');
        continue;
      }

      // 幅度：显式 scale 优先于 motion 布尔映射。
      double scale;
      final rawScale = m['scale'];
      final rawMotion = m['motion'];
      if (rawScale is num) {
        if (!rawScale.isFinite) {
          warnings.add('$tag scale 非有限数值，该条忽略');
          continue;
        }
        final ds = rawScale.toDouble();
        if (ds < 0 || ds > 1) {
          warnings.add('$tag scale $ds 越界，钳到 [0,1]');
        }
        scale = ds.clamp(0.0, 1.0);
      } else if (rawScale != null) {
        warnings.add('$tag scale 不是数值，该条忽略');
        continue;
      } else if (rawMotion is bool) {
        scale = rawMotion ? 1.0 : 0.0;
      } else {
        warnings.add('$tag 缺少 motion 布尔或 scale 数值，该条忽略');
        continue;
      }
      // Phase E 加性可选字段：tempo / subjectBoost（缺省 1.0 = 零变化；
      // 非法值警告 + 回落 1.0，不丢条目——加性字段坏值不拖垮主裁决）。
      var tempo = 1.0;
      final rawTempo = m['tempo'];
      if (rawTempo is num) {
        if (rawTempo.isFinite && rawTempo.toDouble() > 0) {
          tempo = rawTempo.toDouble().clamp(0.25, 4.0);
        } else {
          warnings.add('$tag tempo 非法（需正有限数），回落 1.0');
        }
      } else if (rawTempo != null) {
        warnings.add('$tag tempo 不是数值，回落 1.0');
      }
      var boost = 1.0;
      final rawBoost = m['subjectBoost'];
      if (rawBoost is num) {
        if (rawBoost.isFinite && rawBoost.toDouble() >= 0) {
          boost = rawBoost.toDouble().clamp(0.0, 2.0);
        } else {
          warnings.add('$tag subjectBoost 非法（需非负有限数），回落 1.0');
        }
      } else if (rawBoost != null) {
        warnings.add('$tag subjectBoost 不是数值，回落 1.0');
      }
      kept.add(SidecarScenePanel(dx, dy, dw, dh, scale,
          tempo: tempo, subjectBoost: boost));
    }
    if (rawPanels.length > SceneMotionSpec.maxPanels) {
      warnings.add(
          'scene.panels 条数 ${rawPanels.length} 超上限 '
          '${SceneMotionSpec.maxPanels}，只保留前 ${SceneMotionSpec.maxPanels} 条');
    }
    if (kept.isEmpty) {
      return SceneMotionParse(null, ['scene 无有效条目，整份忽略']);
    }

    return SceneMotionParse(
        SceneMotionSpec(SceneMotionSpec.supportedVersion,
            List.unmodifiable(kept)),
        warnings);
  }
}
