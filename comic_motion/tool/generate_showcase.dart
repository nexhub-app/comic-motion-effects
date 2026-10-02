import 'dart:convert';
import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// v1.1~v1.3 动效演示集生成器：单效 + 组合，一图一目录。
/// 输出：DELIVERY/effect_showcase/<key>/{anim.gif, frame_0000.png}
/// 同时写出 presets/*.json（经典/单效/组合预设，供 --config 使用）。
/// 注意：classic.json 是**引擎默认值的快照**（跟随 Dart 默认漂移），
/// 不是历史版本回滚件——见 _writePresets 的说明。
///
/// 第五轮 W2 追加预览产物：每个 demo 一张首帧 PNG + 一个低配短循环 GIF
/// （360p / 8fps / 1.5s，体积目标 <300KB/个）进 `doc/previews/<key>/`，
/// 并汇总 `doc/previews/index.json`（效果名 → 路径 → 分类，App 面板按
/// 目录自动配图）。生成是确定性的：同 seed 同 config → 同产物字节。
///
/// 运行：dart run tool/generate_showcase.dart            # 全量
///       dart run tool/generate_showcase.dart --previews-only
///       dart run tool/generate_showcase.dart --presets-only
Future<void> main(List<String> args) async {
  final previewsOnly = args.contains('--previews-only');
  final presetsOnly = args.contains('--presets-only');
  // 两个 mode 各表示「只跑这一段」，互斥。同时给出时不再让某一个静默胜出
  // （旧的位置参数写法就是 --previews-only 先判先赢、presets 被无声忽略），
  // 而是报错退出：调用方需要的是「我的参数写错了」这条信息。
  if (previewsOnly && presetsOnly) {
    stderr.writeln('error: --previews-only 与 --presets-only 互斥，只能给一个');
    exitCode = 64; // EX_USAGE
    return;
  }
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final outRoot =
      positional.isNotEmpty ? positional[0] : 'DELIVERY/effect_showcase';
  final presetDir = positional.length > 1 ? positional[1] : 'presets';

  await _runShowcase(outRoot, presetDir,
      previewsOnly: previewsOnly, presetsOnly: presetsOnly);
}

