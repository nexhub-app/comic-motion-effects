/// Effect parameter configuration. Fully JSON-serializable, versioned and
/// hashed so the same parameters always reproduce the same output.
///
/// 纯 Dart：本文件不 import dart:io（配置文件的读取走 `config_io.dart` 的
/// [effectConfigFromFile]，属于 IO 边界）。序列化 + configHash 因此可以在
/// 任意平台（含未来 Web）单测与复用。
library;

import 'dart:convert';

import 'render/envelope.dart';
import 'render/quality.dart';

/// Which motion effects to render, with per-effect amplitude.
/// v1.1 adds: rain, snow, sakura, fireflies, godRays, speedLines,
/// impactFlash, heartbeat (all opt-in via [EffectConfig.effects]).
enum EffectKind {
  parallax,
  breathing,
  ambient,
  lightSweep,
  dust,
  rain,
  snow,
  sakura,
  fireflies,
  godRays,
  speedLines,
  impactFlash,
  heartbeat,
  fog,
  embers,
  lightning,
  toneShift,
  vignette,
  starlight,
  slowPush,
  shimmer,
  focusLines,
  screenTone,
  mangaShake,
  impactRings,
  brushStreak,
  flame,
  smoke,
  bubbles,
  leaves,
  meteors,
  moodScript,
}

/// 效果名 → 枚举。未知名一律抛 [ConfigException]，不静默退化成某个效果：
/// CLI 的 `--effects` 与配置文件里的 `effects` 数组共用这条校验。
EffectKind effectKindFromName(Object? name) {
  for (final k in EffectKind.values) {
    if (k.name == name) return k;
  }
  throw ConfigException(
      'Unknown effect name: "$name" '
      '(available: ${EffectKind.values.map((e) => e.name).join(', ')})',
      code: 'E_UNKNOWN_EFFECT');
}

enum DepthMode { autoLayers, singleLayer }

enum OutputFormat { gif, frames, both, apng }

class ParallaxParams {
  const ParallaxParams({
    this.amplitude = 0.030,
    this.periodSec = 6.0,
    this.directionDeg = 0.0,
    this.verticalRatio = 0.35,
  });

  final double amplitude; // fraction of image width for max layer shift
  final double periodSec;
  final double directionDeg; // main sweep direction
  final double verticalRatio; // how much vertical motion vs horizontal

  Map<String, dynamic> toJson() => {
        'amplitude': amplitude,
        'periodSec': periodSec,
        'directionDeg': directionDeg,
        'verticalRatio': verticalRatio,
      };

  static ParallaxParams fromJson(Map<String, dynamic> j) => ParallaxParams(
        amplitude: (j['amplitude'] as num?)?.toDouble() ?? 0.030,
        periodSec: (j['periodSec'] as num?)?.toDouble() ?? 6.0,
        directionDeg: (j['directionDeg'] as num?)?.toDouble() ?? 0.0,
        verticalRatio: (j['verticalRatio'] as num?)?.toDouble() ?? 0.35,
      );

  /// R5 顶层便捷参数的映射载体：null = 保留原值。
  ParallaxParams copyWith({double? amplitude, double? directionDeg}) =>
      ParallaxParams(
        amplitude: amplitude ?? this.amplitude,
        periodSec: periodSec,
        directionDeg: directionDeg ?? this.directionDeg,
        verticalRatio: verticalRatio,
      );
}

class BreathingParams {
  const BreathingParams({
    this.enabled = true,
    this.amplitude = 0.012,
    this.periodSec = 4.0,
    this.anchor = 'center',
  });

  final bool enabled;
  final double amplitude; // max scale deviation (e.g. 0.012 => 1.012 zoom)
  final double periodSec;
  final String anchor; // center | top | bottom

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'amplitude': amplitude,
        'periodSec': periodSec,
        'anchor': anchor,
      };

  static BreathingParams fromJson(Map<String, dynamic> j) => BreathingParams(
        enabled: j['enabled'] as bool? ?? true,
        amplitude: (j['amplitude'] as num?)?.toDouble() ?? 0.012,
        periodSec: (j['periodSec'] as num?)?.toDouble() ?? 4.0,
        anchor: (j['anchor'] as String?) ?? 'center',
      );
}

class AmbientParams {
  const AmbientParams({
    this.enabled = true,
    this.particleCount = 40,
    this.speed = 12.0,
    this.opacity = 0.22,
    this.mode = 'dust',
  });

  final bool enabled;
  final int particleCount;
  final double speed; // px/sec drift (scaled by image size)
  final double opacity;
  final String mode; // dust | sparkle

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'particleCount': particleCount,
        'speed': speed,
        'opacity': opacity,
        'mode': mode,
      };

  static AmbientParams fromJson(Map<String, dynamic> j) => AmbientParams(
        enabled: j['enabled'] as bool? ?? true,
        particleCount: (j['particleCount'] as num?)?.toInt() ?? 40,
        speed: (j['speed'] as num?)?.toDouble() ?? 12.0,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.22,
        mode: (j['mode'] as String?) ?? 'dust',
      );
}

/// ---- v1.1 新增动效参数 ----
/// 约定：fallCycles/driftCycles/spinTurns/blinkCycles/swayCycles/pulses/
/// flashes/beats 均为「每个循环的整数次数」，保证 GIF 循环无接缝。

String? _normHex(String? s) {
  if (s == null) return null;
  final v = s.replaceAll('#', '').trim();
  return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v) ? v.toLowerCase() : null;
}

class RainParams {
  const RainParams({
    this.count = 90,
    this.fallCycles = 1,
    this.angleDeg = 12.0,
    this.lengthPx = 18.0,
    this.opacity = 0.38,
    this.color = 'd8e2ee',
  });

  final int count;
  final int fallCycles; // 每循环下落几个画面高度
  final double angleDeg; // 雨线倾角
  final double lengthPx;
  final double opacity;
  final String color; // RRGGBB

  Map<String, dynamic> toJson() => {
        'count': count,
        'fallCycles': fallCycles,
        'angleDeg': angleDeg,
        'lengthPx': lengthPx,
        'opacity': opacity,
        'color': color,
      };

  static RainParams fromJson(Map<String, dynamic> j) => RainParams(
        count: (j['count'] as num?)?.toInt() ?? 90,
        fallCycles: (j['fallCycles'] as num?)?.toInt() ?? 1,
        angleDeg: (j['angleDeg'] as num?)?.toDouble() ?? 12.0,
        lengthPx: (j['lengthPx'] as num?)?.toDouble() ?? 18.0,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.38,
        color: _normHex(j['color'] as String?) ?? 'd8e2ee',
      );
}

class SnowParams {
  const SnowParams({
    this.count = 64,
    this.fallCycles = 1,
    this.sizePx = 2.4,
    this.swayPx = 14.0,
    this.opacity = 0.85,
  });

  final int count;
  final int fallCycles;
  final double sizePx;
  final double swayPx;
  final double opacity;

  Map<String, dynamic> toJson() => {
        'count': count,
        'fallCycles': fallCycles,
        'sizePx': sizePx,
        'swayPx': swayPx,
        'opacity': opacity,
      };

  static SnowParams fromJson(Map<String, dynamic> j) => SnowParams(
        count: (j['count'] as num?)?.toInt() ?? 64,
        fallCycles: (j['fallCycles'] as num?)?.toInt() ?? 1,
        sizePx: (j['sizePx'] as num?)?.toDouble() ?? 2.4,
        swayPx: (j['swayPx'] as num?)?.toDouble() ?? 14.0,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.85,
      );
}

class SakuraParams {
  const SakuraParams({
    this.count = 30,
    this.fallCycles = 1,
    this.sizePx = 4.2,
    this.swayPx = 22.0,
    this.spinTurns = 2,
    this.opacity = 0.9,
    this.color = 'f6b8c8',
  });

  final int count;
  final int fallCycles;
  final double sizePx; // 花瓣长轴半长
  final double swayPx;
  final int spinTurns; // 每循环自转圈数
  final double opacity;
  final String color;

  Map<String, dynamic> toJson() => {
        'count': count,
        'fallCycles': fallCycles,
        'sizePx': sizePx,
        'swayPx': swayPx,
        'spinTurns': spinTurns,
        'opacity': opacity,
        'color': color,
      };

  static SakuraParams fromJson(Map<String, dynamic> j) => SakuraParams(
        count: (j['count'] as num?)?.toInt() ?? 30,
        fallCycles: (j['fallCycles'] as num?)?.toInt() ?? 1,
        sizePx: (j['sizePx'] as num?)?.toDouble() ?? 4.2,
        swayPx: (j['swayPx'] as num?)?.toDouble() ?? 22.0,
        spinTurns: (j['spinTurns'] as num?)?.toInt() ?? 2,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.9,
        color: _normHex(j['color'] as String?) ?? 'f6b8c8',
      );
}

class FirefliesParams {
  const FirefliesParams({
    this.count = 22,
    this.glowPx = 14.0,
    this.blinkCycles = 3,
    this.driftCycles = 2,
    this.opacity = 0.8,
    this.color = 'ffe27a',
  });

