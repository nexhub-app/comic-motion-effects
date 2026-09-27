import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// 例子 ④：进度 / 取消 / 超时 / 后台 isolate（R2 + R3 合并演示）。
///
/// 要点：
/// - 解码、降采样、分层、调色板探针同步跑在调用方 isolate——UI 应用请用
///   `processFileInBackground` / `processBytesInBackground`（本例全程后台）。
/// - 取消粒度是「帧边界」：不打断 worker 内部单帧渲染（纯函数），停止后续
///   派发并清理半成品。
/// - 超时与取消共用同一检查点与清理路径，异常 code 分别为
///   `E_CANCELLED` / `E_TIMEOUT`。
///
/// 运行（在 comic_motion/ 包根目录）：
/// ```
/// dart run example/04_progress_cancel_background.dart
/// ```
Future<void> main() async {
  final outDir = 'build/example_04';
  Directory(outDir).createSync(recursive: true);

  // 造一张样例图（渐变 + 对比块，让动效肉眼可见）
  final im = RgbaImage(width: 640, height: 960);
  for (var y = 0; y < 960; y++) {
    for (var x = 0; x < 640; x++) {
      final block = ((x ~/ 80) + (y ~/ 80)) % 2 == 0;
      im.setPixel(x, y, (x ~/ 2) % 256, block ? 40 : 220, (y ~/ 3) % 256);
    }
  }
  final input = File('$outDir/page.png')
    ..writeAsBytesSync(ImageIO.encodePngFrame(im));
  final config = EffectConfig(
    fps: 12,
    durationSec: 2.5,
    maxDimension: 640,
    effects: [EffectKind.parallax, EffectKind.rain, EffectKind.fog],
  );

  // 1) 后台 isolate 渲染 + 进度：解码/分层不再占用当前 isolate
  stdout.writeln('--- ① processFileInBackground + onProgress ---');
  final token = MotionCancelToken();
  final done = await processFileInBackground(
    input.path,
    '$outDir/full',
    config: config,
    parallel: 4,
    memoryBudgetMb: 512,
    cancelToken: token,
    onProgress: (framesDone, framesTotal) =>
        stdout.write('\r  progress: $framesDone/$framesTotal'),
  );
  stdout.writeln('\n  完成: ${done.outputGif} '
      '(${done.elapsedMs}ms, hash=${done.configHash.substring(0, 8)})');

  // 2) 全内存：bytes 进 bytes 出，与落盘产物逐字节一致
  stdout.writeln('--- ② processBytesInBackground（内存到内存） ---');
  final mem = await processBytesInBackground(
    input: input.readAsBytesSync(),
    config: config,
    onProgress: (framesDone, framesTotal) => {},
  );
  stdout.writeln('  gif bytes: ${mem.gifBytes!.length} B, '
      'params: ${mem.paramsJsonBytes.length} B');

  // 3) 中途取消：翻页场景「人已翻走」——立即停止派发并清理半成品
  stdout.writeln('--- ③ 中途取消（用户翻页） ---');
  final cancelToken = MotionCancelToken();
  try {
    await processFileInBackground(
      input.path,
      '$outDir/cancelled',
      config: config,
      parallel: 4,
      cancelToken: cancelToken,
      onProgress: (framesDone, framesTotal) {
        if (framesDone >= 3) cancelToken.cancel(); // 模拟用户在第 4 帧前翻走
      },
    );
  } on MotionCancelledException catch (e) {
    stdout.writeln('  已取消: code=${e.code}（半成品默认清理，'
        'keepPartial: true 可保留）');
  }

  // 4) 超时兜底：低端机重配置
  stdout.writeln('--- ④ 超时兜底 ---');
  try {
    await processFileInBackground(
      input.path,
      '$outDir/timed_out',
      config: config,
      parallel: 1,
      timeout: const Duration(milliseconds: 1), // 故意极短，必然超时
    );
  } on MotionCancelledException catch (e) {
    stdout.writeln('  已超时: code=${e.code}');
  }

  stdout.writeln('done.');
}
