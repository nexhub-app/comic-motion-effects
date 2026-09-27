import 'dart:convert';
import 'dart:io';

import 'package:comic_motion/comic_motion.dart';

/// 例子 ②：效果组合 + 自定义参数 + 配置 JSON 导入/导出。
///
/// 运行（在 comic_motion/ 包根目录）：
/// ```
/// dart run example/02_effects_and_config_json.dart
/// ```
Future<void> main() async {
  // 32 种动效可任意组合；seed 决定粒子/闪电等随机效果的确定性
  var config = EffectConfig(
    effects: [
      EffectKind.parallax,
      EffectKind.breathing,
      EffectKind.rain,
      EffectKind.lightning,
    ],
    fps: 24,
    durationSec: 3.0,
    layerCount: 4,
    seed: 42,
  );
  config.quality = config.quality.copyWith(tier: RenderTier.standard);

  // 导出：与产物 params.json 同源，可用于回放 / 留档 / 跨端传递
  final json = config.toJsonString();
  final jsonFile = File('build/example_02_params.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(json);
  stdout.writeln('配置已导出: ${jsonFile.path}');

  // 导入：从 JSON 还原（CLI 的 --config 即同一套结构）
  final restored = EffectConfig.fromJson(
      jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>);
  stdout.writeln('hash 往返一致: ${restored.configHash == config.configHash}');

  final result = await MotionPipeline(restored, parallel: 4)
      .processFile('sample_images/07_night_city.png', 'build/example_02');
  stdout.writeln('GIF: ${result.outputGif}');
}