  final int count;
  final double glowPx; // 光晕半径
  final int blinkCycles; // 每循环明灭次数
  final int driftCycles; // 游移基础频率
  final double opacity;
  final String color;

  Map<String, dynamic> toJson() => {
        'count': count,
        'glowPx': glowPx,
        'blinkCycles': blinkCycles,
        'driftCycles': driftCycles,
        'opacity': opacity,
        'color': color,
      };

  static FirefliesParams fromJson(Map<String, dynamic> j) => FirefliesParams(
        count: (j['count'] as num?)?.toInt() ?? 22,
        glowPx: (j['glowPx'] as num?)?.toDouble() ?? 14.0,
        blinkCycles: (j['blinkCycles'] as num?)?.toInt() ?? 3,
        driftCycles: (j['driftCycles'] as num?)?.toInt() ?? 2,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.8,
        color: _normHex(j['color'] as String?) ?? 'ffe27a',
      );
}

class GodRaysParams {
  const GodRaysParams({
    this.count = 3,
    this.angleDeg = 24.0,
    this.widthFrac = 0.06,
    this.intensity = 0.30,
    this.swayCycles = 1,
    this.color = 'fff0c8',
  });

  final int count;
  final double angleDeg; // 从竖直方向偏转
  final double widthFrac; // 半宽占图宽比例
  final double intensity;
  final int swayCycles;
  final String color;

  Map<String, dynamic> toJson() => {
        'count': count,
        'angleDeg': angleDeg,
        'widthFrac': widthFrac,
        'intensity': intensity,
        'swayCycles': swayCycles,
        'color': color,
      };

  static GodRaysParams fromJson(Map<String, dynamic> j) => GodRaysParams(
        count: (j['count'] as num?)?.toInt() ?? 3,
        angleDeg: (j['angleDeg'] as num?)?.toDouble() ?? 24.0,
        widthFrac: (j['widthFrac'] as num?)?.toDouble() ?? 0.06,
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.30,
        swayCycles: (j['swayCycles'] as num?)?.toInt() ?? 1,
        color: _normHex(j['color'] as String?) ?? 'fff0c8',
      );
}

class SpeedLinesParams {
  const SpeedLinesParams({
    this.count = 48,
    this.lengthFrac = 0.30,
    this.intensity = 0.5,
    this.pulses = 4,
    this.thickness = 1,
  });

  final int count;
  final double lengthFrac; // 线长占短边比例
  final double intensity;
  final int pulses; // 每循环脉冲次数
  final int thickness;

  Map<String, dynamic> toJson() => {
        'count': count,
        'lengthFrac': lengthFrac,
        'intensity': intensity,
        'pulses': pulses,
        'thickness': thickness,
      };

  static SpeedLinesParams fromJson(Map<String, dynamic> j) => SpeedLinesParams(
        count: (j['count'] as num?)?.toInt() ?? 48,
        lengthFrac: (j['lengthFrac'] as num?)?.toDouble() ?? 0.30,
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.5,
        pulses: (j['pulses'] as num?)?.toInt() ?? 4,
        thickness: (j['thickness'] as num?)?.toInt() ?? 1,
      );
}

class ImpactFlashParams {
  const ImpactFlashParams({
    this.flashes = 2,
    this.dutyFrac = 0.12,
    this.intensity = 0.5,
  });

  final int flashes; // 每循环闪光次数
  final double dutyFrac; // 单次闪光占循环比例
  final double intensity;

  Map<String, dynamic> toJson() => {
        'flashes': flashes,
        'dutyFrac': dutyFrac,
        'intensity': intensity,
      };

  static ImpactFlashParams fromJson(Map<String, dynamic> j) =>
      ImpactFlashParams(
        flashes: (j['flashes'] as num?)?.toInt() ?? 2,
        dutyFrac: (j['dutyFrac'] as num?)?.toDouble() ?? 0.12,
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.5,
      );
}

class HeartbeatParams {
  const HeartbeatParams({
    this.beats = 3,
    this.intensity = 0.02,
    this.doubleBeat = true,
  });

  final int beats; // 每循环心跳次数
  final double intensity; // 缩放幅度
  final bool doubleBeat; // lub-dub 双拍

  Map<String, dynamic> toJson() => {
        'beats': beats,
        'intensity': intensity,
        'doubleBeat': doubleBeat,
      };

  static HeartbeatParams fromJson(Map<String, dynamic> j) => HeartbeatParams(
        beats: (j['beats'] as num?)?.toInt() ?? 3,
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.02,
        doubleBeat: j['doubleBeat'] as bool? ?? true,
      );
}

/// ---- v1.2 新增动效参数 ----

class FogParams {
  const FogParams({
    this.blobs = 8,
    this.driftCycles = 1,
    this.opacity = 0.10,
    this.color = 'e8eef2',
  });

  final int blobs;
  final int driftCycles;
  final double opacity;
  final String color;

  Map<String, dynamic> toJson() => {
        'blobs': blobs,
        'driftCycles': driftCycles,
        'opacity': opacity,
        'color': color,
      };

  static FogParams fromJson(Map<String, dynamic> j) => FogParams(
        blobs: (j['blobs'] as num?)?.toInt() ?? 8,
        driftCycles: (j['driftCycles'] as num?)?.toInt() ?? 1,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.10,
        color: _normHex(j['color'] as String?) ?? 'e8eef2',
      );
}

class EmbersParams {
  const EmbersParams({
    this.count = 40,
    this.riseCycles = 1,
    this.glowPx = 6.0,
    this.opacity = 0.75,
    this.color = 'ff9a3c',
  });

  final int count;
  final int riseCycles;
  final double glowPx;
  final double opacity;
  final String color;

  Map<String, dynamic> toJson() => {
        'count': count,
        'riseCycles': riseCycles,
        'glowPx': glowPx,
        'opacity': opacity,
        'color': color,
      };

  static EmbersParams fromJson(Map<String, dynamic> j) => EmbersParams(
        count: (j['count'] as num?)?.toInt() ?? 40,
        riseCycles: (j['riseCycles'] as num?)?.toInt() ?? 1,
        glowPx: (j['glowPx'] as num?)?.toDouble() ?? 6.0,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.75,
        color: _normHex(j['color'] as String?) ?? 'ff9a3c',
      );
}

class LightningParams {
  const LightningParams({
    this.strikes = 2,
    this.boltOpacity = 0.9,
    this.flashIntensity = 0.45,
  });

  final int strikes; // 每循环落雷次数
  final double boltOpacity; // 闪电主干不透明度
  final double flashIntensity; // 全屏瞬亮强度

  Map<String, dynamic> toJson() => {
        'strikes': strikes,
        'boltOpacity': boltOpacity,
        'flashIntensity': flashIntensity,
      };

  static LightningParams fromJson(Map<String, dynamic> j) => LightningParams(
        strikes: (j['strikes'] as num?)?.toInt() ?? 2,
        boltOpacity: (j['boltOpacity'] as num?)?.toDouble() ?? 0.9,
        flashIntensity: (j['flashIntensity'] as num?)?.toDouble() ?? 0.45,
      );
}

class ToneShiftParams {
  const ToneShiftParams({
    this.shift = 0.05,
    this.warmthCycles = 1,
  });

  final double shift; // 色温偏移最大幅度（0-0.15）
  final int warmthCycles; // 每循环冷暖往复次数

  Map<String, dynamic> toJson() => {
        'shift': shift,
        'warmthCycles': warmthCycles,
      };

  static ToneShiftParams fromJson(Map<String, dynamic> j) => ToneShiftParams(
        shift: (j['shift'] as num?)?.toDouble() ?? 0.05,
        warmthCycles: (j['warmthCycles'] as num?)?.toInt() ?? 1,
      );
}

class VignetteParams {
  const VignetteParams({
    this.strength = 0.30,
    this.cycles = 1,
  });

  final double strength; // 暗角最大强度（0-0.8）
  final int cycles;

  Map<String, dynamic> toJson() => {
        'strength': strength,
        'cycles': cycles,
      };

  static VignetteParams fromJson(Map<String, dynamic> j) => VignetteParams(
        strength: (j['strength'] as num?)?.toDouble() ?? 0.30,
        cycles: (j['cycles'] as num?)?.toInt() ?? 1,
      );
}

class StarlightParams {
  const StarlightParams({
    this.count = 12,
    this.blinkCycles = 2,
    this.intensity = 0.7,
    this.sizePx = 9.0,
  });

  final int count;
  final int blinkCycles;
  final double intensity;
  final double sizePx; // 十字星臂长半径

  Map<String, dynamic> toJson() => {
        'count': count,
        'blinkCycles': blinkCycles,
        'intensity': intensity,
        'sizePx': sizePx,
      };

  static StarlightParams fromJson(Map<String, dynamic> j) => StarlightParams(
        count: (j['count'] as num?)?.toInt() ?? 12,
        blinkCycles: (j['blinkCycles'] as num?)?.toInt() ?? 2,
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.7,
        sizePx: (j['sizePx'] as num?)?.toDouble() ?? 9.0,
      );
}

