import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_depth_onnx/comic_motion_depth_onnx.dart';
import 'package:test/test.dart';

class _FakeSession implements DepthSession {
  _FakeSession(this.values);
  final List<double> values;
  Float32List? lastInput;
  List<int>? lastShape;

  @override
  List<double> run(Float32List input, List<int> shape) {
    lastInput = Float32List.fromList(input);
    lastShape = List<int>.from(shape);
    return values;
  }
}

void main() {
  test('NCHW 布局 + ImageNet 归一化（白像素已知值锁定）', () {
    final img = RgbaImage(width: 2, height: 2);
    for (var i = 0; i < 4; i++) {
      img.setPixel(i % 2, i ~/ 2, 255, 255, 255, 255);
    }
    final s = _FakeSession(List<double>.filled(4, 0.5));
    OnnxDepthEstimator(s, size: 2).estimate(img);
    final input = s.lastInput!;
    expect(s.lastShape, [1, 3, 2, 2]);
    expect(input.length, 12);
    // 白像素：(1 - mean) / std
    expect(input[0], closeTo((1.0 - 0.485) / 0.229, 1e-6)); // R 平面 (0,0)
    expect(input[4], closeTo((1.0 - 0.456) / 0.224, 1e-6)); // G 平面 (0,0)
    expect(input[8], closeTo((1.0 - 0.406) / 0.225, 1e-6)); // B 平面 (0,0)
  });

  test('输出 min-max 归一化 → DepthMap [0,1]', () {
    final img = RgbaImage(width: 2, height: 2);
    final s = _FakeSession(<double>[1, 2, 3, 4]);
    final d = OnnxDepthEstimator(s, size: 2).estimate(img);
    expect(d.width, 2);
    expect(d.height, 2);
    expect(d.data, <double>[0, 1 / 3, 2 / 3, 1]);
  });

  test('输出长度不符抛 StateError（模型形状契约）', () {
    final img = RgbaImage(width: 2, height: 2);
    final s = _FakeSession(<double>[1, 2, 3]);
    expect(() => OnnxDepthEstimator(s, size: 2).estimate(img),
        throwsStateError);
  });

  test('恒定输出（退化模型）range=1 防除零：全 0.5', () {
    final img = RgbaImage(width: 2, height: 2);
    final s = _FakeSession(List<double>.filled(4, 0.5));
    final d = OnnxDepthEstimator(s, size: 2).estimate(img);
    expect(d.data.every((v) => v == 0.0), isTrue);
  });
}
