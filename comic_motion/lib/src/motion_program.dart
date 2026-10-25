/// 镜头运动程序（重构方案 M2，`motion_redesign_plan_20261025.md` §3）——
/// 「运镜为主语、内容运动为强语、视差为调味」。
///
/// `program.json` 的逐格载荷：镜头（camera）+ 层参数（layers，与
/// `PanelMotionStrategy` 同源）+ 效果建议（effects，shader 路径信号）+
/// 部件引用（parts）+ 焦点升档（focus，G-3 宫格差异化——阅读器聚焦时
/// 的 uniform 乘数，动效本体变强而非只换揭示动画）。
///
/// 确定性纪律：程序只存**标称参数**，渲染期按 `durationSec` 整周期化
/// （`MotionMath.cycleCount` 同款口径，无缝循环契约延续到镜头维度）；
/// t=0 为静息点（restSnapWave 族语义）——首帧/静息帧 = 原画。
library;

import 'dart:math' as math;

import 'apng_writer.dart' show PixelRect;
import 'scene_motion.dart';
import 'subject_segmenter.dart' show SubjectMask;

/// 镜头类型（M2 程序表）。none = 无镜头（E2' narrative 裁决，不翻案）。
enum CameraType { none, pushIn, drift }

/// 镜头程序：类型 + 锚点（归一化格坐标）+ 缩放区间 + 标称周期。
class CameraProgram {
  const CameraProgram({
    this.type = CameraType.none,
    this.anchorX = 0.5,
    this.anchorY = 0.42,
    this.zoom0 = 1.0,
    this.zoom1 = 1.0,
    this.driftAmp = 0.0,
    this.periodSec = 6.0,
  });

  /// none（静默语义保持）。
  static const CameraProgram none = CameraProgram();

  final CameraType type;

  /// 缩放/漂移焦点（归一化格坐标）：action=会聚灭点，closeup=主体质心，
  /// atmosphere=格中心（中景）。
  final double anchorX;
  final double anchorY;

  /// 推镜缩放区间 [zoom0, zoom1]（pushIn；drift 恒 [1,1]+覆盖放大）。
  final double zoom0;
  final double zoom1;

  /// 横移幅度（占格宽比例，drift；±[driftAmp] 整周期往返）。
  final double driftAmp;

  /// 标称周期（秒）：渲染期按整周期数对齐 durationSec（无缝）。
  final double periodSec;

  Map<String, dynamic> toJson() => {
        'type': switch (type) {
          CameraType.none => 'none',
          CameraType.pushIn => 'pushIn',
          CameraType.drift => 'drift',
        },
        if (type != CameraType.none) ...{
          'anchor': [anchorX, anchorY],
          if (type == CameraType.pushIn) 'zoom': [zoom0, zoom1],
          if (type == CameraType.drift) 'driftAmp': driftAmp,
          'periodSec': periodSec,
        },
      };

  static CameraProgram fromJson(Map<String, dynamic> json) {
    final type = switch (json['type']) {
      'pushIn' => CameraType.pushIn,
      'drift' => CameraType.drift,
      _ => CameraType.none,
    };
    if (type == CameraType.none) return CameraProgram.none;
    final anchor = (json['anchor'] as List?)?.cast<num>();
    final zoom = (json['zoom'] as List?)?.cast<num>();
    return CameraProgram(
      type: type,
      anchorX: anchor != null && anchor.isNotEmpty ? anchor[0].toDouble() : 0.5,
      anchorY: anchor != null && anchor.length > 1
          ? anchor[1].toDouble()
          : 0.42,
      zoom0: zoom != null && zoom.isNotEmpty ? zoom[0].toDouble() : 1.0,
      zoom1: zoom != null && zoom.length > 1 ? zoom[1].toDouble() : 1.0,
      driftAmp: (json['driftAmp'] as num?)?.toDouble() ?? 0.0,
      periodSec: (json['periodSec'] as num?)?.toDouble() ?? 6.0,
    );
  }
}

/// 焦点升档乘数（G-3）：阅读器聚焦该格时 uniform 乘数（idle 基线×乘数），
/// 动效本体变强；熄焦回落。导出路径不消费（阅读器交互态），随 pack 下发。
class FocusProgram {
  const FocusProgram({this.scaleMul = 1.0, this.tempoMul = 1.0});

  /// 默认升档（方案 §3 示例值；idle 档→focus 档的乘数表）。
  static const FocusProgram defaultUp =
      FocusProgram(scaleMul: 1.6, tempoMul: 1.25);

  final double scaleMul;
  final double tempoMul;

  Map<String, dynamic> toJson() => {
        'scaleMul': scaleMul,
        'tempoMul': tempoMul,
      };

  static FocusProgram fromJson(Map<String, dynamic> json) => FocusProgram(
        scaleMul: (json['scaleMul'] as num?)?.toDouble() ?? 1.0,
        tempoMul: (json['tempoMul'] as num?)?.toDouble() ?? 1.0,
      );
}

/// 逐格运动程序（program.json 载荷）。
class MotionProgram {
  const MotionProgram({
    required this.camera,
    required this.scale,
    required this.tempo,
    required this.subjectBoost,
    this.effects = const [],
    this.focus = FocusProgram.defaultUp,
  });

  final CameraProgram camera;