class SlowPushParams {
  const SlowPushParams({
    this.pushFrac = 0.060,
    this.cycles = 1,
  });

  final double pushFrac; // 每循环推近比例（0.002-0.15）
  final int cycles; // ≥1（整数次往返保证无缝；1=单向推近需配往返）

  Map<String, dynamic> toJson() => {
        'pushFrac': pushFrac,
        'cycles': cycles,
      };

  static SlowPushParams fromJson(Map<String, dynamic> j) => SlowPushParams(
        pushFrac: (j['pushFrac'] as num?)?.toDouble() ?? 0.060,
        cycles: (j['cycles'] as num?)?.toInt() ?? 1,
      );
}

class ShimmerParams {
  const ShimmerParams({
    this.rows = 10,
    this.cycles = 1,
    this.intensity = 0.20,
    this.bandPx = 26.0,
  });

  final int rows; // 波纹亮带条数
  final int cycles;
  final double intensity;
  final double bandPx; // 亮带厚度

  Map<String, dynamic> toJson() => {
        'rows': rows,
        'cycles': cycles,
        'intensity': intensity,
        'bandPx': bandPx,
      };

  static ShimmerParams fromJson(Map<String, dynamic> j) => ShimmerParams(
        rows: (j['rows'] as num?)?.toInt() ?? 10,
        cycles: (j['cycles'] as num?)?.toInt() ?? 1,
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.20,
        bandPx: (j['bandPx'] as num?)?.toDouble() ?? 26.0,
      );
}

/// ---- v1.3 新增动效参数 ----
/// 漫画动势语言：集中线 / 网点纸 / 震屏 / 冲击波环 / 飞白笔触。

class FocusLinesParams {
  const FocusLinesParams({
    this.lines = 28,
    this.focalX = 0.5,
    this.focalY = 0.45,
    this.innerFrac = 0.26,
    this.wedgeDeg = 2.4,
    this.turnCycles = 1,
    this.opacity = 0.34,
    this.mode = 'black',
  });

  final int lines; // 楔形条数
  final double focalX, focalY; // 汇聚点（归一化）
  final double innerFrac; // 内圈留空半径 / 半对角，中心区域不画线
  final double wedgeDeg; // 单条楔形半顶角（度）
  final int turnCycles; // 每循环整圈旋转数（整数 → 无缝）
  final double opacity;
  final String mode; // black | white | both

  Map<String, dynamic> toJson() => {
        'lines': lines,
        'focalX': focalX,
        'focalY': focalY,
        'innerFrac': innerFrac,
        'wedgeDeg': wedgeDeg,
        'turnCycles': turnCycles,
        'opacity': opacity,
        'mode': mode,
      };

  static FocusLinesParams fromJson(Map<String, dynamic> j) {
    final m = (j['mode'] as String?) ?? 'black';
    return FocusLinesParams(
      lines: (j['lines'] as num?)?.toInt() ?? 28,
      focalX: (j['focalX'] as num?)?.toDouble() ?? 0.5,
      focalY: (j['focalY'] as num?)?.toDouble() ?? 0.45,
      innerFrac: (j['innerFrac'] as num?)?.toDouble() ?? 0.26,
      wedgeDeg: (j['wedgeDeg'] as num?)?.toDouble() ?? 2.4,
      turnCycles: (j['turnCycles'] as num?)?.toInt() ?? 1,
      opacity: (j['opacity'] as num?)?.toDouble() ?? 0.34,
      mode: (m == 'white' || m == 'both') ? m : 'black',
    );
  }
}

/// 网点纸：旋转方格网点/线网/十字网，按整数 tile 漂移 + 疏密呼吸。
class ScreenToneParams {
  const ScreenToneParams({
    this.spacingPx = 8.0,
    this.density = 0.34,
    this.driftTilesX = 2,
    this.driftTilesY = 1,
    this.densityCycles = 1,
    this.angleDeg = 30.0,
    this.opacity = 0.16,
    this.mode = 'dot',
  });

  final double spacingPx; // 网格间距（也是图案周期）
  final double density; // 网点占空比（0-1）：点面积 / 格面积
  final int driftTilesX; // 每循环沿旋转轴漂移的整格数（整数 → 无缝）
  final int driftTilesY;
  final int densityCycles; // 每循环疏密往复次数
  final double angleDeg; // 网点旋转角
  final double opacity;
  final String mode; // dot | line | cross

  Map<String, dynamic> toJson() => {
        'spacingPx': spacingPx,
        'density': density,
        'driftTilesX': driftTilesX,
        'driftTilesY': driftTilesY,
        'densityCycles': densityCycles,
        'angleDeg': angleDeg,
        'opacity': opacity,
        'mode': mode,
      };

  static ScreenToneParams fromJson(Map<String, dynamic> j) {
    final m = (j['mode'] as String?) ?? 'dot';
    return ScreenToneParams(
      spacingPx: (j['spacingPx'] as num?)?.toDouble() ?? 8.0,
      density: (j['density'] as num?)?.toDouble() ?? 0.34,
      driftTilesX: (j['driftTilesX'] as num?)?.toInt() ?? 2,
      driftTilesY: (j['driftTilesY'] as num?)?.toInt() ?? 1,
      densityCycles: (j['densityCycles'] as num?)?.toInt() ?? 1,
      angleDeg: (j['angleDeg'] as num?)?.toDouble() ?? 30.0,
      opacity: (j['opacity'] as num?)?.toDouble() ?? 0.16,
      mode: (m == 'line' || m == 'cross') ? m : 'dot',
    );
  }
}

/// 震屏：每个爆点一次衰减抖动，方向均分圆周 + 手绘角抖动。
class MangaShakeParams {
  const MangaShakeParams({
    this.shakes = 6,
    this.amplitude = 0.018,
    this.decay = 0.72,
    this.rotJitDeg = 0.12,
  });

  final int shakes; // 每循环爆点数（整数 → 无缝）
  final double amplitude; // 峰值位移占图宽比例
  final double decay; // 爆点内衰减（env = (1-ph)^(2·decay)）
  final double rotJitDeg; // 逐爆点方向抖动（度）

  Map<String, dynamic> toJson() => {
        'shakes': shakes,
        'amplitude': amplitude,
        'decay': decay,
        'rotJitDeg': rotJitDeg,
      };

  static MangaShakeParams fromJson(Map<String, dynamic> j) => MangaShakeParams(
        shakes: (j['shakes'] as num?)?.toInt() ?? 6,
        amplitude: (j['amplitude'] as num?)?.toDouble() ?? 0.018,
        decay: (j['decay'] as num?)?.toDouble() ?? 0.72,
        rotJitDeg: (j['rotJitDeg'] as num?)?.toDouble() ?? 0.12,
      );
}

/// 冲击波环：自焦点外扩的漫画描边环，多环错相；`shock` 另加一道内侧暗边。
class ImpactRingsParams {
  const ImpactRingsParams({
    this.rings = 3,
    this.focalX = 0.5,
    this.focalY = 0.5,
    this.innerFrac = 0.05,
    this.outerFrac = 0.55,
    this.thicknessPx = 3.4,
    this.pulses = 2,
    this.opacity = 0.5,
    this.mode = 'ring',
  });

  final int rings; // 同屏环数（错相排列）
  final double focalX, focalY; // 焦点（归一化）
  final double innerFrac; // 起始半径占半对角线
  final double outerFrac; // 终止半径占半对角线
  final double thicknessPx;
  final int pulses; // 每循环扩散轮数（整数 → 无缝）
  final double opacity;
  final String mode; // ring | shock

  Map<String, dynamic> toJson() => {
        'rings': rings,
        'focalX': focalX,
        'focalY': focalY,
        'innerFrac': innerFrac,
        'outerFrac': outerFrac,
        'thicknessPx': thicknessPx,
        'pulses': pulses,
        'opacity': opacity,
        'mode': mode,
      };

  static ImpactRingsParams fromJson(Map<String, dynamic> j) {
    final m = (j['mode'] as String?) ?? 'ring';
    return ImpactRingsParams(
      rings: (j['rings'] as num?)?.toInt() ?? 3,
      focalX: (j['focalX'] as num?)?.toDouble() ?? 0.5,
      focalY: (j['focalY'] as num?)?.toDouble() ?? 0.5,
      innerFrac: (j['innerFrac'] as num?)?.toDouble() ?? 0.05,
      outerFrac: (j['outerFrac'] as num?)?.toDouble() ?? 0.55,
      thicknessPx: (j['thicknessPx'] as num?)?.toDouble() ?? 3.4,
      pulses: (j['pulses'] as num?)?.toInt() ?? 2,
      opacity: (j['opacity'] as num?)?.toDouble() ?? 0.5,
      mode: m == 'shock' ? m : 'ring',
    );
  }
}

/// 飞白笔触：沿固定方向的干笔，一维噪声啃出缺口，运笔→停留→淡出。
class BrushStreakParams {
  const BrushStreakParams({
    this.streaks = 12,
    this.lengthFrac = 0.42,
    this.thicknessPx = 7.0,
    this.angleDeg = 8.0,
    this.pulses = 2,
    this.gapFreq = 0.11,
    this.opacity = 0.40,
  });

