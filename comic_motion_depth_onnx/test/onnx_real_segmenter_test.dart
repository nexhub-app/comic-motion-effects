// u2netp 真模型集成验证（机器本地，自跳过）：QDQ 模型不存在时整组 skip，
// 不进 CI 门禁。模型路径可用环境变量 SEG_MODEL 覆盖。模式与
// onnx_real_model_test.dart（MiDaS）一致。
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_depth_onnx/comic_motion_depth_onnx.dart';
import 'package:flutter_test/flutter_test.dart';

const String _defaultModel = '../build/depth_probe/models/u2netp.onnx';

/// 白底 + 中央深色圆盘的合成页：显著性目标明确，u2netp 应找出主体。
RgbaImage _discPage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, 255, 255, 255, 255);
    }
  }
  final cx = w / 2, cy = h / 2, r = w / 5.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r * r) {
        img.setPixel(x, y, 30, 30, 30, 255);
      }
    }
  }
  return img;
}

void main() {
  final modelPath = Platform.environment['SEG_MODEL'] ?? _defaultModel;
  final modelExists = File(modelPath).existsSync();

  group('OnnxSubjectSegmenter 真模型（机器本地自跳过）', () {
    test('真实 QDQ u2netp：合成圆盘页分割出主体域', () {
      final seg = OnnxSubjectSegmenter(OrtSessionAdapter.fromFile(modelPath));
      final mask = seg.segment(_discPage(320, 320));
      expect(mask.width, 320);
      expect(mask.height, 320);
      expect(mask.hasSubjects, isTrue,
          reason: '白底黑圆盘是强显著性目标，u2netp 应检出主体');
      for (final b in mask.blobs) {
        expect(b.rect.x, inInclusiveRange(0, 319));
        expect(b.rect.y, inInclusiveRange(0, 319));
        expect(b.area, greaterThan(0));
      }
      // 主体域应落在圆盘附近（页面中央区域有覆盖）。
      expect(mask.labelAt(160, 160), greaterThan(0));
    }, skip: modelExists ? false : 'machine-local u2netp QDQ model not found');

    test('后台链路（分割 + 钳制工厂跨 isolate）：两次运行逐字节一致', () async {
      final input =
          Uint8List.fromList(ImageIO.encodePngFrame(_discPage(240, 240)));
      EffectConfig cfg() => EffectConfig.fromJson(const <String, dynamic>{
            'effects': <String>['parallax'],
            'fps': 12,
            'durationSec': 0.5,
            'maxDimension': 240,
            'layerCount': 3,
            'panelAware': false,
            'outputFormat': 'gif',
            'seed': 7,
          });
      Future<MemoryPipelineResult> run() => processBytesInBackground(
            input: input,
            config: cfg(),
            subjectSegmenterFactory: () => OnnxSubjectSegmenter(
                OrtSessionAdapter.fromFile(modelPath)),
          );
      final a = await run();
      final b = await run();
      expect(a.frameCount, greaterThanOrEqualTo(1));
      expect(b.gifBytes, a.gifBytes, reason: '真模型推理必须确定性可复现');
    }, skip: modelExists ? false : 'machine-local u2netp QDQ model not found');
  });
}