Future<void> _runShowcase(String outRoot, String presetDir,
    {bool previewsOnly = false, bool presetsOnly = false}) async {
  if (!presetsOnly) {
    final root = Directory(outRoot)..createSync(recursive: true);
    // 只清「带 anim.gif 的演示目录」：图鉴 HTML 与启动脚本是手工资产，
    // 生成器无权抹掉（v1.3 之前是整树 delete，重新生成一次就丢一次 HTML）。
    for (final d in root.listSync().whereType<Directory>()) {
      if (File('${d.path}/anim.gif').existsSync()) {
        d.deleteSync(recursive: true);
      }
    }
  }
  Directory(presetDir).createSync(recursive: true);

  final demos = <String, EffectConfig Function()>{
    // ---- 8 个单效（底座 = 视差+呼吸，突出该效果本身）----
    'rain_night_city': () => EffectConfig(
          effects: [EffectKind.parallax, EffectKind.breathing, EffectKind.rain],
          rain: RainParams(count: 110, angleDeg: 14, opacity: 0.42),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'snow_landscape': () => EffectConfig(
          effects: [EffectKind.parallax, EffectKind.breathing, EffectKind.snow],
          snow: SnowParams(count: 72, swayPx: 18),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'sakura_portrait': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.sakura
          ],
          sakura: SakuraParams(count: 34, spinTurns: 2),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'fireflies_forest': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.fireflies
          ],
          fireflies: FirefliesParams(count: 26, glowPx: 15, blinkCycles: 3),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'godrays_forest': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.godRays
          ],
          godRays: GodRaysParams(count: 3, angleDeg: 22, intensity: 0.32),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'speedlines_action': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.speedLines
          ],
          speedLines: SpeedLinesParams(count: 54, intensity: 0.55, pulses: 4),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'impact_duel': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.impactFlash
          ],
          impactFlash: ImpactFlashParams(flashes: 3, intensity: 0.55),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'heartbeat_closeup': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.heartbeat
          ],
          heartbeat: HeartbeatParams(beats: 3, intensity: 0.022),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    // ---- 3 个组合 ----
    'combo_rain_lanterns': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.rain,
            EffectKind.fireflies,
            EffectKind.heartbeat
          ],
          rain: RainParams(count: 80, opacity: 0.36),
          fireflies: FirefliesParams(count: 18, glowPx: 13),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'combo_sakura_light': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.sakura,
            EffectKind.godRays
          ],
          sakura: SakuraParams(count: 26),
          godRays: GodRaysParams(count: 3, intensity: 0.26),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'combo_full_action': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.speedLines,
            EffectKind.impactFlash,
            EffectKind.heartbeat
          ],
          speedLines: SpeedLinesParams(count: 60, intensity: 0.6),
          impactFlash: ImpactFlashParams(flashes: 4, intensity: 0.5),
          heartbeat: HeartbeatParams(beats: 4, intensity: 0.024),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    // ---- v1.2：8 单效 + 2 组合 + 1 抖动对比 ----
    'fog_landscape': () => EffectConfig(
          effects: [EffectKind.parallax, EffectKind.breathing, EffectKind.fog],
          fog: FogParams(blobs: 9, opacity: 0.11),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'embers_night_city': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.embers
          ],
          embers: EmbersParams(count: 44, glowPx: 6),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'lightning_night_city': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.lightning
          ],
          lightning: LightningParams(strikes: 2, flashIntensity: 0.5),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'toneshift_landscape': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.toneShift
          ],
          toneShift: ToneShiftParams(shift: 0.06),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'vignette_closeup': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.vignette
          ],
          vignette: VignetteParams(strength: 0.34),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'starlight_night_city': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.starlight
          ],
          starlight: StarlightParams(count: 14, intensity: 0.75),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'slowpush_portrait': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.slowPush
          ],
          slowPush: SlowPushParams(pushFrac: 0.051),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'shimmer_landscape': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.shimmer
          ],
          shimmer: ShimmerParams(rows: 9, intensity: 0.22),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'combo_storm_night': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.fog,
            EffectKind.lightning,
            EffectKind.vignette
          ],
          fog: FogParams(blobs: 6, opacity: 0.08),
          lightning: LightningParams(strikes: 3, flashIntensity: 0.5),
          vignette: VignetteParams(strength: 0.3),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'combo_campfire': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.embers,
            EffectKind.vignette,
            EffectKind.toneShift
          ],
          embers: EmbersParams(count: 36),
          toneShift: ToneShiftParams(shift: 0.045),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'dither_compare_forest': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.fireflies
          ],
          fireflies: FirefliesParams(count: 24),
          quality: QualityParams(dither: true),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    // ---- v1.3 漫画动势语言：5 单效 ----
    'focus_lines_action': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.focusLines
          ],
          parallax: ParallaxParams(amplitude: 0.030, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.012, periodSec: 3),
          focusLines: FocusLinesParams(
              lines: 34,
              innerFrac: 0.22,
              wedgeDeg: 2.6,
              opacity: 0.38,
              mode: 'black'),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'screen_tone_closeup': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.screenTone
          ],
          parallax: ParallaxParams(amplitude: 0.025, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.010, periodSec: 3),
          screenTone: ScreenToneParams(
              spacingPx: 7,
              density: 0.38,
              angleDeg: 30,
              opacity: 0.18,
              mode: 'dot'),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'impact_burst': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.impactRings,
            EffectKind.impactFlash
          ],
          parallax: ParallaxParams(amplitude: 0.035, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.014, periodSec: 3),
          impactRings: ImpactRingsParams(
              rings: 4,
              outerFrac: 0.6,
              thicknessPx: 4,
              opacity: 0.55,
              mode: 'shock'),
          impactFlash:
              ImpactFlashParams(flashes: 2, dutyFrac: 0.08, intensity: 0.45),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'brush_streak_run': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.brushStreak
          ],
          parallax:
              ParallaxParams(amplitude: 0.040, periodSec: 3, directionDeg: 12),
          breathing: BreathingParams(amplitude: 0.012, periodSec: 3),
          brushStreak: BrushStreakParams(
              streaks: 14,
              lengthFrac: 0.48,
              thicknessPx: 8,
              angleDeg: 8,
              pulses: 2,
              gapFreq: 0.12,
              opacity: 0.42),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'manga_shake_impact': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.mangaShake
          ],
          parallax: ParallaxParams(amplitude: 0.035, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.014, periodSec: 3),
          mangaShake: MangaShakeParams(
              shakes: 5, amplitude: 0.027, decay: 0.7, rotJitDeg: 0.15),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    // ---- v1.3 自然氛围：5 单效 ----
    'flame_campfire': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.flame
          ],
          parallax: ParallaxParams(amplitude: 0.030, periodSec: 3),
          breathing:
              BreathingParams(amplitude: 0.012, periodSec: 3, anchor: 'bottom'),
          flame: FlameParams(
              tongues: 16, heightFrac: 0.22, flickerCycles: 6, opacity: 0.78),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'smoke_indoor': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.smoke
          ],
          parallax: ParallaxParams(amplitude: 0.025, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.010, periodSec: 3),
          smoke: SmokeParams(
              puffs: 14, sizePx: 40, turbulence: 0.4, opacity: 0.16),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'bubbles_underwater': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.bubbles
          ],
          parallax: ParallaxParams(
              amplitude: 0.030, periodSec: 3, verticalRatio: 0.45),
          breathing: BreathingParams(amplitude: 0.012, periodSec: 3),
          bubbles:
              BubblesParams(count: 24, sizePx: 9, wobblePx: 16, opacity: 0.55),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'leaves_autumn': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.leaves
          ],
          parallax:
              ParallaxParams(amplitude: 0.030, periodSec: 3, directionDeg: 8),
          breathing: BreathingParams(amplitude: 0.010, periodSec: 3),
          leaves: LeavesParams(
              count: 26,
              sizePx: 13,
              swayPx: 32,
              opacity: 0.9,
              palette: 'autumn'),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'meteors_night': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.meteors
          ],
          parallax: ParallaxParams(amplitude: 0.025, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.010, periodSec: 3),
          meteors: MeteorsParams(
              count: 6,
              streakCycles: 2,
              lengthFrac: 0.24,
              windowFrac: 0.22,
              opacity: 0.88),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    // ---- v1.3 节奏编排：2 条 moodScript 演示 ----
    'mood_tension_build': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.ambient,
            EffectKind.speedLines,
            EffectKind.focusLines,
            EffectKind.moodScript
          ],
          parallax: ParallaxParams(amplitude: 0.035, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.016, periodSec: 3),
          speedLines: SpeedLinesParams(
              count: 40, lengthFrac: 0.26, intensity: 0.4, pulses: 2),
          focusLines: FocusLinesParams(
              lines: 26, innerFrac: 0.3, wedgeDeg: 2.2, opacity: 0.26),
          moodScript: MoodScriptParams(mood: 'tension'),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'mood_burst_impact': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.mangaShake,
            EffectKind.impactRings,
            EffectKind.impactFlash,
            EffectKind.moodScript
          ],
          parallax: ParallaxParams(amplitude: 0.040, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.020, periodSec: 3),
          mangaShake: MangaShakeParams(shakes: 4, amplitude: 0.021),
          impactRings: ImpactRingsParams(
              rings: 3,
              outerFrac: 0.58,
              thicknessPx: 4.2,
              pulses: 1,
              mode: 'shock'),
          impactFlash:
              ImpactFlashParams(flashes: 1, dutyFrac: 0.08, intensity: 0.5),
          moodScript: MoodScriptParams(mood: 'burst'),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    // ---- v1.3 组合：3 个 ----
    'combo_manga_impact': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.focusLines,
            EffectKind.mangaShake,
            EffectKind.impactRings,
            EffectKind.impactFlash,
            EffectKind.moodScript
          ],
          parallax: ParallaxParams(amplitude: 0.040, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.020, periodSec: 3),
          focusLines: FocusLinesParams(
              lines: 30,
              focalY: 0.5,
              innerFrac: 0.24,
              opacity: 0.30,
              mode: 'both'),
          mangaShake: MangaShakeParams(
              shakes: 3, amplitude: 0.024, decay: 0.68, rotJitDeg: 0.16),
          impactRings: ImpactRingsParams(
              rings: 3,
              innerFrac: 0.06,
              outerFrac: 0.55,
              thicknessPx: 3.8,
              mode: 'shock'),
          impactFlash: ImpactFlashParams(intensity: 0.42),
          moodScript: MoodScriptParams(mood: 'burst', strength: 0.9),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'combo_night_battle': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.speedLines,
            EffectKind.lightning,
            EffectKind.embers,
            EffectKind.vignette,
            EffectKind.moodScript
          ],
          parallax: ParallaxParams(amplitude: 0.035, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.016, periodSec: 3),
          speedLines: SpeedLinesParams(count: 48, intensity: 0.42, pulses: 4),
          lightning: LightningParams(strikes: 3, flashIntensity: 0.45),
          embers: EmbersParams(count: 34),
          vignette: VignetteParams(strength: 0.38),
          moodScript: MoodScriptParams(mood: 'tension'),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    'combo_peaceful_evening': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.fog,
            EffectKind.leaves,
            EffectKind.fireflies,
            EffectKind.godRays,
            EffectKind.toneShift,
            EffectKind.moodScript
          ],
          parallax: ParallaxParams(amplitude: 0.030, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.012, periodSec: 3),
          fog: FogParams(blobs: 7, opacity: 0.10, color: 'eaf0e4'),
          leaves: LeavesParams(
              count: 14, sizePx: 12, swayPx: 26, palette: 'summer'),
          fireflies: FirefliesParams(count: 26, glowPx: 16),
          godRays: GodRaysParams(
              count: 3, angleDeg: 26, widthFrac: 0.07, intensity: 0.26),
          toneShift: ToneShiftParams(shift: 0.05),
          moodScript: MoodScriptParams(mood: 'calm'),
          fps: 12,
          durationSec: 3,
          maxDimension: 512,
          quality: QualityParams(tier: RenderTier.standard),
        ),
    // ---- 第五轮 W2 补覆盖：底座 / 扫光 / 尘埃（dust 是 legacy 别名，
    // 粒子渲染走 ambient；此处补齐目录里各自缺演示的效果）----
    'classic_base': () => EffectConfig(
          effects: [EffectKind.parallax, EffectKind.breathing],
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'light_sweep_hall': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.lightSweep
          ],
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
    'dust_motes': () => EffectConfig(
          effects: [
            EffectKind.parallax,
            EffectKind.breathing,
            EffectKind.ambient
          ],
          ambient: AmbientParams(particleCount: 36, mode: 'dust'),
          fps: 12,
          durationSec: 3,
          maxDimension: 640,
        ),
  };

  final inputs = <String, String>{
    'rain_night_city': 'sample_images/07_night_city.png',
    'snow_landscape': 'sample_images/04_landscape.png',
    'sakura_portrait': 'sample_images/01_portrait.png',
    'fireflies_forest': 'sample_images/08_forest.png',
    'godrays_forest': 'sample_images/08_forest.png',
    'speedlines_action': 'sample_images/02_action.png',
    'impact_duel': 'sample_images/10_duel.png',
    'heartbeat_closeup': 'sample_images/05_closeup.png',
    'combo_rain_lanterns': 'sample_images/07_night_city.png',
    'combo_sakura_light': 'sample_images/01_portrait.png',
    'combo_full_action': 'sample_images/02_action.png',
    'fog_landscape': 'sample_images/04_landscape.png',
    'embers_night_city': 'sample_images/07_night_city.png',
    'lightning_night_city': 'sample_images/07_night_city.png',
    'toneshift_landscape': 'sample_images/04_landscape.png',
    'vignette_closeup': 'sample_images/05_closeup.png',
    'starlight_night_city': 'sample_images/07_night_city.png',
    'slowpush_portrait': 'sample_images/01_portrait.png',
    'shimmer_landscape': 'sample_images/04_landscape.png',
    'combo_storm_night': 'sample_images/07_night_city.png',
    'combo_campfire': 'sample_images/08_forest.png',
    'dither_compare_forest': 'sample_images/08_forest.png',
    'focus_lines_action': 'sample_images/10_duel.png',
    'screen_tone_closeup': 'sample_images/05_closeup.png',
    'impact_burst': 'sample_images/10_duel.png',
    'brush_streak_run': 'sample_images/02_action.png',
    'manga_shake_impact': 'sample_images/02_action.png',
    'flame_campfire': 'sample_images/08_forest.png',
    'smoke_indoor': 'sample_images/01_portrait.png',
    'bubbles_underwater': 'sample_images/03_two_panel.png',
    'leaves_autumn': 'sample_images/04_landscape.png',
    'meteors_night': 'sample_images/07_night_city.png',
    'mood_tension_build': 'sample_images/02_action.png',
    'mood_burst_impact': 'sample_images/10_duel.png',
    'combo_manga_impact': 'sample_images/10_duel.png',
    'combo_night_battle': 'sample_images/07_night_city.png',
    'combo_peaceful_evening': 'sample_images/08_forest.png',
    'classic_base': 'sample_images/01_portrait.png',
    'light_sweep_hall': 'sample_images/05_closeup.png',
    'dust_motes': 'sample_images/08_forest.png',
  };

  // --previews-only：只产出 doc/previews 预览资产（跳过演示集渲染与
  // presets 重写；presets 内容确定性，重复生成无差异，但没必要跑）。
  if (previewsOnly) {
    _generatePreviews(demos, inputs);
    return;
  }

  // --presets-only：只写 classic.json + 每个 demo 的配置 JSON，不渲染
  // 演示 GIF/PNG、不清理 DELIVERY 目录、不跑 _generatePreviews。
  if (presetsOnly) {
    _writePresets(demos, presetDir);
    stdout.writeln('PRESETS-ONLY: wrote classic + ${demos.length} demo configs');
    return;
  }

  // classic.json + 每个 demo 的 preset（与渲染循环里写的是同一份内容，
  // 由 _writePresets 单点 emit；见其文档关于 classic 语义的更正）。
  _writePresets(demos, presetDir);

  final tmpRoot = 'build/showcase_tmp';
  if (Directory(tmpRoot).existsSync()) {
    Directory(tmpRoot).deleteSync(recursive: true);
  }
  Directory(tmpRoot).createSync(recursive: true);

  var n = 0;
  for (final entry in demos.entries) {
    final key = entry.key;
    final input = inputs[key]!;
    final cfg = entry.value();
    final sw = Stopwatch()..start();
    final r = await MotionPipeline(cfg).processFile(input, tmpRoot);
    sw.stop();
    // 归一化命名：<outRoot>/<key>/{anim.gif, frame_0000.png, params.json}
    final stemDir = r.outputGif.substring(0, r.outputGif.lastIndexOf('/'));
    final target = Directory('$outRoot/$key');
    target.createSync(recursive: true);
    File(r.outputGif).copySync('${target.path}/anim.gif');
    final frame0 = File('${r.frameDir}/frame_0000.png');
    if (frame0.existsSync()) {
      frame0.copySync('${target.path}/frame_0000.png');
    }
    final paramsFile = File('$stemDir/params.json');
    if (paramsFile.existsSync()) {
      paramsFile.copySync('${target.path}/params.json');
    }
    Directory(stemDir).deleteSync(recursive: true);
    // 预设文件已由循环前的 _writePresets 统一写出（内容与此处 cfg.toJsonString()
    // 同源同字节），不再重复写一遍。
    n++;
    stdout.writeln(
        '$key: ${r.frameCount} frames, ${(File('${target.path}/anim.gif').lengthSync() / 1024).toStringAsFixed(0)} KB, ${sw.elapsedMilliseconds} ms');
  }
  stdout.writeln('DONE: $n demos -> $outRoot');
  _generatePreviews(demos, inputs);
}