  final int streaks; // 笔触条数
  final double lengthFrac; // 长度占短边比例
  final double thicknessPx;
  final double angleDeg; // 主运笔方向
  final int pulses; // 每循环运笔轮数（整数 → 无缝）
  final double gapFreq; // 缺口频率（周/像素）；渲染内夹到 ≤0.25 以免与 2px 段长混叠
  final double opacity;

  Map<String, dynamic> toJson() => {
        'streaks': streaks,
        'lengthFrac': lengthFrac,
        'thicknessPx': thicknessPx,
        'angleDeg': angleDeg,
        'pulses': pulses,
        'gapFreq': gapFreq,
        'opacity': opacity,
      };

  static BrushStreakParams fromJson(Map<String, dynamic> j) =>
      BrushStreakParams(
        streaks: (j['streaks'] as num?)?.toInt() ?? 12,
        lengthFrac: (j['lengthFrac'] as num?)?.toDouble() ?? 0.42,
        thicknessPx: (j['thicknessPx'] as num?)?.toDouble() ?? 7.0,
        angleDeg: (j['angleDeg'] as num?)?.toDouble() ?? 8.0,
        pulses: (j['pulses'] as num?)?.toInt() ?? 2,
        gapFreq: (j['gapFreq'] as num?)?.toDouble() ?? 0.11,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.40,
      );
}

/// 火焰：底部一排火苗，节点自下而上堆叠，颜色由根部热色过渡到尖端冷色。
class FlameParams {
  const FlameParams({
    this.tongues = 14,
    this.riseCycles = 2,
    this.heightFrac = 0.18,
    this.flickerCycles = 6,
    this.hot = 'fff3b0',
    this.cold = 'ff5a1e',
    this.opacity = 0.72,
  });

  final int tongues; // 火苗条数
  final int riseCycles; // 每循环摆动轮数（整数 → 无缝）
  final double heightFrac; // 苗高占画高比例
  final int flickerCycles; // 每循环闪烁轮数
  final String hot; // 根部（热）色
  final String cold; // 尖端（冷）色
  final double opacity;

  Map<String, dynamic> toJson() => {
        'tongues': tongues,
        'riseCycles': riseCycles,
        'heightFrac': heightFrac,
        'flickerCycles': flickerCycles,
        'hot': hot,
        'cold': cold,
        'opacity': opacity,
      };

  static FlameParams fromJson(Map<String, dynamic> j) => FlameParams(
        tongues: (j['tongues'] as num?)?.toInt() ?? 14,
        riseCycles: (j['riseCycles'] as num?)?.toInt() ?? 2,
        heightFrac: (j['heightFrac'] as num?)?.toDouble() ?? 0.18,
        flickerCycles: (j['flickerCycles'] as num?)?.toInt() ?? 6,
        hot: _normHex(j['hot'] as String?) ?? 'fff3b0',
        cold: _normHex(j['cold'] as String?) ?? 'ff5a1e',
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.72,
      );
}

/// 烟雾：雾团上升而非横漂，三频叠加扰动 + 半径随高度放大（扩散感）。
class SmokeParams {
  const SmokeParams({
    this.puffs = 16,
    this.riseCycles = 1,
    this.sizePx = 26.0,
    this.turbulence = 0.35,
    this.opacity = 0.14,
    this.color = 'c9ccd4',
  });

  final int puffs; // 雾团数
  final int riseCycles; // 每循环上升轮数（整数 → 无缝）
  final double sizePx; // 起始半径
  final double turbulence; // 扰动幅度（相对起始半径）
  final double opacity;
  final String color;

  Map<String, dynamic> toJson() => {
        'puffs': puffs,
        'riseCycles': riseCycles,
        'sizePx': sizePx,
        'turbulence': turbulence,
        'opacity': opacity,
        'color': color,
      };

  static SmokeParams fromJson(Map<String, dynamic> j) => SmokeParams(
        puffs: (j['puffs'] as num?)?.toInt() ?? 16,
        riseCycles: (j['riseCycles'] as num?)?.toInt() ?? 1,
        sizePx: (j['sizePx'] as num?)?.toDouble() ?? 26.0,
        turbulence: (j['turbulence'] as num?)?.toDouble() ?? 0.35,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.14,
        color: _normHex(j['color'] as String?) ?? 'c9ccd4',
      );
}

/// 气泡：描边圆环 + 内部弱填充 + 左上高光，边升边左右摆。
class BubblesParams {
  const BubblesParams({
    this.count = 18,
    this.riseCycles = 1,
    this.sizePx = 6.5,
    this.wobblePx = 10.0,
    this.opacity = 0.5,
    this.color = 'dff2ff',
  });

  final int count;
  final int riseCycles; // 每循环上升轮数（整数 → 无缝）
  final double sizePx; // 半径
  final double wobblePx; // 横向摆动幅度
  final double opacity;
  final String color;

  Map<String, dynamic> toJson() => {
        'count': count,
        'riseCycles': riseCycles,
        'sizePx': sizePx,
        'wobblePx': wobblePx,
        'opacity': opacity,
        'color': color,
      };

  static BubblesParams fromJson(Map<String, dynamic> j) => BubblesParams(
        count: (j['count'] as num?)?.toInt() ?? 18,
        riseCycles: (j['riseCycles'] as num?)?.toInt() ?? 1,
        sizePx: (j['sizePx'] as num?)?.toDouble() ?? 6.5,
        wobblePx: (j['wobblePx'] as num?)?.toDouble() ?? 10.0,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.5,
        color: _normHex(j['color'] as String?) ?? 'dff2ff',
      );
}

/// 落叶：与樱花同族的下落骨架，把自转换成「翻面」——宽度按 |cos| 收拢，
/// 侧立的瞬间切深色，两片面因此看起来不同。
class LeavesParams {
  const LeavesParams({
    this.count = 22,
    this.fallCycles = 1,
    this.sizePx = 6.8,
    this.flipTurns = 2,
    this.swayPx = 26.0,
    this.opacity = 0.88,
    this.palette = 'autumn',
  });

  final int count;
  final int fallCycles; // 每循环下落轮数（整数 → 无缝）
  final double sizePx; // 叶长的一半
  final int flipTurns; // 每循环翻面圈数（整数 → 无缝）
  final double swayPx;
  final double opacity;
  final String palette; // autumn | spring | summer

  /// 三组色：[0] 叶面、[1] 叶背、[2] 侧立深色。
  List<int> paletteRgb() => _leafPalettes[palette] ?? _leafPalettes['autumn']!;

  Map<String, dynamic> toJson() => {
        'count': count,
        'fallCycles': fallCycles,
        'sizePx': sizePx,
        'flipTurns': flipTurns,
        'swayPx': swayPx,
        'opacity': opacity,
        'palette': palette,
      };

  static LeavesParams fromJson(Map<String, dynamic> j) {
    final pal = (j['palette'] as String?) ?? 'autumn';
    return LeavesParams(
      count: (j['count'] as num?)?.toInt() ?? 22,
      fallCycles: (j['fallCycles'] as num?)?.toInt() ?? 1,
      sizePx: (j['sizePx'] as num?)?.toDouble() ?? 6.8,
      flipTurns: (j['flipTurns'] as num?)?.toInt() ?? 2,
      swayPx: (j['swayPx'] as num?)?.toDouble() ?? 26.0,
      opacity: (j['opacity'] as num?)?.toDouble() ?? 0.88,
      palette: _leafPalettes.containsKey(pal) ? pal : 'autumn',
    );
  }
}

/// 落叶配色表：每档 3 组色（叶面 / 叶背 / 侧立深色）。
const Map<String, List<int>> _leafPalettes = {
  'autumn': [0xc1a470, 0xd98b4a, 0xa8542f],
  'spring': [0x9fc97a, 0x74ab55, 0x4c7a3a],
  'summer': [0x6fae7c, 0x4f8a5f, 0x2f5b3f],
};

/// 流星雨：与闪电同族的窗口式设计，短窗口内沿固定角度划出亮头透明尾。
class MeteorsParams {
  const MeteorsParams({
    this.count = 5,
    this.streakCycles = 2,
    // 屏幕坐标 y 轴向下，正值 = 向右下划落。
    this.angleDeg = 32.0,
    this.lengthFrac = 0.22,
    this.windowFrac = 0.18,
    this.opacity = 0.85,
  });

  final int count;
  final int streakCycles; // 每循环流星轮数（整数 → 无缝）
  final double angleDeg; // 划落方向
  final double lengthFrac; // 尾迹长度占短边比例
  final double windowFrac; // 单颗可见窗口占本轮比例
  final double opacity;

  Map<String, dynamic> toJson() => {
        'count': count,
        'streakCycles': streakCycles,
        'angleDeg': angleDeg,
        'lengthFrac': lengthFrac,
        'windowFrac': windowFrac,
        'opacity': opacity,
      };

