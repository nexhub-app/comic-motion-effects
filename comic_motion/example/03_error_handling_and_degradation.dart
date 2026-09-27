import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// 例子 ③：异常处理与降级（decode 失败 / 像素预算超限 / 内存预算降级 /
/// worker 崩溃的错误码）。
///
/// 运行（在 comic_motion/ 包根目录）：
/// ```
/// dart run example/03_error_handling_and_degradation.dart
/// ```
Future<void> main() async {
  final outDir = 'build/example_03';
  Directory(outDir).createSync(recursive: true);

  // 1) decode 失败：异常带稳定错误码，按 code 程序化分支，不必解析文案
  final broken = File('$outDir/broken.png')
    ..writeAsBytesSync(<int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3]);
  try {
    ImageIO.decodeFile(broken.path);
  } on ImageDecodeException catch (e) {
    stdout.writeln('decode 失败   : code=${e.code}, ${e.message}');
  }

  // 2) 像素预算：默认 40M 像素，可按设备能力收紧（防移动端 OOM）
  final im = RgbaImage(width: 64, height: 64);
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      im.setPixel(x, y, x * 4, y * 4, 128);
    }
  }
  final small = File('$outDir/small.png')
    ..writeAsBytesSync(ImageIO.encodePngFrame(im));
  try {
    ImageIO.decodeFile(small.path, maxPixels: 100); // 4096 px > 100
  } on ImageTooLargeException catch (e) {
    stdout.writeln(
        '超限拒绝       : code=${e.code}, ${e.pixelCount} 像素 > 上限 ${e.maxPixels}');
  }

  // 3) 内存预算降级：预算不足以支撑请求的并行度时自动降档并写 warnings
  final config = EffectConfig(fps: 12, durationSec: 2.0, maxDimension: 1280);
  final result = await MotionPipeline(config, parallel: 8, memoryBudgetMb: 100)
      .processFile(small.path, '$outDir/out');
  for (final w in result.warnings) {
    stdout.writeln('warning       : $w');
  }
  stdout.writeln(
      '实际并行      : ${result.parallel}（fallback=${result.parallelFallback}）');

  // 4) worker 崩溃：渲染中途崩溃不会静默出图，任务整体失败并抛
  //    EngineWorkerException（code=E_WORKER_CRASH），HTTP 层映射同码。
  stdout.writeln(
      'worker 崩溃码 : ${EngineWorkerException(0, 'demo').code}');
}