/// 写出 presets/*.json：classic.json + 每个 demo 的完整配置。
///
/// 两条路径共用这一处 emit（review M8）：`--presets-only` 只跑它，全量路径在
/// 渲染循环之前跑一次——同一个 `cfg.toJsonString()` 写出器、同一份
/// `EffectConfig`，与旧的全量路径逐条写盘字节一致（emit 内容只依赖 config，
/// 与渲染产物无关，重复运行幂等）。
/// 顺序差异：全量路径由「边渲染边逐个写」改成「循环前一次写完」，内容不变，
/// 只是渲染中途抛错时预设已经落盘——这正是 `--presets-only` 的语义。
///
/// classic 的语义更正（review I3）：它由 `EffectConfig(fps: 12, durationSec: 3,
/// maxDimension: 640)` 生成，其余字段**全部继承引擎默认值**。Task 3.1 就地抬高
/// 默认值后，它就跟着一起变成 v1.4 张力档，因此它不是「v1.0.0 行为、回滚用」
/// 的预设（旧注释与文件头文档说的都不再成立）；`classic_base.json` 只是预览
/// 底图，同样不是回滚件 ⇒ 仓库内目前**没有** v1.0.0 回滚预设。是否要补一个、
/// 还是以 CHANGELOG 说明，属 Task 3.7 checklist #6 的用户裁定，这里只如实描述
/// 现状，不改任何 emit 值。
void _writePresets(
    Map<String, EffectConfig Function()> demos, String presetDir) {
  final classic = EffectConfig(fps: 12, durationSec: 3, maxDimension: 640);
  File('$presetDir/classic.json').writeAsStringSync(classic.toJsonString());
  for (final entry in demos.entries) {
    File('$presetDir/${entry.key}.json')
        .writeAsStringSync(entry.value().toJsonString());
  }
}