  static MeteorsParams fromJson(Map<String, dynamic> j) => MeteorsParams(
        count: (j['count'] as num?)?.toInt() ?? 5,
        streakCycles: (j['streakCycles'] as num?)?.toInt() ?? 2,
        angleDeg: (j['angleDeg'] as num?)?.toDouble() ?? 32.0,
        lengthFrac: (j['lengthFrac'] as num?)?.toDouble() ?? 0.22,
        windowFrac: (j['windowFrac'] as num?)?.toDouble() ?? 0.18,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.85,
      );
}

/// moodScript 情绪包络：自身不绘制任何东西，只按整循环曲线缩放已有动效的
/// 振幅/浓度/曝光，并给 toneShift 与 vignette 叠加增量（见 render/envelope.dart）。
class MoodScriptParams {
  const MoodScriptParams({
    this.mood = 'tension',
    this.cycles = 1,
    this.strength = 1.0,
  });

  final String mood; // tension | calm | eerie | burst
  final int cycles; // 每条循环重复的包络轮数（整数 → 无缝）
  final double strength; // 与恒等因子的混合比：0 = 完全不调制

  Map<String, dynamic> toJson() => {
        'mood': mood,
        'cycles': cycles,
        'strength': strength,
      };

  static MoodScriptParams fromJson(Map<String, dynamic> j) => MoodScriptParams(
        mood: (j['mood'] as String?) ?? 'tension',
        cycles: (j['cycles'] as num?)?.toInt() ?? 1,
        strength: (j['strength'] as num?)?.toDouble() ?? 1.0,
      );
}

/// 渲染质量参数（v1.2 引入抖动，v1.3 引入分级，v1.4 默认档升为 standard、
/// 默认关抖动 R38）。
class QualityParams {
  const QualityParams({
    this.dither = false,
    this.ditherMode = 'sierra',
    this.tier = RenderTier.standard,
    this.mipLevels = 2,
    this.edgeStretchPx = 6,
  });

  /// 误差扩散抖动：减轻 GIF 256 色渐变色带，但把 GIF 字节乘 2.2–2.4×（高频噪声
  /// 打穿 LZW）。R34 实测 + R38 用户裁决：flat-ink + 线稿漫画语料换不来可见收益
  /// ⇒ **默认关闭**（回退最近色映射，v1.1 的量化口径）；需要平滑渐变的图显式
  /// 传 `dither: true`（或 JSON `"dither": true`）即可开回 sierra/floyd。
  final bool dither;

  /// 抖动核：sierra（v1.4 默认核，更柔和）| floyd（v1.2 行为）。仅在
  /// `dither == true` 且 standard+ 档时才是活的（R38 后默认 dither 关闭 ⇒
  /// 本键默认惰性，值保持不变）。
  final String ditherMode;

  /// 渲染档位；v1.4 起默认 standard，legacy 仍供显式选择并逐字节冻结 v1.2。
  final RenderTier tier;

  /// 层栅格预建的 mipmap 级数（1..2），供 scale<1 的面积平均取样。
  final int mipLevels;

  /// 层边缘色外扩像素（0..16），消除视差位移时的露底双边。
  final int edgeStretchPx;

  /// 省略哨兵（v1.4 裁决 R32，R38 同步 dither 一源）：全等于**当前默认**
  /// （standard/sierra/**false** + mipLevels 2 / edgeStretchPx 6）才整段不序列化。
  ///
  /// 「等于默认就不写」这个习语只有在 **省略哨兵 == 缺键兜底 == 构造默认**
  /// 三者锁步时 JSON 才是无损的。Task 3.6 的 R24 只翻了构造默认与缺键兜底、
  /// 把哨兵留在 legacy/floyd/false，于是同一份 JSON 有两种渲染行为：混档配置
  /// （如 legacy + sierra + dither）会在 legacy 哨兵处丢掉 tier，而完整的
  /// v1.2 回滚配置（legacy/floyd/false/2/6）反过来命中 isDefault ⇒ 整段不写
  /// ⇒ 一次 toJson→fromJson 就把回滚静默抹成新默认。R32 把哨兵同步到新默认，
  /// R38 又把 dither 的默认值翻回 false（四处同源一起动：构造默认、缺键兜底、
  /// 本哨兵、toJson 的逐键省略条件，外加 param_catalog 的声明值）。于是：
  /// 新默认（standard/sierra/**false**）⇒ 整段省略，默认 JSON 的键集与
  /// configHash 一字不动；v1.2 回滚（legacy/floyd/**false**/2/6）⇒ 写出
  /// `{ditherMode:'floyd', tier:'legacy'}`（dither 等于自身默认 ⇒ 该键省略，
  /// 读回靠 `?? false` 兜底复原，仍然无损）；显式开抖动 ⇒ 写出 `{dither:true}`；
  /// 混档 ⇒ 逐键「等于该键自己的默认才省略」。三条路径都往返无损（有测试门）。
  /// 默认配置的 configHash 因此仍是「不写 quality 段」的形状，绝对指纹归
  /// Task 3.7 re-baseline。
  bool get isDefault =>
      !dither &&
      ditherMode == 'sierra' &&
      tier == RenderTier.standard &&
      mipLevels == 2 &&
      edgeStretchPx == 6;

  QualityParams copyWith(
          {bool? dither,
          String? ditherMode,
          RenderTier? tier,
          int? mipLevels,
          int? edgeStretchPx}) =>
      QualityParams(
        dither: dither ?? this.dither,
        ditherMode: ditherMode ?? this.ditherMode,
        tier: tier ?? this.tier,
        mipLevels: mipLevels ?? this.mipLevels,
        edgeStretchPx: edgeStretchPx ?? this.edgeStretchPx,
      );

  /// 逐键条件序列化（R32，R38 把 dither 一并纳入逐键口径）：**每个键都
  /// 「等于自己的默认就不写」**，`dither` 也不例外——R38 后 dither 的默认是
  /// false，段内再恒写 `false` 就是「写了一个等于自身默认值的键」，与本习语
  /// 矛盾（且新 `?? false` 兜底让「缺键」就能无损读回 false）。`if (dither)`
  /// 对新兜底双向无损：显式 true ⇒ 写键，默认 false ⇒ 省键。
  /// 哨兵与 `isDefault`/`fromJson` 兜底/构造默认/param_catalog 声明五处同源，
  /// 缺一处就会静默改语义。
  Map<String, dynamic> toJson() => {
        if (dither) 'dither': true,
        if (ditherMode != 'sierra') 'ditherMode': ditherMode,
        if (tier != RenderTier.standard) 'tier': tier.name,
        if (mipLevels != 2) 'mipLevels': mipLevels,
        if (edgeStretchPx != 6) 'edgeStretchPx': edgeStretchPx,
      };

  /// 缺键兜底与构造默认**锁步**（R24），且与 `isDefault`/`toJson` 的**省略
  /// 哨兵同源**（R32）：quality-less JSON 必须解析出与 `QualityParams()`
  /// 相同的对象，而「等于默认就不写」的反向路径也必须回到同一个对象，否则
  /// 同一份 JSON 有两种渲染行为，configHash 不再标识渲染路径（哈希即身份）。
  /// 显式 `null` 与缺键同义（都表示「没说过」）⇒ 落到新默认；只有**非空的
  /// 未知名字**才走 `RenderTier.parse` 的既有 sanitise（回落 legacy，契约不动）。
  static QualityParams fromJson(Map<String, dynamic> j) => QualityParams(
        // R24 锁步 + R38 翻转：缺键兜底 == 构造默认 == false（toJson 也只在
        // true 时写键，两侧同向 ⇒ 「缺键」与「显式 false」读出同一个值）。
        dither: j['dither'] as bool? ?? false,
        // 与「非 sierra 一律 sierra」的宽容方向对称：缺失/显式 null/未知 ⇒
        // 新默认 sierra，仅显式 'floyd' 才回落 floyd。
        ditherMode: (j['ditherMode'] == 'floyd') ? 'floyd' : 'sierra',
        // 不让 RenderTier.parse(null) 悄悄兜成 legacy：缺键**与显式 null** 都
        // ⇒ 新默认 standard；非空但未知的名字仍由 parse sanitise 成 legacy。
        tier: j['tier'] == null ? RenderTier.standard : RenderTier.parse(j['tier']),
        mipLevels: ((j['mipLevels'] as num?)?.toInt() ?? 2).clamp(1, 2),
        edgeStretchPx:
            ((j['edgeStretchPx'] as num?)?.toInt() ?? 6).clamp(0, 16),
      );
}

/// GIF 编码参数（T5）。
class EncodingParams {
  const EncodingParams({this.diffMode = 'none', this.apngDelay = 'cs'});

  /// 帧间差分模式：
  /// - `none`（默认）——每帧全画布 LZW 编码（v1.3 行为，逐字节契约由该
  ///   默认值守护）；
  /// - `rect`——相邻帧比较**量化后索引图**，只编码变化矩形（首帧仍全画布，
  ///   帧 disposal 置 do-not-dispose 供解码器跨帧合成；无变化帧以 1x1 矩形
  ///   占位保住帧时序）。差分在量化后字节层面进行：dither / sierra 的误差
  ///   扩散逐帧独立、无跨帧污染，与差分正交，确定性保持。
  final String diffMode;

