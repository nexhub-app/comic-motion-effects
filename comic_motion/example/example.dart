import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// Minimal runnable example: render one static comic page into a
/// deterministic animated GIF.
///
/// Run from the `comic_motion/` package root:
/// ```
/// dart run example/example.dart [imagePath]
/// ```
Future<void> main(List<String> args) async {
  final input = args.isNotEmpty ? args[0] : 'sample_images/01_portrait.png';
  final config = EffectConfig(
    fps: 12,
    durationSec: 2.0,
    maxDimension: 1280, // mobile-friendly working resolution
  );

  final pipeline = MotionPipeline(
    config,
    parallel: 4,
    onProgress: (done, total) => stdout.write('\rframe $done/$total'),
  );

  final result = await pipeline.processFile(input, 'build/example');

  stdout.writeln();
  stdout.writeln('gif        : ${result.outputGif}');
  stdout.writeln('configHash : ${result.configHash} (byte-reproducible)');
  stdout.writeln('contentHash: ${result.contentHash}');

  // Same input + same config always yields byte-identical output:
  // run this example twice and compare the configHash.
  exit(0);
}