/// 预览产物分类（index.json 的 `category` 字段，App 面板分组用）。
const Map<String, String> _kPreviewCategories = {
  'classic_base': 'base',
  'light_sweep_hall': 'light',
  'dust_motes': 'ambient',
  'rain_night_city': 'weather',
  'snow_landscape': 'weather',
  'sakura_portrait': 'weather',
  'fireflies_forest': 'weather',
  'godrays_forest': 'light',
  'speedlines_action': 'manga',
  'impact_duel': 'manga',
  'heartbeat_closeup': 'motion',
  'fog_landscape': 'atmosphere',
  'embers_night_city': 'atmosphere',
  'lightning_night_city': 'weather',
  'toneshift_landscape': 'color',
  'vignette_closeup': 'color',
  'starlight_night_city': 'light',
  'slowpush_portrait': 'motion',
  'shimmer_landscape': 'light',
  'combo_storm_night': 'combo',
  'combo_campfire': 'combo',
  'dither_compare_forest': 'quality',
  'focus_lines_action': 'manga',
  'screen_tone_closeup': 'manga',
  'impact_burst': 'manga',
  'brush_streak_run': 'manga',
  'manga_shake_impact': 'manga',
  'flame_campfire': 'atmosphere',
  'smoke_indoor': 'atmosphere',
  'bubbles_underwater': 'atmosphere',
  'leaves_autumn': 'weather',
  'meteors_night': 'weather',
  'mood_tension_build': 'mood',
  'mood_burst_impact': 'mood',
  'combo_manga_impact': 'combo',
  'combo_night_battle': 'combo',
  'combo_peaceful_evening': 'combo',
  'combo_rain_lanterns': 'combo',
  'combo_sakura_light': 'combo',
  'combo_full_action': 'combo',
};

