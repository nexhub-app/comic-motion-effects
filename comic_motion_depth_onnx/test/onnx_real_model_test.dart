// 真模型集成验证（机器本地，自跳过）：QDQ 模型不存在时整组 skip，
// 不进 CI 门禁。模型路径可用环境变量 MIDAS_QDQ_MODEL 覆盖。
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_depth_onnx/comic_motion_depth_onnx.dart';
import 'package:flutter_test/flutter_test.dart';

const String _defaultModel =
    '../build/depth_probe/models/midas_v21_small_256_qdq.onnx';

RgbaImage _synthetic(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, x * 255 ~/ w, y * 255 ~/ h, (x + y) % 256, 255);
    }
  }
  return img;
}

void main() {
  final modelPath = Platform.environment['MIDAS_QDQ_MODEL'] ?? _defaultModel;
  final modelExists = File(modelPath).existsSync();

  group('OrtSessionAdapter 真模型（机器本地自跳过）', () {
    test('真实 QDQ 模型加载 + 单次估算（NCHW→[0,1] 深度）', () {
      final est = OnnxDepthEstimator(OrtSessionAdapter.fromFile(modelPath));
      final d = est.estimate(_synthetic(512, 384));
      expect(d.width, 256);
      expect(d.height, 256);
      for (final v in d.data) {
        expect(v.isNaN, isFalse);
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    }, skip: modelExists ? false : 'machine-local QDQ model not found');

    test('后台链路（工厂跨 isolate）：两次运行逐字节一致', () async {
      final input = Uint8List.fromList(
          ImageIO.encodePngFrame(_synthetic(160, 200)));
      EffectConfig cfg() => EffectConfig.fromJson(const <String, dynamic>{
            'effects': <String>['parallax'],
            'fps': 12,
            'durationSec': 0.5,
            'maxDimension': 128,
            'layerCount': 3,
            'panelAware': false,
            'outputFormat': 'gif',
            'seed': 7,
          });
      Future<MemoryPipelineResult> run() => processBytesInBackground(
            input: input,
            config: cfg(),
            depthEstimatorFactory: () => RegionCoherentDepthEstimator(
                inner: OnnxDepthEstimator(
                    OrtSessionAdapter.fromFile(modelPath)),
                detailMinArea: 64),
            motionGateFactory: () => const DepthSpreadGate(),
          );
      final a = await run();
      final b = await run();
      expect(a.frameCount, greaterThanOrEqualTo(1));
      expect(b.gifBytes, a.gifBytes, reason: '真模型推理必须确定性可复现');
    }, skip: modelExists ? false : 'machine-local QDQ model not found');
  });
}
