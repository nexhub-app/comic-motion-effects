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
  // 33 种动效可任意组合；seed 决定粒子/闪电等随机效果的确定性
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

  // ---- R5 渲染参数 API + 效果选择 API（不可变链式）----
  // 顶层便捷参数（dither / amplitude / directionDeg / qualityTier）一处设齐
  // 全部渲染参数，内部映射到既有字段，与显式嵌套写法同 hash；效果增删返回
  // 新实例、原 config 不被修改。
  final tuned = EffectConfig(
    fps: 12,
    durationSec: 2.5,
    maxDimension: 800,
    dither: true,
    qualityTier: RenderTier.standard,
    amplitude: 0.02,
    directionDeg: 45,
    effects: [EffectKind.rain],
  ).withoutEffect(EffectKind.fog).withEffect(EffectKind.snow);
  stdout.writeln(
      '链式配置: fps=${tuned.fps}, dither=${tuned.quality.dither}, '
      'amplitude=${tuned.parallax.amplitude}, '
      'effects=${tuned.effects.map((e) => e.name).join('+')}');
  // 程序可读的参数目录：App 可据此动态生成设置面板（范围不硬编码）
  for (final spec in kRenderParamSpecs) {
    stdout.writeln(
        '  参数目录 ${spec.name}(${spec.type}): 默认=${spec.defaultValue}, '
        'min=${spec.min}, max=${spec.max}');
  }

  // 导出：与产物 params.json 同源，可用于回放 / 留档 / 跨端传递。
  // App 持久化推荐方式：直接存 EffectConfig.toJsonString()，读回即恢复。
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