  /// layers 块（与 PanelMotionStrategy 同源：幅度/节奏/主体增强）。
  final double scale;
  final double tempo;
  final double subjectBoost;

  /// 效果建议（shader 路径信号；导出路径不渲染，加性扩展位）。
  final List<String> effects;

  final FocusProgram focus;

  Map<String, dynamic> toJson() => {
        'camera': camera.toJson(),
        'layers': {
          'scale': scale,
          'tempo': tempo,
          'subjectBoost': subjectBoost,
        },
        if (effects.isNotEmpty) 'effects': effects,
        'focus': focus.toJson(),
      };

  static MotionProgram fromJson(Map<String, dynamic> json) {
    final layers = (json['layers'] as Map?)?.cast<String, dynamic>() ?? const {};
    return MotionProgram(
      camera: CameraProgram.fromJson(
          (json['camera'] as Map?)?.cast<String, dynamic>() ?? const {}),
      scale: (layers['scale'] as num?)?.toDouble() ?? 1.0,
      tempo: (layers['tempo'] as num?)?.toDouble() ?? 1.0,
      subjectBoost: (layers['subjectBoost'] as num?)?.toDouble() ?? 1.0,
      effects: (json['effects'] as List?)?.cast<String>() ?? const [],
      focus: FocusProgram.fromJson(
          (json['focus'] as Map?)?.cast<String, dynamic>() ?? const {}),
    );
  }
}

/// 程序表（方案 §3）：画面类别 → 确定性镜头配方。对标华为「按内容类型
/// 配运镜」的可复现替代——无提示词工程，纯查表。
/// - action：快推 zoom 1.0→1.10（周期短），锚点=会聚灭点（C2 特征两用）；
/// - closeup：慢推 1.0→1.05（8s 标称），锚点=主体质心；
/// - atmosphere：横移 ±1.5%（6s 标称），锚点=格中心（中景）；
/// - narrative：none（E2' 裁决：默认静止语义，不翻案）。
class MotionProgramTable {
  const MotionProgramTable();

  /// action 快推标称周期（秒）。
  static const double actionPeriodSec = 2.0;

  /// closeup 慢推标称周期（秒，方案 §3 的 8s）。
  static const double closeupPeriodSec = 8.0;

  /// atmosphere 漂移标称周期（秒）。
  static const double atmospherePeriodSec = 6.0;

  /// atmosphere 横移幅度（占格宽 ±1.5%）。
  static const double atmosphereDriftAmp = 0.015;

  MotionProgram build({
    required PanelDiagnosis d,
    required PixelRect panel,
    SubjectMask? mask,
  }) {
    final f = d.features;
    return switch (d.cls) {
      PanelClass.action => MotionProgram(
          camera: CameraProgram(
            type: CameraType.pushIn,
            anchorX: f.vpX,
            anchorY: f.vpY,
            zoom0: 1.0,
            zoom1: 1.10,
            periodSec: actionPeriodSec,
          ),
          scale: d.strategy.scale,
          tempo: d.strategy.tempo,
          subjectBoost: d.strategy.subjectBoost,
          effects: const ['speedLines'],
        ),
      PanelClass.closeup => MotionProgram(
          camera: CameraProgram(
            type: CameraType.pushIn,
            anchorX: _subjectCentroidX(mask) ?? 0.5,
            anchorY: _subjectCentroidY(mask) ?? 0.42,
            zoom0: 1.0,
            zoom1: 1.05,
            periodSec: closeupPeriodSec,
          ),
          scale: d.strategy.scale,
          tempo: d.strategy.tempo,
          subjectBoost: d.strategy.subjectBoost,
          effects: const ['heartbeat'],
        ),
      PanelClass.atmosphere => MotionProgram(
          camera: CameraProgram(
            type: CameraType.drift,
            anchorX: 0.5,
            anchorY: 0.5,
            driftAmp: atmosphereDriftAmp,
            periodSec: atmospherePeriodSec,
          ),
          scale: d.strategy.scale,
          tempo: d.strategy.tempo,
          subjectBoost: d.strategy.subjectBoost,
        ),
      PanelClass.narrative => MotionProgram(
          camera: CameraProgram.none,
          scale: d.strategy.scale,
          tempo: d.strategy.tempo,
          subjectBoost: d.strategy.subjectBoost,
        ),
    };
  }

  /// 主体质心（最大 blob 的外接矩形中心，归一化格坐标）——特写推镜锚点。
  /// 无主体/空掩码返回 null（回落程序表默认锚点）。
  static double? _subjectCentroidX(SubjectMask? mask) {
    if (mask == null || !mask.hasSubjects || mask.blobs.isEmpty) return null;
    var best = mask.blobs.first;
    for (final b in mask.blobs) {
      if (b.area > best.area) best = b;
    }
    final cx = best.rect.x + best.rect.width / 2;
    return (cx / math.max(1, mask.width)).clamp(0.0, 1.0).toDouble();
  }

  static double? _subjectCentroidY(SubjectMask? mask) {
    if (mask == null || !mask.hasSubjects || mask.blobs.isEmpty) return null;
    var best = mask.blobs.first;
    for (final b in mask.blobs) {
      if (b.area > best.area) best = b;
    }
    final cy = best.rect.y + best.rect.height / 2;
    return (cy / math.max(1, mask.height)).clamp(0.0, 1.0).toDouble();
  }
}
