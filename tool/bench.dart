import 'dart:convert' as convert;
import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// Performance benchmark + reproducibility verification.
///
/// Usage: dart run tool/bench.dart [imagePath] [outDir]
/// Writes bench_report.json with timing / memory / reproducibility evidence.
Future<void> main(List<String> args) async {
  final input = args.isNotEmpty ? args[0] : 'sample_images/01_portrait.png';
  final out = args.length > 1 ? args[1] : 'build/bench';
  Directory(out).createSync(recursive: true);

  final rows = <Map<String, dynamic>>[];
  final richEffects = [
    EffectKind.parallax,
    EffectKind.breathing,
    EffectKind.ambient,
    EffectKind.rain,
    EffectKind.snow,
    EffectKind.sakura,
    EffectKind.fireflies,
    EffectKind.godRays,
    EffectKind.speedLines,
    EffectKind.impactFlash,
    EffectKind.heartbeat,
    EffectKind.fog,
    EffectKind.embers,
    EffectKind.lightning,
    EffectKind.toneShift,
    EffectKind.vignette,
    EffectKind.starlight,
    EffectKind.slowPush,
    EffectKind.shimmer,
  ];
  final scenarios = [
    {'name': 'draft_480p', 'maxDimension': 480, 'fps': 12, 'durationSec': 2.0},
    {'name': 'typical_1080p', 'maxDimension': 1080, 'fps': 24, 'durationSec': 4.0},
    {'name': 'preview_1600', 'maxDimension': 1600, 'fps': 24, 'durationSec': 4.0},
    {
      'name': 'rich_1080p',
      'maxDimension': 1080,
      'fps': 24,
      'durationSec': 4.0,
      'rich': true
    },
  ];

  for (final s in scenarios) {
    final cfg = EffectConfig(
      fps: s['fps'] as int,
      durationSec: s['durationSec'] as double,
      maxDimension: s['maxDimension'] as int,
      outputFormat: OutputFormat.gif,
      effects: s['rich'] == true ? richEffects : const [EffectKind.parallax, EffectKind.breathing, EffectKind.ambient],
    );
    // warm-up JVM-less; run twice, keep second run (JIT warm)
    MotionPipeline(cfg).processFile(input, '$out/warm_${s['name']}');
    final r = MotionPipeline(cfg).processFile(input, '$out/${s['name']}');
    rows.add({
      'scenario': s['name'],
      'maxDimension': s['maxDimension'],
      'fps': s['fps'],
      'durationSec': s['durationSec'],
      'frameCount': r.frameCount,
      'elapsedMs': r.elapsedMs,
      'peakRssMb': double.parse(r.peakRssMb.toStringAsFixed(1)),
      'input': input,
    });
    stdout.writeln(
        '${s['name']}: ${r.elapsedMs} ms, peak ${r.peakRssMb.toStringAsFixed(1)} MB, ${r.frameCount} frames');
  }

  // --- Reproducibility: same image + same params twice => byte-identical GIF.
  final cfg = EffectConfig(
      fps: 8, durationSec: 1, maxDimension: 320, outputFormat: OutputFormat.gif);
  final r1 = MotionPipeline(cfg).processFile(input, '$out/repro_a');
  final r2 = MotionPipeline(cfg).processFile(input, '$out/repro_b');
  final h1 = _md5ish(File(r1.outputGif).readAsBytesSync());
  final h2 = _md5ish(File(r2.outputGif).readAsBytesSync());
  final reproducible = h1 == h2;
  stdout.writeln('reproducibility: ${reproducible ? "PASS" : "FAIL"} '
      '($h1 vs $h2)');

  // --- Parameter sensitivity: amplitude change must alter output.
  final loud = EffectConfig(
      fps: 8,
      durationSec: 1,
      maxDimension: 320,
      parallax: const ParallaxParams(amplitude: 0.05),
      outputFormat: OutputFormat.gif);
  final r3 = MotionPipeline(loud).processFile(input, '$out/repro_loud');
  final h3 = _md5ish(File(r3.outputGif).readAsBytesSync());
  final sensitive = h1 != h3;
  stdout.writeln('param sensitivity: ${sensitive ? "PASS" : "FAIL"}');

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'input': input,
    'benchmarks': rows,
    'acceptanceLine': {
      'singleImageMaxSec': 30,
      'peakMemoryMaxMb': 2048,
    },
    'reproducibility': {
      'pass': reproducible,
      'gifHashRun1': h1,
      'gifHashRun2': h2,
      'paramsChangedHash': h3,
      'paramSensitivityPass': sensitive,
    },
    'engineVersion': '1.0.0',
  };
  File('$out/bench_report.json').writeAsStringSync(
      const convert.JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('report: $out/bench_report.json');

  if (!reproducible || !sensitive) exit(2);
}

String _md5ish(List<int> bytes) {
  // FNV-1a 64 over bytes; deterministic cross-run hash for comparison.
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b & 0xff;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
