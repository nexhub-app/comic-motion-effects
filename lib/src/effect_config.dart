/// Effect parameter configuration. Fully JSON-serializable, versioned and
/// hashed so the same parameters always reproduce the same output.
library;

import 'dart:convert';
import 'dart:io';

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
}

enum DepthMode { autoLayers, singleLayer }

enum OutputFormat { gif, frames, both }

class ParallaxParams {
  const ParallaxParams({
    this.amplitude = 0.012,
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
        amplitude: (j['amplitude'] as num?)?.toDouble() ?? 0.012,
        periodSec: (j['periodSec'] as num?)?.toDouble() ?? 6.0,
        directionDeg: (j['directionDeg'] as num?)?.toDouble() ?? 0.0,
        verticalRatio: (j['verticalRatio'] as num?)?.toDouble() ?? 0.35,
      );
}

class BreathingParams {
  const BreathingParams({
    this.enabled = true,
    this.amplitude = 0.006,
    this.periodSec = 4.0,
    this.anchor = 'center',
  });

  final bool enabled;
  final double amplitude; // max scale deviation (e.g. 0.006 => 1.006 zoom)
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
        amplitude: (j['amplitude'] as num?)?.toDouble() ?? 0.006,
        periodSec: (j['periodSec'] as num?)?.toDouble() ?? 4.0,
        anchor: (j['anchor'] as String?) ?? 'center',
      );
}

class AmbientParams {
  const AmbientParams({
    this.enabled = true,
    this.particleCount = 40,
    this.speed = 12.0,
    this.opacity = 0.16,
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
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0.16,
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
    this.intensity = 0.01,
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
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.01,
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

  static LightningParams fromJson(Map<String, dynamic> j) =>
      LightningParams(
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
    this.pushFrac = 0.035,
    this.cycles = 1,
  });

  final double pushFrac; // 每循环推近比例（0.005-0.08）
  final int cycles; // ≥1（整数次往返保证无缝；1=单向推近需配往返）

  Map<String, dynamic> toJson() => {
        'pushFrac': pushFrac,
        'cycles': cycles,
      };

  static SlowPushParams fromJson(Map<String, dynamic> j) => SlowPushParams(
        pushFrac: (j['pushFrac'] as num?)?.toDouble() ?? 0.035,
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

/// 渲染质量参数（v1.2）。
class QualityParams {
  const QualityParams({this.dither = false});

  /// Floyd–Steinberg 误差扩散抖动：显著减轻 GIF 256 色渐变色带。
  /// 关闭后回退到最近色映射（v1.1 行为）。
  final bool dither;

  Map<String, dynamic> toJson() => {'dither': dither};

  static QualityParams fromJson(Map<String, dynamic> j) => QualityParams(
        dither: j['dither'] as bool? ?? true,
      );
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
    QualityParams? quality,
    this.fps = 24,
    this.durationSec = 4.0,
    this.depthMode = DepthMode.autoLayers,
    this.layerCount = 3,
    this.outputFormat = OutputFormat.both,
    this.seed = 20260914,
    this.maxDimension = 1600,
    this.maxFrames = 96,
    this.reducedMotion = false,
  })  : parallax = parallax ?? ParallaxParams(),
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
        quality = quality ?? QualityParams();

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

  /// 渲染质量（v1.2：GIF 抖动等）。默认 dither=true。
  QualityParams quality;

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

  int get frameCount =>
      reducedMotion ? 1 : (fps * durationSec).round().clamp(2, maxFrames);

  String get version => 'v1';

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
        // v1.2 质量段：仅在 dither=true（非默认）时序列化，保经典指纹不变
        if (quality.dither) 'quality': quality.toJson(),
        'fps': fps,
        'durationSec': durationSec,
        'depthMode': depthMode.name,
        'layerCount': layerCount,
        'outputFormat': outputFormat.name,
        'seed': seed,
        'maxDimension': maxDimension,
        'maxFrames': maxFrames,
        if (reducedMotion) 'reducedMotion': true,
      };

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

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
    final effects = ((j['effects'] as List?) ?? const ['parallax', 'breathing', 'ambient'])
        .map((e) => EffectKind.values
            .firstWhere((k) => k.name == e, orElse: () => EffectKind.parallax))
        .toList();
    var depthMode = DepthMode.autoLayers;
    if (j['depthMode'] != null) {
      depthMode =
          DepthMode.values.firstWhere((d) => d.name == j['depthMode']);
    }
    var outputFormat = OutputFormat.both;
    if (j['outputFormat'] != null) {
      outputFormat = OutputFormat.values
          .firstWhere((f) => f.name == j['outputFormat']);
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
          : SakuraParams.fromJson(
              (j['sakura'] as Map).cast<String, dynamic>()),
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
          : EmbersParams.fromJson(
              (j['embers'] as Map).cast<String, dynamic>()),
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
      quality: j['quality'] == null
          ? null
          : QualityParams.fromJson(
              (j['quality'] as Map).cast<String, dynamic>()),
      fps: (j['fps'] as num?)?.toInt() ?? 24,
      durationSec: (j['durationSec'] as num?)?.toDouble() ?? 4.0,
      depthMode: depthMode,
      layerCount: (j['layerCount'] as num?)?.toInt() ?? 3,
      outputFormat: outputFormat,
      seed: (j['seed'] as num?)?.toInt() ?? 20260914,
      maxDimension: (j['maxDimension'] as num?)?.toInt() ?? 1600,
      maxFrames: (j['maxFrames'] as num?)?.toInt() ?? 96,
      reducedMotion: j['reducedMotion'] == true,
    );
  }

  /// Load from a JSON file (throws [ConfigException] on bad files).
  static EffectConfig fromFile(String path) {
    try {
      final raw = File(path).readAsStringSync();
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FileSystemException catch (e) {
      throw ConfigException('无法读取配置文件: ${e.message}');
    } on FormatException catch (e) {
      throw ConfigException('配置文件不是合法 JSON: ${e.message}');
    } on TypeError {
      throw ConfigException('配置字段类型不正确，请参照 docs/api.md 的参数表');
    }
  }
}

class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;

  @override
  String toString() => 'ConfigException: $message';
}
