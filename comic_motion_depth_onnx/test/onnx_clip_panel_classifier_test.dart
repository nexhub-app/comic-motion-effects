import 'dart:math' as math;
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

/// 单位提示词嵌入（每类一个正交基向量）→ 余弦 = 图像嵌入对应分量。
List<List<double>> _unitPrompts(int dim) => [
      for (var c = 0; c < 4; c++)
        [for (var i = 0; i < dim; i++) i == c ? 1.0 : 0.0],
    ];

RgbaImage _panel() {
  final img = RgbaImage(width: 4, height: 4);
  for (var i = 0; i < 16; i++) {
    img.setPixel(i % 4, i ~/ 4, 128, 64, 200, 255);
  }
  return img;
}

void main() {
  test('NCHW 布局 + CLIP 归一化（灰像素已知值锁定）', () {
    final img = RgbaImage(width: 2, height: 2);
    for (var i = 0; i < 4; i++) {
      img.setPixel(i % 2, i ~/ 2, 255, 255, 255, 255);
    }
    final s = _FakeSession(List<double>.filled(4, 0.0));
    OnnxClipPanelClassifier(s, _unitPrompts(4), size: 2).scores(img);
    final input = s.lastInput!;
    expect(s.lastShape, [1, 3, 2, 2]);
    expect(input[0], closeTo((1.0 - 0.48145466) / 0.26862954, 1e-6));
    expect(input[4], closeTo((1.0 - 0.4578275) / 0.26130258, 1e-6));
    expect(input[8], closeTo((1.0 - 0.40821073) / 0.27577711, 1e-6));
  });

  test('余弦打分：嵌入正交基 → 各类分数独立', () {
    // 图像嵌入 = [0.1, 0.9, 0.2, 0.05] → 归一后与各类基向量的余弦。
    final s = _FakeSession(const [0.1, 0.9, 0.2, 0.05]);
    final scores =
        OnnxClipPanelClassifier(s, _unitPrompts(4), size: 2).scores(_panel());
    expect(scores.length, 4);
    final norm = 0.1 * 0.1 + 0.9 * 0.9 + 0.2 * 0.2 + 0.05 * 0.05;
    expect(scores[0], closeTo(0.1 / math.sqrt(norm), 1e-9), reason: 'action 分量');
    expect(scores[1], closeTo(0.9 / math.sqrt(norm), 1e-9), reason: 'atmosphere 最大');
    expect(scores[3], closeTo(0.05 / math.sqrt(norm), 1e-9));
  });

  test('输出维度与提示词维度不符 → 空表（不可用，回落启发式）', () {
    final s = _FakeSession(const [1.0, 2.0]); // 2 维 != 提示词 4 维
    expect(
        OnnxClipPanelClassifier(s, _unitPrompts(4), size: 2).scores(_panel()),
        isEmpty);
  });

  test('会话抛异常 / 零嵌入 → 空表（永不抛契约）', () {
    final img = _panel();
    expect(
        OnnxClipPanelClassifier(_ThrowingSession(), _unitPrompts(4), size: 2)
            .scores(img),
        isEmpty);
    expect(
        OnnxClipPanelClassifier(
                _FakeSession(List<double>.filled(4, 0.0)), _unitPrompts(4),
                size: 2)
            .scores(img),
        isEmpty,
        reason: '零向量嵌入 norm=0 → 空表');
  });

  test('ClassifierPanelStrategyJudge：置信覆盖、不置信与空表回落', () {
    final img = RgbaImage(width: 8, height: 8);
    for (var i = 0; i < 64; i++) {
      img.setPixel(i % 8, i ~/ 8, 200, 200, 200, 255);
    }
    final panels = [PixelRect(0, 0, 8, 8)];
    final subjects = [SubjectMask.empty(8, 8)];

    // 置信 action（分量 0 大胜）→ 覆盖为动作档（启发式本判氛围，被覆盖）。
    final confident = ClassifierPanelStrategyJudge(
        classifier: _FixedScores(const [0.5, 0.1, 0.1, 0.1]));
    final s1 = confident.panelStrategies(img, panels, subjects);
    expect(s1[0].tempo, kActionTempo, reason: '模型确信动作 → 覆盖启发式');

    // 不置信（top1−top2 < margin）→ 回退启发式（此页为氛围档）。
    final unsure = ClassifierPanelStrategyJudge(
        classifier: _FixedScores(const [0.11, 0.1, 0.1, 0.1]));
    final s2 = unsure.panelStrategies(img, panels, subjects);
    expect(s2[0].scale, kAtmosphereScale, reason: '不置信 → 启发式氛围档');

    // 空表（模型不可用）→ 回退。
    final broken = ClassifierPanelStrategyJudge(
        classifier: _FixedScores(const []));
    final s3 = broken.panelStrategies(img, panels, subjects);
    expect(s3[0].scale, kAtmosphereScale);

    // 置信 narrative → 覆盖为静止（模型可把启发式的动格压静）。
    final narrative = ClassifierPanelStrategyJudge(
        classifier: _FixedScores(const [0.1, 0.1, 0.1, 0.5]));
    final s4 = narrative.panelStrategies(img, panels, subjects);
    expect(s4[0].scale, 0.0);
  });
}

class _FixedScores implements PanelClassifier {
  const _FixedScores(this.values);
  final List<double> values;
  @override
  List<double> scores(RgbaImage panel) => values;
}