  /// APNG 帧延迟口径（W3，opt-in）：
  /// - `cs`（默认）——厘秒定点：delay_num = (100/fps).round()、delay_den =
  ///   100，与 GIF 同口径（v1.3 行为；60fps 会取整到 20ms = 50fps）；
  /// - `exact`——精确分数：delay_num = 1、delay_den = fps（fcTL 为 16.16
  ///   定点数，60fps 精确表达 16.67ms；仅影响 APNG 路径，GIF 不受影响）。
  final String apngDelay;

  bool get isDefault => diffMode == 'none' && apngDelay == 'cs';

  EncodingParams copyWith({String? diffMode, String? apngDelay}) =>
      EncodingParams(
          diffMode: diffMode ?? this.diffMode,
          apngDelay: apngDelay ?? this.apngDelay);

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (diffMode != 'none') 'diffMode': diffMode,
        // 条件序列化：默认 cs 不写入 → 关闭时 configHash 与旧版完全一致。
        if (apngDelay != 'cs') 'apngDelay': apngDelay,
      };

  static EncodingParams fromJson(Map<String, dynamic> j) => EncodingParams(
      diffMode: (j['diffMode'] == 'rect') ? 'rect' : 'none',
      apngDelay: (j['apngDelay'] == 'exact') ? 'exact' : 'cs');
}

class EffectConfig {
  EffectConfig({
    this.effects = const [
      EffectKind.parallax,
      EffectKind.breathing,
      EffectKind.ambient
    ],
    ParallaxParams? parallax,
    BreathingParams? breathing,
    AmbientParams? ambient,
    RainParams? rain,
    SnowParams? snow,
    SakuraParams? sakura,
    FirefliesParams? fireflies,
    GodRaysParams? godRays,
    SpeedLinesParams? speedLines,
    ImpactFlashParams? impactFlash,
    HeartbeatParams? heartbeat,
    FogParams? fog,
    EmbersParams? embers,
    LightningParams? lightning,
    ToneShiftParams? toneShift,
    VignetteParams? vignette,
    StarlightParams? starlight,
    SlowPushParams? slowPush,
    ShimmerParams? shimmer,
    FocusLinesParams? focusLines,
    ScreenToneParams? screenTone,
    MangaShakeParams? mangaShake,
    ImpactRingsParams? impactRings,
    BrushStreakParams? brushStreak,
    FlameParams? flame,
    SmokeParams? smoke,
    BubblesParams? bubbles,
    LeavesParams? leaves,
    MeteorsParams? meteors,
    MoodScriptParams? moodScript,
    QualityParams? quality,
    EncodingParams? encoding,
    this.fps = 24,
    this.durationSec = 4.0,
    this.depthMode = DepthMode.autoLayers,
    this.layerCount = 3,
    this.outputFormat = OutputFormat.both,
    this.seed = 20260914,
    this.maxDimension = 1600,
    this.maxFrames = 96,
    this.reducedMotion = false,
    // v1.4 R39（用户裁决）：分格感知默认**开启**。0/41 预设显式设置它 ⇒
    // 默认关等于出厂不可达；R34 实测它反而更快（每格层集覆盖面积更小，
    // 合成 −21%/−23%），且它是投诉 #2「效果几乎是堆叠」的结构性修复。
    // 三源锁步之一（另两处：toJson 省略哨兵 / fromJson 缺键兜底）。
    this.panelAware = true,
    this.contentAware = true,

    /// ---- R5 顶层便捷参数（null = 不触碰对应嵌套字段）----
    /// 嵌入方在一处设齐全部渲染参数；非 null 时映射到既有字段，与显式
    /// 传嵌套参数**逐字节等价**（序列化与 configHash 均相同，等价性矩阵
    /// 有测试覆盖）。v1.4 R24/R32/R38：quality 默认 standard/sierra/**dither
    /// 关闭** 且省略哨兵同源 ⇒ 默认（含 null 便捷参数）不写 quality 段，
    /// 显式 legacy 或显式 `dither: true` 才写。
    bool? dither,
    double? amplitude,
    double? directionDeg,
    RenderTier? qualityTier,
  })  : parallax = (parallax ?? ParallaxParams())
            .copyWith(amplitude: amplitude, directionDeg: directionDeg),
        breathing = breathing ?? BreathingParams(),
        ambient = ambient ?? AmbientParams(),
        rain = rain ?? RainParams(),
        snow = snow ?? SnowParams(),
        sakura = sakura ?? SakuraParams(),
        fireflies = fireflies ?? FirefliesParams(),
        godRays = godRays ?? GodRaysParams(),
        speedLines = speedLines ?? SpeedLinesParams(),
        impactFlash = impactFlash ?? ImpactFlashParams(),
        heartbeat = heartbeat ?? HeartbeatParams(),
        fog = fog ?? FogParams(),
        embers = embers ?? EmbersParams(),
        lightning = lightning ?? LightningParams(),
        toneShift = toneShift ?? ToneShiftParams(),
        vignette = vignette ?? VignetteParams(),
        starlight = starlight ?? StarlightParams(),
        slowPush = slowPush ?? SlowPushParams(),
        shimmer = shimmer ?? ShimmerParams(),
        focusLines = focusLines ?? FocusLinesParams(),
        screenTone = screenTone ?? ScreenToneParams(),
        mangaShake = mangaShake ?? MangaShakeParams(),
        impactRings = impactRings ?? ImpactRingsParams(),
        brushStreak = brushStreak ?? BrushStreakParams(),
        flame = flame ?? FlameParams(),
        smoke = smoke ?? SmokeParams(),
        bubbles = bubbles ?? BubblesParams(),
        leaves = leaves ?? LeavesParams(),
        meteors = meteors ?? MeteorsParams(),
        moodScript = moodScript ?? MoodScriptParams(),
        quality = (quality ?? QualityParams())
            .copyWith(dither: dither, tier: qualityTier),
        encoding = encoding ?? EncodingParams() {
    // Structural fail-fast (v1.3.1): these parameters define the shape of the
    // output; out-of-domain values used to fall through to per-path degenerate
    // behavior (fps=0 divides t by zero in frame rendering, maxFrames<2 breaks
    // the frameCount clamp, maxDimension<1 breaks the downscale clamp). Only
    // *illegal* values are rejected - legal domains render byte-identically,
    // so configHash stability is unaffected.
    if (fps < 1) {
      throw ConfigException('fps must be a positive integer, got $fps');
    }
    if (durationSec <= 0) {
      throw ConfigException('durationSec must be > 0, got $durationSec');
    }
    if (layerCount < 1 || layerCount > 8) {
      throw ConfigException('layerCount must be in [1, 8], got $layerCount');
    }
    if (maxDimension < 1) {
      throw ConfigException('maxDimension must be >= 1, got $maxDimension');
    }
    if (maxFrames < 2) {
      throw ConfigException(
          'maxFrames must be >= 2 (frameCount clamps to [2, maxFrames]), '
          'got $maxFrames');
    }
  }

  List<EffectKind> effects;
  ParallaxParams parallax;
  BreathingParams breathing;
  AmbientParams ambient;
  RainParams rain;
  SnowParams snow;
  SakuraParams sakura;
  FirefliesParams fireflies;
  GodRaysParams godRays;
  SpeedLinesParams speedLines;
  ImpactFlashParams impactFlash;
  HeartbeatParams heartbeat;
  FogParams fog;
  EmbersParams embers;
  LightningParams lightning;
  ToneShiftParams toneShift;
  VignetteParams vignette;
  StarlightParams starlight;
  SlowPushParams slowPush;
  ShimmerParams shimmer;
  FocusLinesParams focusLines;
  ScreenToneParams screenTone;
  MangaShakeParams mangaShake;
  ImpactRingsParams impactRings;
  BrushStreakParams brushStreak;
  FlameParams flame;
  SmokeParams smoke;
  BubblesParams bubbles;
  LeavesParams leaves;
  MeteorsParams meteors;

  /// 情绪包络（v1.3）：仅当 `effects` 含 moodScript 时生效并序列化。
  MoodScriptParams moodScript;

  /// 渲染质量（v1.2 引入 GIF 抖动）。v1.4 起默认 ditherMode=sierra +
  /// tier=standard（R24），但 **dither 默认关闭**（R38：误差扩散把 GIF 字节
  /// 乘 2.2–2.4×，对 flat-ink + 线稿语料不值；锐度来自 standard 档而非抖动）。
  /// JSON 缺键兜底与省略哨兵、toJson 逐键省略、param_catalog 声明值同源（R32/R38）；
  /// 「与 v1.2 逐字节一致」的 legacy 档仍需**显式**选择（`tier: legacy` /
  /// JSON `"tier":"legacy"`），且显式写出后能无损往返。
  QualityParams quality;

