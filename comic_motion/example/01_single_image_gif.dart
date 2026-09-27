import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// 例子 ①：单张漫画图 → GIF 动图（最短路径）。
///
/// 运行（在 comic_motion/ 包根目录）：
/// ```
/// dart run example/01_single_image_gif.dart
/// ```
Future<void> main() async {
  final input = 'sample_images/01_portrait.png';
  final config = EffectConfig(
    fps: 12,
    durationSec: 2.0,
    maxDimension: 1280, // 移动端友好的工作分辨率
  );

  final result = await MotionPipeline(config, parallel: 4)
      .processFile(input, 'build/example_01');

  stdout.writeln('GIF        : ${result.outputGif}');
  stdout.writeln('帧序列目录 : ${result.frameDir}');
  stdout.writeln('参数回放   : ${result.paramsFile}');
  stdout.writeln('configHash : ${result.configHash}（同参数逐字节可复现）');
}
