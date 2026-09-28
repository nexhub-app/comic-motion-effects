import 'dart:convert' as convert;
import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// High-fps APNG benchmark (W3): 60 fps short-loop APNG with exact frame
/// delay, full-frame vs rect-diff encoding, against a 24 fps GIF baseline.
///
/// Usage: dart run tool/bench_high_fps.dart [imagePath] [outDir]
/// Writes high_fps_report.json (timing / memory / output size evidence) used
/// by doc/high-fps.md. Deterministic configs (seed fixed) — sizes are
/// reproducible byte-for-byte; timings/RSS are indicative only.
Future<void> main(List<String> args) async {
  final input = args.isNotEmpty ? args[0] : 'sample_images/02_action.png';
  final out = args.length > 1 ? args[1] : 'build/bench_high_fps';
  Directory(out).createSync(recursive: true);

  // 局部动效（rect 差分受益场景）与全画面动效（rect 零收益场景）各取代表。
  const localEffect = 'lightSweep';
  const globalEffect = 'rain';

  final rows = <Map<String, dynamic>>[];
  Future<void> runScenario({
    required String name,
    required String effect,
    required int maxDimension,
    required String container, // apng_full | apng_rect | gif_full
    int fps = 60,
    double durationSec = 2.0,
  }) async {
    final isGif = container == 'gif_full';
    final encoding = isGif
        ? null
        : {
            'diffMode': container == 'apng_rect' ? 'rect' : 'none',
            'apngDelay': 'exact',
          };
    final cfg = EffectConfig.fromJson(<String, dynamic>{
      'effects': [effect],
      'fps': fps,
      'durationSec': durationSec,
      'maxDimension': maxDimension,
      'outputFormat': isGif ? 'gif' : 'apng',
      'seed': 7,
      if (encoding != null) 'encoding': encoding,
    });
    // warm-up run（JIT 预热），正式跑第二遍。
    await MotionPipeline(cfg).processFile(input, '$out/warm_$name');
    final r = await MotionPipeline(cfg).processFile(input, '$out/$name');
    final bytes = isGif
        ? File(r.outputGif).lengthSync()
        : File(r.outputApng).lengthSync();
    rows.add(<String, dynamic>{
      'scenario': name,
      'effect': effect,
      'container': container,
      'maxDimension': maxDimension,
      'fps': fps,
      'durationSec': durationSec,
      'frameCount': r.frameCount,
      'outputBytes': bytes,
      'outputKb': double.parse((bytes / 1024).toStringAsFixed(1)),
      'elapsedMs': r.elapsedMs,
      'peakRssMb': double.parse(r.peakRssMb.toStringAsFixed(1)),
      'parallel': r.parallel,
    });
    stdout.writeln(
        '$name: ${(bytes / 1024).toStringAsFixed(0)}KB ${r.elapsedMs}ms ${r.peakRssMb}MB');
  }

  for (final effect in [localEffect, globalEffect]) {
    final tag = effect == localEffect ? 'local' : 'global';
    for (final dim in [360, 540, 720]) {
      await runScenario(
          name: '${tag}_apng_full_$dim',
          effect: effect,
          maxDimension: dim,
          container: 'apng_full');
      await runScenario(
          name: '${tag}_apng_rect_$dim',
          effect: effect,
          maxDimension: dim,
          container: 'apng_rect');
      // 24fps GIF 全量基线（一次即可，与分辨率同档 720 保持可比）。
      if (dim == 720) {
        await runScenario(
            name: '${tag}_gif24_full_720',
            effect: effect,
            maxDimension: dim,
            container: 'gif_full',
            fps: 24);
      }
    }
  }

  // 确定性抽查：同 config 重跑一次，体积必须一致（字节级复现由单测锁定）。
  const checkName = 'local_apng_rect_540';
  final cfg = EffectConfig.fromJson(<String, dynamic>{
    'effects': [localEffect],
    'fps': 60,
    'durationSec': 2.0,
    'maxDimension': 540,
    'outputFormat': 'apng',
    'seed': 7,
    'encoding': {'diffMode': 'rect', 'apngDelay': 'exact'},
  });
  final rerun = await MotionPipeline(cfg).processFile(input, '$out/det_check');
  final detBytes = File(rerun.outputApng).lengthSync();
  final baseRow =
      rows.firstWhere((r) => r['scenario'] == checkName) as Map<String, dynamic>;
  final deterministic = detBytes == (baseRow['outputBytes'] as int);
  stdout.writeln('determinism size check: $deterministic');

  final report = <String, dynamic>{
    'kind': 'high_fps_bench',
    'input': input,
    'seed': 7,
    'rows': rows,
    'determinismSizeCheck': deterministic,
  };
  File('$out/high_fps_report.json').writeAsStringSync(
      const convert.JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('DONE -> $out/high_fps_report.json');
}
