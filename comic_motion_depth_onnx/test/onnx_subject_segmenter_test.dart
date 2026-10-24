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

class _ThrowingSession implements DepthSession {
  @override
  List<double> run(Float32List input, List<int> shape) =>
      throw StateError('boom');
}

void main() {
  test('NCHW 布局 + /255 + ImageNet 归一化（白像素已知值锁定，绿 std=0.227）',
      () {
    final img = RgbaImage(width: 2, height: 2);
    for (var i = 0; i < 4; i++) {
      img.setPixel(i % 2, i ~/ 2, 255, 255, 255, 255);
    }
    final s = _FakeSession(List<double>.filled(4, 0.5));
    OnnxSubjectSegmenter(s, size: 2).segment(img);
    final input = s.lastInput!;
    expect(s.lastShape, [1, 3, 2, 2]);
    expect(input.length, 12);
    // 白像素：(1 - mean) / std。u2netp 官方 loader 绿通道 std = 0.227。
    expect(input[0], closeTo((1.0 - 0.485) / 0.229, 1e-6)); // R 平面 (0,0)
    expect(input[4], closeTo((1.0 - 0.456) / 0.227, 1e-6)); // G 平面 (0,0)
    expect(input[8], closeTo((1.0 - 0.406) / 0.225, 1e-6)); // B 平面 (0,0)
  });

  test('sigmoid 概率直通（不做 min-max）→ SubjectMask 连通域', () {
    final img = RgbaImage(width: 2, height: 2);
    // 概率图：上排 0.9（主体），下排 0.1（背景）。阈值 0.5 → 上排成域。
    final s = _FakeSession(<double>[0.9, 0.9, 0.1, 0.1]);
    final mask = OnnxSubjectSegmenter(s, size: 2, minBlobArea: 1).segment(img);
    expect(mask.width, 2);
    expect(mask.height, 2);
    expect(mask.hasSubjects, isTrue);
    expect(mask.blobs.length, 1);
    expect(mask.blobs[0].rect.x, 0);
    expect(mask.blobs[0].rect.y, 0);
    expect(mask.blobs[0].area, 2);
    expect(mask.labelAt(0, 0), 1);
    expect(mask.labelAt(1, 0), 1);
    expect(mask.labelAt(0, 1), 0);
    // 直通校验：若被 min-max 归一化，0.45 会被拉伸到 0.5 而过阈值——
    // 直通语义下它必须仍是背景。
    final s2 = _FakeSession(<double>[0.8, 0.4, 0.45, 0.1]);
    final m2 =
        OnnxSubjectSegmenter(s2, size: 2, minBlobArea: 1).segment(img);
    expect(m2.labelAt(0, 0), 1, reason: '0.8 ≥ 0.5');
    expect(m2.labelAt(1, 1), 0,
        reason: '0.45 < 0.5（min-max 归一化会把它拉到恰 0.5 而误判主体）');
    expect(m2.blobs[0].area, 1);
  });

  test('输出长度不符：降级空掩码（永不抛契约）', () {
    final img = RgbaImage(width: 2, height: 2);
    final s = _FakeSession(<double>[1, 2, 3]);
    final mask = OnnxSubjectSegmenter(s, size: 2).segment(img);
    expect(mask.hasSubjects, isFalse);
    expect(mask.width, 2);
    expect(mask.height, 2);
  });

  test('会话抛异常：降级空掩码（永不抛契约）', () {
    final img = RgbaImage(width: 2, height: 2);
    final mask = OnnxSubjectSegmenter(_ThrowingSession(), size: 2).segment(img);
    expect(mask.hasSubjects, isFalse);
  });

  test('全低概率（无主体）：空掩码', () {
    final img = RgbaImage(width: 2, height: 2);
    final s = _FakeSession(List<double>.filled(4, 0.05));
    final mask = OnnxSubjectSegmenter(s, size: 2).segment(img);
    expect(mask.hasSubjects, isFalse);
  });

  test('cacheTag：默认带输入边长，可覆盖', () {
    expect(OnnxSubjectSegmenter(_FakeSession(const [])).cacheTag, 'u2netp320');
    expect(
        OnnxSubjectSegmenter(_FakeSession(const []), cacheTag: 'u2netp-int8')
            .cacheTag,
        'u2netp-int8');
  });

  test('概率图重采样：320 口径模型输出映射到小格', () {
    // size=2 模型输出 → 4x4 格：双线性放大后阈值化。
    final img = RgbaImage(width: 4, height: 4);
    final s = _FakeSession(<double>[0.9, 0.1, 0.1, 0.1]);
    final mask = OnnxSubjectSegmenter(s, size: 2, minBlobArea: 1).segment(img);
    expect(mask.width, 4);
    expect(mask.height, 4);
    // 左上角概率最高，主体域应覆盖左上区域（具体形状由双线性决定）。
    expect(mask.labelAt(0, 0), 1);
  });
}