  /// GIF 编码参数（帧间差分）。条件序列化：默认 `none` 时整段不出现，
  /// 既有配置的 configHash 不受影响。
  EncodingParams encoding;

  final int fps;
  final double durationSec;
  final DepthMode depthMode;
  final int layerCount;
  final OutputFormat outputFormat;
  final int seed;
  final int maxDimension; // downscale working resolution
  final int maxFrames; // hard frame-count guard

  /// 减弱动态降级：true 时输出单帧静态图（关闭全部动效，内容完整）。
  bool reducedMotion;

  /// 分格感知分层（W5，opt-in）：true 时先做横向白带分格检测，多格图
  /// 逐格独立估算深度与分层、层以格边界裁剪（根除启发式深度跨格错位
  /// 与串色）；单格/无白带图自动回退整页分层（结果与 false 等价）。
  /// 条件序列化：默认 false 不写入 → configHash 与旧版完全一致。
  final bool panelAware;

  /// 内容感知布局（v1.4 placement）：true 时管线对底图跑一次
  /// `SaliencyAnalyzer`，把得到的 AnchorMap 贯通进合成器与 worker 作业
  /// （`FrameCompositor.anchors` / `FrameJobSpec.anchors`），由落位任务消费
  /// （Task 2.1 focusLines/impactRings 焦点、2.2 粒子 activity 加权播种、
  /// 2.3 分格裁剪）。**v1.4 Task 3.6b（R30/R36）起默认 true** ——内容感知
  /// 落位开箱即活，显式 `contentAware: false` 是回滚开关；R36 裁决落位与
  /// RenderTier 正交，门控只看本字段。
  /// 条件序列化（R32 习语）：等于默认 true 不写入 ⇒ 默认 JSON 键集与旧版
  /// 逐字节相同；显式 false 写出键 ⇒ 回滚意图无损往返。
  final bool contentAware;

  int get frameCount =>
      reducedMotion ? 1 : (fps * durationSec).round().clamp(2, maxFrames);

  String get version => 'v1';

  /// 配置层面的可见告警（写进台账，不参与 configHash）。
  /// 目前只有 moodScript 的未知 mood 回落会报：效果参数越界在取样处静默 clamp；
  /// 结构性参数（fps/durationSec/layerCount 等）已在构造时 fail-fast 校验。
  List<String> get warnings {
    if (!effects.contains(EffectKind.moodScript)) return const [];
    final m = moodScript.mood.trim().toLowerCase();
    if (MotionEnvelope.knownMoods.contains(m)) return const [];
    return ['moodScript: 未知 mood "${moodScript.mood}"，已回落 calm'];
  }

