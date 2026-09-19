import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// v1.1~v1.3 动效演示集生成器：单效 + 组合，一图一目录。
/// 输出：DELIVERY/effect_showcase/<key>/{anim.gif, frame_0000.png}
/// 同时写出 presets/*.json（经典/单效/组合预设，供 --config 使用与回滚）。
///
/// 运行：dart run tool/generate_showcase.dart
Future<void> main(List<String> args) async {
  final outRoot = args.isNotEmpty ? args[0] : 'DELIVERY/effect_showcase';
  final presetDir = args.length > 1 ? args[1] : 'presets';
  final root = Directory(outRoot)..createSync(recursive: true);
  // 只清「带 anim.gif 的演示目录」：图鉴 HTML 与启动脚本是手工资产，
  // 生成器无权抹掉（v1.3 之前是整树 delete，重新生成一次就丢一次 HTML）。
  for (final d in root.listSync().whereType<Directory>()) {
    if (File('${d.path}\\anim.gif').existsSync()) d.deleteSync(recursive: true);
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
          heartbeat: HeartbeatParams(beats: 3, intensity: 0.011),
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
          heartbeat: HeartbeatParams(beats: 4, intensity: 0.012),
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
          slowPush: SlowPushParams(pushFrac: 0.03),
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
          parallax: ParallaxParams(amplitude: 0.012, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.006, periodSec: 3),
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
          parallax: ParallaxParams(amplitude: 0.010, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.005, periodSec: 3),
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
          parallax: ParallaxParams(amplitude: 0.014, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.007, periodSec: 3),
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
              ParallaxParams(amplitude: 0.016, periodSec: 3, directionDeg: 12),
          breathing: BreathingParams(amplitude: 0.006, periodSec: 3),
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
          parallax: ParallaxParams(amplitude: 0.014, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.007, periodSec: 3),
          mangaShake: MangaShakeParams(
              shakes: 5, amplitude: 0.009, decay: 0.7, rotJitDeg: 0.15),
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
          parallax: ParallaxParams(amplitude: 0.012, periodSec: 3),
          breathing:
              BreathingParams(amplitude: 0.006, periodSec: 3, anchor: 'bottom'),
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
          parallax: ParallaxParams(amplitude: 0.010, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.005, periodSec: 3),
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
              amplitude: 0.012, periodSec: 3, verticalRatio: 0.45),
          breathing: BreathingParams(amplitude: 0.006, periodSec: 3),
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
              ParallaxParams(amplitude: 0.012, periodSec: 3, directionDeg: 8),
          breathing: BreathingParams(amplitude: 0.005, periodSec: 3),
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
          parallax: ParallaxParams(amplitude: 0.010, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.005, periodSec: 3),
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
          parallax: ParallaxParams(amplitude: 0.014, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.008, periodSec: 3),
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
          parallax: ParallaxParams(amplitude: 0.016, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.010, periodSec: 3),
          mangaShake: MangaShakeParams(shakes: 4, amplitude: 0.007),
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
          parallax: ParallaxParams(amplitude: 0.016, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.010, periodSec: 3),
          focusLines: FocusLinesParams(
              lines: 30,
              focalY: 0.5,
              innerFrac: 0.24,
              opacity: 0.30,
              mode: 'both'),
          mangaShake: MangaShakeParams(
              shakes: 3, amplitude: 0.008, decay: 0.68, rotJitDeg: 0.16),
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
          parallax: ParallaxParams(amplitude: 0.014, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.008, periodSec: 3),
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
          parallax: ParallaxParams(amplitude: 0.012, periodSec: 3),
          breathing: BreathingParams(amplitude: 0.006, periodSec: 3),
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
  };

  // 经典预设（v1.0.0 行为，回滚用）
  final classic = EffectConfig(fps: 12, durationSec: 3, maxDimension: 640);
  File('$presetDir/classic.json').writeAsStringSync(classic.toJsonString());

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
    final stemDir = r.outputGif.substring(0, r.outputGif.lastIndexOf('\\'));
    final target = Directory('$outRoot/$key');
    target.createSync(recursive: true);
    File(r.outputGif).copySync('${target.path}\\anim.gif');
    final frame0 = File('${r.frameDir}\\frame_0000.png');
    if (frame0.existsSync()) {
      frame0.copySync('${target.path}\\frame_0000.png');
    }
    final paramsFile = File('$stemDir\\params.json');
    if (paramsFile.existsSync()) {
      paramsFile.copySync('${target.path}\\params.json');
    }
    Directory(stemDir).deleteSync(recursive: true);
    // 预设文件（完整配置，供 --config 直接使用）
    File('$presetDir/$key.json').writeAsStringSync(cfg.toJsonString());
    n++;
    stdout.writeln(
        '$key: ${r.frameCount} frames, ${(File('${target.path}\\anim.gif').lengthSync() / 1024).toStringAsFixed(0)} KB, ${sw.elapsedMilliseconds} ms');
  }
  stdout.writeln('DONE: $n demos -> $outRoot');
}
