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

  const baseEffects = [
    EffectKind.parallax,
    EffectKind.breathing,
    EffectKind.ambient,
  ];
  // v1.2 的 19 效全开场景，行名与口径保持历史可比（rich_1080p 红线是「不比 v1.2 慢」）。
  final v12Effects = [
    ...baseEffects,
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
  // 全效果 = EffectKind 全集，写死条数迟早和枚举漂移。
  final allEffects = EffectKind.values.toList();

  final rows = <Map<String, dynamic>>[];
  final scenarios = [
    {
      'name': 'draft_480p',
      'maxDimension': 480,
      'fps': 12,
      'durationSec': 2.0,
      'maxMs': 450
    },
    {
      'name': 'typical_1080p',
      'maxDimension': 1080,
      'fps': 24,
      'durationSec': 4.0,
      'maxMs': 5000
    },
    {
      'name': 'preview_1600',
      'maxDimension': 1600,
      'fps': 24,
      'durationSec': 4.0,
      'maxMs': 7000
    },
    {
      'name': 'rich_1080p',
      'maxDimension': 1080,
      'fps': 24,
      'durationSec': 4.0,
      'effects': v12Effects
    },
    // v1.3 质量档全开（AA 光栅 + 面积平均 + Catmull-Rom + LUT 量化 + 三帧调色板）
    {
      'name': 'standard_1080p',
      'maxDimension': 1080,
      'fps': 24,
      'durationSec': 4.0,
      'tier': 'standard',
    },
    {
      'name': 'rich_tier_1080p',
      'maxDimension': 1080,
      'fps': 24,
      'durationSec': 4.0,
      'effects': v12Effects,
      'tier': 'rich',
    },
    // v1.3 全效 + standard 档：新动效叠加后的真实最坏情况
    {
      'name': 'v13_full_1080p',
      'maxDimension': 1080,
      'fps': 24,
      'durationSec': 4.0,
      'effects': allEffects,
      'tier': 'standard',
      'maxMs': 9000,
    },
  ];

  for (final s in scenarios) {
    final effects = (s['effects'] as List<EffectKind>?) ?? baseEffects;
    final cfg = EffectConfig(
      fps: s['fps'] as int,
      durationSec: s['durationSec'] as double,
      maxDimension: s['maxDimension'] as int,
      outputFormat: OutputFormat.gif,
      quality: QualityParams(
          tier: RenderTier.parse(s['tier'] ?? 'legacy'),
          ditherMode: s['tier'] == 'rich' ? 'sierra' : 'floyd'),
      effects: effects,
    );
    // warm-up JVM-less; run twice, keep second run (JIT warm)
    await MotionPipeline(cfg).processFile(input, '$out/warm_${s['name']}');
    final r = await MotionPipeline(cfg).processFile(input, '$out/${s['name']}');
    final maxMs = s['maxMs'];
    final withinLine = maxMs == null || r.elapsedMs <= (maxMs as int);
    rows.add({
      'scenario': s['name'],
      'tier': s['tier'] ?? 'legacy',
      'maxDimension': s['maxDimension'],
      'fps': s['fps'],
      'durationSec': s['durationSec'],
      'effectCount': effects.length,
      'frameCount': r.frameCount,
      'elapsedMs': r.elapsedMs,
      'peakRssMb': double.parse(r.peakRssMb.toStringAsFixed(1)),
      'parallel': r.parallel,
      if (maxMs != null) 'maxMs': maxMs,
      if (maxMs != null) 'redLinePass': withinLine,
      'input': input,
    });
    stdout.writeln('${s['name']}: ${r.elapsedMs} ms '
        '(${effects.length} effects, parallel=${r.parallel}), '
        'peak ${r.peakRssMb.toStringAsFixed(1)} MB, ${r.frameCount} frames'
        '${maxMs == null ? '' : withinLine ? ' PASS(≤$maxMs)' : ' FAIL(>$maxMs)'}');
  }

  // --- 并行度扫描：1/2/4/8 只应改耗时，不改字节。
  final sweepCfg = EffectConfig(
    fps: 24,
    durationSec: 4.0,
    maxDimension: 1080,
    outputFormat: OutputFormat.gif,
    quality: const QualityParams(tier: RenderTier.standard),
    effects: baseEffects,
  );
  await MotionPipeline(sweepCfg).processFile(input, '$out/warm_sweep');
  final sweep = <Map<String, dynamic>>[];
  String? serialHash;
  for (final p in [1, 2, 4, 8]) {
    final r =
        await MotionPipeline(sweepCfg, parallel: p).processFile(input, '$out/sweep_p$p');
    final h = _md5ish(File(r.outputGif).readAsBytesSync());
    final equalsSerial = serialHash == null || h == serialHash;
    serialHash ??= h;
    final rss = double.parse(r.peakRssMb.toStringAsFixed(1));
    final maxRss = p == 1 ? 780.0 : 1150.0;
    sweep.add({
      'parallelRequested': p,
      'parallelUsed': r.parallel,
      'elapsedMs': r.elapsedMs,
      'peakRssMb': rss,
      'gifHash': h,
      'bytesEqualsSerial': equalsSerial,
      'rssRedLineMb': maxRss,
      'rssRedLinePass': rss <= maxRss,
    });
    stdout.writeln('parallel=$p (used ${r.parallel}): ${r.elapsedMs} ms, '
        'peak $rss MB (红线 $maxRss), 字节${equalsSerial ? '一致' : '不一致'}');
    Directory('$out/sweep_p$p').deleteSync(recursive: true);
  }
  final sweepOk = sweep.every((e) => e['bytesEqualsSerial'] == true);

  // --- Reproducibility: same image + same params twice => byte-identical GIF.
  final cfg = EffectConfig(
      fps: 8,
      durationSec: 1,
      maxDimension: 320,
      outputFormat: OutputFormat.gif);
  final r1 = await MotionPipeline(cfg).processFile(input, '$out/repro_a');
  final r2 = await MotionPipeline(cfg).processFile(input, '$out/repro_b');
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
  final r3 = await MotionPipeline(loud).processFile(input, '$out/repro_loud');
  final h3 = _md5ish(File(r3.outputGif).readAsBytesSync());
  final sensitive = h1 != h3;
  stdout.writeln('param sensitivity: ${sensitive ? "PASS" : "FAIL"}');

  // --- 并行一致性：parallel=1 与 parallel=4 必须逐字节相同（同参数同 hash）。
  final rs = await MotionPipeline(cfg, parallel: 1)
      .processFile(input, '$out/repro_serial');
  final rp = await MotionPipeline(cfg, parallel: 4)
      .processFile(input, '$out/repro_par4');
  final hs = _md5ish(File(rs.outputGif).readAsBytesSync());
  final hp = _md5ish(File(rp.outputGif).readAsBytesSync());
  final parallelOk = hs == hp && hs == h1;
  stdout.writeln('parallel == serial: ${parallelOk ? "PASS" : "FAIL"} '
      '(serial=$hs parallel4=$hp, 实际并行度 ${rp.parallel})');

  final redLineFails = [
    for (final r in rows)
      if (r.containsKey('redLinePass') && r['redLinePass'] == false)
        '${r['scenario']} ${r['elapsedMs']}ms > ${r['maxMs']}ms',
    for (final e in sweep)
      if (e['rssRedLinePass'] == false)
        'parallel=${e['parallelRequested']} RSS ${e['peakRssMb']}MB > ${e['rssRedLineMb']}MB',
  ];
  for (final f in redLineFails) {
    stdout.writeln('性能红线超标: $f');
  }

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'input': input,
    'benchmarks': rows,
    'parallelSweep': sweep,
    'acceptanceLine': {
      'singleImageMaxSec': 30,
      'peakMemoryMaxMb': 2048,
      'draft480pMaxMs': 450,
      'typical1080pMaxMs': 5000,
      'preview1600MaxMs': 7000,
      'v13Full1080pMaxMs': 9000,
      'peakRssParallel8MaxMb': 1150,
      'peakRssParallel1MaxMb': 780,
    },
    'redLineFailures': redLineFails,
    'reproducibility': {
      'pass': reproducible,
      'gifHashRun1': h1,
      'gifHashRun2': h2,
      'paramsChangedHash': h3,
      'paramSensitivityPass': sensitive,
      'parallelEqualsSerial': parallelOk,
      'parallelSerialHash': hs,
      'parallelWorkerHash': hp,
      'parallelWorkersUsed': rp.parallel,
      'sweepBytesIdentical': sweepOk,
    },
    'engineVersion': comicMotionVersion,
  };
  File('$out/bench_report.json').writeAsStringSync(
      const convert.JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('report: $out/bench_report.json');

  if (!reproducible || !sensitive || !parallelOk) exit(2);
  if (redLineFails.isNotEmpty || !sweepOk) exit(3);
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
