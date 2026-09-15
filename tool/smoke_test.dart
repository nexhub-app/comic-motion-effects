import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// Minimal smoke test: one image in, GIF + frames out.
Future<void> main(List<String> args) async {
  final input = args.isNotEmpty ? args[0] : 'sample_images\\01_portrait.png';
  final out = args.length > 1 ? args[1] : 'build\\smoke';
  final config = EffectConfig(
    fps: 12,
    durationSec: 2.0,
    maxDimension: 480,
    outputFormat: OutputFormat.both,
  );
  final sw = Stopwatch()..start();
  final result = MotionPipeline(config).processFile(input, out);
  sw.stop();
  final gif = File(result.outputGif);
  stdout.writeln('input      : ${result.inputPath}');
  stdout.writeln('size       : ${result.width}x${result.height}');
  stdout.writeln('layers     : ${result.layerCount}');
  stdout.writeln('frames     : ${result.frameCount}');
  stdout.writeln('gif        : ${result.outputGif} '
      '(${gif.existsSync() ? gif.lengthSync() : -1} bytes)');
  stdout.writeln('frames dir : ${result.frameDir}');
  stdout.writeln('elapsed    : ${result.elapsedMs} ms (wall ${sw.elapsedMilliseconds} ms)');
  if (!gif.existsSync() || gif.lengthSync() < 1000) {
    stderr.writeln('SMOKE FAILED: gif missing or too small');
    exit(2);
  }
  stdout.writeln('SMOKE OK');
}
