import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// v1.1 新动效演示集生成器：8 单效 + 3 组合。
/// 输出：DELIVERY/effect_showcase/<key>/anim.gif + frame_0000.png（静态降级帧）
/// 同时写出 presets/*.json（经典/单效/组合预设，供 --config 使用与回滚）。
///
/// 运行：dart run tool/generate_showcase.dart
void main(List<String> args) {
  final outRoot = args.isNotEmpty ? args[0] : 'DELIVERY/effect_showcase';
  final presetDir = args.length > 1 ? args[1] : 'presets';
  if (Directory(outRoot).existsSync()) {
    Directory(outRoot).deleteSync(recursive: true);
  }
  Directory(outRoot).createSync(recursive: true);
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
  };

  // 经典预设（v1.0.0 行为，回滚用）
  final classic = EffectConfig(fps: 12, durationSec: 3, maxDimension: 640);
  File('$presetDir/classic.json')
      .writeAsStringSync(classic.toJsonString());

  final tmpRoot = 'build/showcase_tmp';
  if (Directory(tmpRoot).existsSync()) {
    Directory(tmpRoot).deleteSync(recursive: true);
  }
  Directory(tmpRoot).createSync(recursive: true);

  var n = 0;
  demos.forEach((key, mkCfg) {
    final input = inputs[key]!;
    final cfg = mkCfg();
    final sw = Stopwatch()..start();
    final r = MotionPipeline(cfg).processFile(input, tmpRoot);
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
  });
  stdout.writeln('DONE: $n demos -> $outRoot');
}