  Map<String, dynamic> toJson() => {
        'configVersion': version,
        'effects': effects.map((e) => e.name).toList(),
        'parallax': parallax.toJson(),
        'breathing': breathing.toJson(),
        'ambient': ambient.toJson(),
        // v1.1 新效果：仅在启用时序列化，保证经典配置哈希逐字节不变（回滚兼容）。
        if (effects.contains(EffectKind.rain)) 'rain': rain.toJson(),
        if (effects.contains(EffectKind.snow)) 'snow': snow.toJson(),
        if (effects.contains(EffectKind.sakura)) 'sakura': sakura.toJson(),
        if (effects.contains(EffectKind.fireflies))
          'fireflies': fireflies.toJson(),
        if (effects.contains(EffectKind.godRays)) 'godRays': godRays.toJson(),
        if (effects.contains(EffectKind.speedLines))
          'speedLines': speedLines.toJson(),
        if (effects.contains(EffectKind.impactFlash))
          'impactFlash': impactFlash.toJson(),
        if (effects.contains(EffectKind.heartbeat))
          'heartbeat': heartbeat.toJson(),
        if (effects.contains(EffectKind.fog)) 'fog': fog.toJson(),
        if (effects.contains(EffectKind.embers)) 'embers': embers.toJson(),
        if (effects.contains(EffectKind.lightning))
          'lightning': lightning.toJson(),
        if (effects.contains(EffectKind.toneShift))
          'toneShift': toneShift.toJson(),
        if (effects.contains(EffectKind.vignette))
          'vignette': vignette.toJson(),
        if (effects.contains(EffectKind.starlight))
          'starlight': starlight.toJson(),
        if (effects.contains(EffectKind.slowPush))
          'slowPush': slowPush.toJson(),
        if (effects.contains(EffectKind.shimmer)) 'shimmer': shimmer.toJson(),
        // v1.3 新效果：同样只在启用时序列化
        if (effects.contains(EffectKind.focusLines))
          'focusLines': focusLines.toJson(),
        if (effects.contains(EffectKind.screenTone))
          'screenTone': screenTone.toJson(),
        if (effects.contains(EffectKind.mangaShake))
          'mangaShake': mangaShake.toJson(),
        if (effects.contains(EffectKind.impactRings))
          'impactRings': impactRings.toJson(),
        if (effects.contains(EffectKind.brushStreak))
          'brushStreak': brushStreak.toJson(),
        if (effects.contains(EffectKind.flame)) 'flame': flame.toJson(),
        if (effects.contains(EffectKind.smoke)) 'smoke': smoke.toJson(),
        if (effects.contains(EffectKind.bubbles)) 'bubbles': bubbles.toJson(),
        if (effects.contains(EffectKind.leaves)) 'leaves': leaves.toJson(),
        if (effects.contains(EffectKind.meteors)) 'meteors': meteors.toJson(),
        if (effects.contains(EffectKind.moodScript))
          'moodScript': moodScript.toJson(),
        // v1.4 R32/R38：quality 段等于**当前默认**（standard/sierra/false/2/6）时
        // 整段省略，v1.2 回滚配置与任何混档配置逐键写出（等于自身默认的键省略）
        // ⇒ 往返无损。
        if (!quality.isDefault) 'quality': quality.toJson(),
        if (!encoding.isDefault) 'encoding': encoding.toJson(),
        'fps': fps,
        'durationSec': durationSec,
        'depthMode': depthMode.name,
        'layerCount': layerCount,
        'outputFormat': outputFormat.name,
        'seed': seed,
        'maxDimension': maxDimension,
        'maxFrames': maxFrames,
        if (reducedMotion) 'reducedMotion': true,
        // R39 翻转（习语同 R32 / 3.6b / 3.6e）：省略条件必须等于
        // 「== 构造默认(true)」——默认不写键（默认 JSON 键集逐字节不动、
        // configHash 不移动），显式回滚 false 才写出键。旧写法
        // `if (panelAware) 'panelAware': true` 在新默认下会把回滚意图省略掉，
        // 缺键兜底成 true ⇒ 一次 toJson→fromJson 静默改写用户配置（哈希即身份）。
        if (!panelAware) 'panelAware': false,
        // R32 习语 + 3.6b 翻转：省略条件必须等于「== 构造默认(true)」，
        // 默认不写键（默认 JSON 键集逐字节不动），显式回滚 false 写出键。
        if (!contentAware) 'contentAware': false,
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// CLI override helper (mutates nested param objects in place).
  void applyOverrides({double? amplitude, double? directionDeg}) {
    if (amplitude != null) {
      parallax = ParallaxParams(
        amplitude: amplitude,
        periodSec: parallax.periodSec,
        directionDeg: parallax.directionDeg,
        verticalRatio: parallax.verticalRatio,
      );
    }
    if (directionDeg != null) {
      parallax = ParallaxParams(
        amplitude: parallax.amplitude,
        periodSec: parallax.periodSec,
        directionDeg: directionDeg,
        verticalRatio: parallax.verticalRatio,
      );
    }
  }

  /// ---- R5 渲染效果选择 API（不可变语义）----
  /// 全部返回**新实例**，原 config 绝不修改（`effects` 列表为全新列表）。
  /// 参数对象与原实例共享引用——与既有可变性模型一致；`configHash` 只依赖
  /// 序列化内容，效果增删后与「直接用同名单构造」完全一致。

  /// 复制配置：字段逐一传入构造器（全部已通过校验，不会重抛）。
  EffectConfig copy() => EffectConfig(
        effects: List<EffectKind>.from(effects),
        parallax: parallax,
        breathing: breathing,
        ambient: ambient,
        rain: rain,
        snow: snow,
        sakura: sakura,
        fireflies: fireflies,
        godRays: godRays,
        speedLines: speedLines,
        impactFlash: impactFlash,
        heartbeat: heartbeat,
        fog: fog,
        embers: embers,
        lightning: lightning,
        toneShift: toneShift,
        vignette: vignette,
        starlight: starlight,
        slowPush: slowPush,
        shimmer: shimmer,
        focusLines: focusLines,
        screenTone: screenTone,
        mangaShake: mangaShake,
        impactRings: impactRings,
        brushStreak: brushStreak,
        flame: flame,
        smoke: smoke,
        bubbles: bubbles,
        leaves: leaves,
        meteors: meteors,
        moodScript: moodScript,
        quality: quality,
        fps: fps,
        durationSec: durationSec,
        depthMode: depthMode,
        layerCount: layerCount,
        outputFormat: outputFormat,
        seed: seed,
        maxDimension: maxDimension,
        maxFrames: maxFrames,
        reducedMotion: reducedMotion,
        panelAware: panelAware,
        contentAware: contentAware,
      );

  /// 启用一个效果（已启用则为无变化的等价新实例）。
  EffectConfig withEffect(EffectKind kind) {
    final c = copy();
    if (!c.effects.contains(kind)) c.effects = [...c.effects, kind];
    return c;
  }

  /// 关闭一个效果（未启用则为无变化的等价新实例）。
  EffectConfig withoutEffect(EffectKind kind) {
    final c = copy();
    c.effects = c.effects.where((e) => e != kind).toList();
    return c;
  }

  /// 全量替换效果列表（不去重，按传入顺序）。
  EffectConfig withEffects(List<EffectKind> kinds) {
    final c = copy();
    c.effects = List<EffectKind>.from(kinds);
    return c;
  }

  /// 全关效果（= 静帧）。
  EffectConfig clearEffects() {
    final c = copy();
    c.effects = const [];
    return c;
  }

  /// SHA-like stable hash (FNV-1a 64) over canonical JSON of the config.
  String get configHash {
    final canonical = const JsonEncoder().convert(toJson());
    var hash = 0xcbf29ce484222325;
    for (final c in canonical.codeUnits) {
      hash ^= c & 0xff;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
      hash ^= c >> 8;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static EffectConfig fromJson(Map<String, dynamic> j) {
    final effects = ((j['effects'] as List?) ??
            const ['parallax', 'breathing', 'ambient'])
        .map((e) => effectKindFromName(e))
        .toList();
    var depthMode = DepthMode.autoLayers;
    if (j['depthMode'] != null) {
      depthMode = DepthMode.values.firstWhere((d) => d.name == j['depthMode']);
    }
    var outputFormat = OutputFormat.both;
    if (j['outputFormat'] != null) {
      outputFormat =
          OutputFormat.values.firstWhere((f) => f.name == j['outputFormat']);
    }
    return EffectConfig(
      effects: effects,
      parallax: j['parallax'] == null
          ? null
          : ParallaxParams.fromJson(
              (j['parallax'] as Map).cast<String, dynamic>()),
      breathing: j['breathing'] == null
          ? null
          : BreathingParams.fromJson(
              (j['breathing'] as Map).cast<String, dynamic>()),
      ambient: j['ambient'] == null
          ? null
          : AmbientParams.fromJson(
              (j['ambient'] as Map).cast<String, dynamic>()),
      rain: j['rain'] == null
          ? null
          : RainParams.fromJson((j['rain'] as Map).cast<String, dynamic>()),
      snow: j['snow'] == null
          ? null
          : SnowParams.fromJson((j['snow'] as Map).cast<String, dynamic>()),
      sakura: j['sakura'] == null
          ? null
          : SakuraParams.fromJson((j['sakura'] as Map).cast<String, dynamic>()),
      fireflies: j['fireflies'] == null
          ? null
          : FirefliesParams.fromJson(
              (j['fireflies'] as Map).cast<String, dynamic>()),
      godRays: j['godRays'] == null
          ? null
          : GodRaysParams.fromJson(
              (j['godRays'] as Map).cast<String, dynamic>()),
      speedLines: j['speedLines'] == null
          ? null
          : SpeedLinesParams.fromJson(
              (j['speedLines'] as Map).cast<String, dynamic>()),
      impactFlash: j['impactFlash'] == null
          ? null
          : ImpactFlashParams.fromJson(
              (j['impactFlash'] as Map).cast<String, dynamic>()),
      heartbeat: j['heartbeat'] == null
          ? null
          : HeartbeatParams.fromJson(
              (j['heartbeat'] as Map).cast<String, dynamic>()),
      fog: j['fog'] == null
          ? null
          : FogParams.fromJson((j['fog'] as Map).cast<String, dynamic>()),
      embers: j['embers'] == null
          ? null
          : EmbersParams.fromJson((j['embers'] as Map).cast<String, dynamic>()),
      lightning: j['lightning'] == null
          ? null
          : LightningParams.fromJson(
              (j['lightning'] as Map).cast<String, dynamic>()),
      toneShift: j['toneShift'] == null
          ? null
          : ToneShiftParams.fromJson(
              (j['toneShift'] as Map).cast<String, dynamic>()),
      vignette: j['vignette'] == null
          ? null
          : VignetteParams.fromJson(
              (j['vignette'] as Map).cast<String, dynamic>()),
      starlight: j['starlight'] == null
          ? null
          : StarlightParams.fromJson(
              (j['starlight'] as Map).cast<String, dynamic>()),
      slowPush: j['slowPush'] == null
          ? null
          : SlowPushParams.fromJson(
              (j['slowPush'] as Map).cast<String, dynamic>()),
      shimmer: j['shimmer'] == null
          ? null
          : ShimmerParams.fromJson(
              (j['shimmer'] as Map).cast<String, dynamic>()),
      focusLines: j['focusLines'] == null
          ? null
          : FocusLinesParams.fromJson(
              (j['focusLines'] as Map).cast<String, dynamic>()),
      screenTone: j['screenTone'] == null
          ? null
          : ScreenToneParams.fromJson(
              (j['screenTone'] as Map).cast<String, dynamic>()),
      mangaShake: j['mangaShake'] == null
          ? null
          : MangaShakeParams.fromJson(
              (j['mangaShake'] as Map).cast<String, dynamic>()),
      impactRings: j['impactRings'] == null
          ? null
          : ImpactRingsParams.fromJson(
              (j['impactRings'] as Map).cast<String, dynamic>()),
      brushStreak: j['brushStreak'] == null
          ? null
          : BrushStreakParams.fromJson(
              (j['brushStreak'] as Map).cast<String, dynamic>()),
      flame: j['flame'] == null
          ? null
          : FlameParams.fromJson((j['flame'] as Map).cast<String, dynamic>()),
      smoke: j['smoke'] == null
          ? null
          : SmokeParams.fromJson((j['smoke'] as Map).cast<String, dynamic>()),
      bubbles: j['bubbles'] == null
          ? null
          : BubblesParams.fromJson(
              (j['bubbles'] as Map).cast<String, dynamic>()),
      leaves: j['leaves'] == null
          ? null
          : LeavesParams.fromJson((j['leaves'] as Map).cast<String, dynamic>()),
      meteors: j['meteors'] == null
          ? null
          : MeteorsParams.fromJson(
              (j['meteors'] as Map).cast<String, dynamic>()),
      moodScript: j['moodScript'] == null
          ? null
          : MoodScriptParams.fromJson(
              (j['moodScript'] as Map).cast<String, dynamic>()),
      quality: j['quality'] == null
          ? null
          : QualityParams.fromJson(
              (j['quality'] as Map).cast<String, dynamic>()),
      encoding: j['encoding'] == null
          ? null
          : EncodingParams.fromJson(
              (j['encoding'] as Map).cast<String, dynamic>()),
      fps: (j['fps'] as num?)?.toInt() ?? 24,
      durationSec: (j['durationSec'] as num?)?.toDouble() ?? 4.0,
      depthMode: depthMode,
      layerCount: (j['layerCount'] as num?)?.toInt() ?? 3,
      outputFormat: outputFormat,
      seed: (j['seed'] as num?)?.toInt() ?? 20260914,
      maxDimension: (j['maxDimension'] as num?)?.toInt() ?? 1600,
      maxFrames: (j['maxFrames'] as num?)?.toInt() ?? 96,
      reducedMotion: j['reducedMotion'] == true,
      // R39（三源锁步第三源，写法与下面 contentAware 逐字同构）：缺键与显式
      // null 都是「没说说过」⇒ 落新默认 true；显式 false 与非 bool 值仍
      // sanitize 成 false——sanitize **方向**与翻转前一致（旧 `== true` 一直把
      // 非 bool 折成 false），本次只翻默认值。写成 `!= false` 会让 'yes' / 1
      // 静默变成「要求开启」，那是把垃圾输入当授权。
      panelAware: j['panelAware'] == null ? true : j['panelAware'] == true,
      // 3.6b：缺键与显式 null 都落新默认 true（= 构造默认 = 省略哨兵，三源
      // 锁步）；显式 false 与非 bool 值仍 sanitize 成 false（兜底方向翻转、
      // sanitize 语义不变）。
      contentAware:
          j['contentAware'] == null ? true : j['contentAware'] == true,
    );
  }
}

/// Invalid effect configuration with a machine-readable [code] so callers
/// can branch programmatically. Codes align with the HTTP API error-code
/// table: `E_BAD_CONFIG` for malformed fields/files,
/// `E_UNKNOWN_EFFECT` for unrecognized effect names.
class ConfigException implements Exception {
  ConfigException(this.message, {this.code = 'E_BAD_CONFIG'});

  /// Human-readable English reason.
  final String message;

  /// Stable error code, e.g. `E_BAD_CONFIG` or `E_UNKNOWN_EFFECT`.
  final String code;

  @override
  String toString() => 'ConfigException [$code]: $message';
}