/// 第五轮 W2：生成效果预览资产（首帧 PNG + 低配短循环 GIF）。
///
/// - 配置从各 demo 的 JSON 派生，仅覆写 `fps=8 / durationSec=1.5 /
///   maxDimension=360`（360p、12 帧循环，体积目标 <300KB/个）；
/// - 输出 `doc/previews/<key>/preview.png` + `preview.gif` +
///   汇总 `doc/previews/index.json`（key → 路径 → 分类，含 GIF 字节数）；
/// - 确定性：无时间戳等易变字段，同 seed 同 config 逐字节可复现。
Future<void> _generatePreviews(
    Map<String, EffectConfig Function()> demos, Map<String, String> inputs) async {
  const previewRoot = 'doc/previews';
  final tmpRoot = 'build/preview_tmp';
  if (Directory(tmpRoot).existsSync()) {
    Directory(tmpRoot).deleteSync(recursive: true);
  }
  Directory(tmpRoot).createSync(recursive: true);
  Directory(previewRoot).createSync(recursive: true);

  final entries = <Map<String, dynamic>>[];
  var oversize = 0;
  // 体积预算自适应降档：规则固定 → 同 seed 同产物，确定性保持。
  // 粒子/速度线等帧间变化大的效果 GIF 压缩率低，按档位降分辨率直到达标。
  const budgetBytes = 300 * 1024;
  const dimensionLadder = [360, 280, 220, 170, 130];
  for (final entry in demos.entries) {
    final key = entry.key;
    final input = inputs[key];
    if (input == null) {
      throw StateError('demo "$key" 缺少输入图映射');
    }
    final target = Directory('$previewRoot/$key')..createSync(recursive: true);
    var chosenDim = dimensionLadder.last;
    var chosenGif = '';
    var chosenFrameDir = '';
    var chosenTmpDir = '';
    for (final dim in dimensionLadder) {
      final tmpDir = '$tmpRoot/$key@$dim';
      final previewCfg = EffectConfig.fromJson(<String, dynamic>{
        ...entry.value().toJson(),
        'fps': 8,
        'durationSec': 1.5,
        'maxDimension': dim,
        'outputFormat': 'both',
      });
      final r = await MotionPipeline(previewCfg).processFile(input, tmpDir);
      final gifBytes = File(r.outputGif).lengthSync();
      // 替换上一档兜底：先删旧目录再记新路径（体积随分辨率单调降的反常
      // 情形以最后一轮为准，规则固定即可确定性复现）。
      if (chosenTmpDir.isNotEmpty) {
        Directory(chosenTmpDir).deleteSync(recursive: true);
      }
      chosenDim = dim;
      chosenGif = r.outputGif;
      chosenFrameDir = r.frameDir;
      chosenTmpDir = tmpDir;
      if (gifBytes <= budgetBytes) break;
    }
    final gifFile = File(chosenGif);
    if (!gifFile.existsSync()) {
      throw StateError('demo "$key" 预览 GIF 缺失');
    }
    gifFile.copySync('${target.path}/preview.gif');
    final frame0 = File('$chosenFrameDir/frame_0000.png');
    if (!frame0.existsSync()) {
      throw StateError('demo "$key" 预览首帧缺失');
    }
    frame0.copySync('${target.path}/preview.png');
    Directory(chosenTmpDir).deleteSync(recursive: true);
    final gifBytes = File('${target.path}/preview.gif').lengthSync();
    if (gifBytes > budgetBytes) oversize++;
    entries.add(<String, dynamic>{
      'key': key,
      'category': _kPreviewCategories[key] ?? 'misc',
      'previewGif': 'doc/previews/$key/preview.gif',
      'previewPng': 'doc/previews/$key/preview.png',
      'maxDimension': chosenDim,
      'gifBytes': gifBytes,
    });
    stdout.writeln(
        'preview $key: ${(gifBytes / 1024).toStringAsFixed(0)} KB @${chosenDim}px${gifBytes > budgetBytes ? '  [OVER 300KB]' : ''}');
  }

  // 确定性索引：固定键序（Map 字面量插入序），无易变字段。
  final index = <String, dynamic>{
    'kind': 'previews',
    'fps': 8,
    'durationSec': 1.5,
    'dimensionLadder': dimensionLadder,
    'entries': entries,
  };
  File('$previewRoot/index.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(index));
  if (Directory(tmpRoot).existsSync()) {
    Directory(tmpRoot).deleteSync(recursive: true);
  }
  stdout.writeln(
      'DONE: ${entries.length} previews -> $previewRoot${oversize > 0 ? '  [$oversize over 300KB budget]' : ''}');
}
