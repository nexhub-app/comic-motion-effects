import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';

import 'onnx_depth_estimator.dart' show DepthSession;

/// CLIP 零样本面板分类器（Phase E'）：图像塔 ONNX（如 ViT-B/32，224²）+
/// **离线预计算的提示词嵌入**（prepare_clip_prompts.py 产出的 JSON，与
/// [PanelClass.values] 对齐）——端侧只跑图像塔，余弦相似度打分，无文本塔。
///
/// - 预处理：双线性 224² + CLIP 归一化（mean 0.481/0.458/0.408，
///   std 0.269/0.261/0.276）+ NCHW。
/// - 打分：图像嵌入与各提示词嵌入分别 L2 归一后取余弦（∈[-1,1]，
///   [ClassifierPanelStrategyJudge] 的 margin 在此尺度上工作）。
/// - 契约：**永不抛**（形状不符/维度不匹配 → 空表，判断器回落启发式）。
///
/// 会话必须在目标 isolate 内创建（与 [OnnxDepthEstimator] 同约定）。
class OnnxClipPanelClassifier extends PanelClassifier {
  OnnxClipPanelClassifier(this.session, this.promptEmbeddings,
      {this.size = 224});

  final DepthSession session;

  /// 与 [PanelClass.values] 对齐的提示词嵌入（任意维，须与模型输出维一致）。
  final List<List<double>> promptEmbeddings;

  /// 图像塔输入边长（正方形）。默认 224 = CLIP ViT-B/32。
  final int size;

  static const List<double> _mean = <double>[
    0.48145466,
    0.4578275,
    0.40821073
  ];
  static const List<double> _std = <double>[
    0.26862954,
    0.26130258,
    0.27577711
  ];

  @override
  List<double> scores(RgbaImage panel) {
    try {
      final s = size;
      final input = Float32List(3 * s * s);
      final sx = panel.width / s, sy = panel.height / s;
      final px = List<int>.filled(4, 0);
      for (var y = 0; y < s; y++) {
        for (var x = 0; x < s; x++) {
          panel.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, px);
          input[0 * s * s + y * s + x] = (px[0] / 255.0 - _mean[0]) / _std[0];
          input[1 * s * s + y * s + x] = (px[1] / 255.0 - _mean[1]) / _std[1];
          input[2 * s * s + y * s + x] = (px[2] / 255.0 - _mean[2]) / _std[2];
        }
      }
      final emb = session.run(input, <int>[1, 3, s, s]);
      if (emb.isEmpty || emb.length != promptEmbeddings.first.length) {
        return const <double>[];
      }
      // 图像嵌入 L2 归一。
      var norm = 0.0;
      for (final v in emb) {
        norm += v * v;
      }
      if (norm <= 1e-12) return const <double>[];
      final inv = 1.0 / math.sqrt(norm);
      // 与各提示词嵌入的余弦。
      return [
        for (final p in promptEmbeddings) _cosine(emb, inv, p),
      ];
    } catch (_) {
      return const <double>[];
    }
  }

  static double _cosine(List<double> a, double aInv, List<double> b) {
    var dot = 0.0;
    var nb = 0.0;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
      nb += b[i] * b[i];
    }
    if (nb <= 1e-12) return 0.0;
    return dot * aInv / math.sqrt(nb);
  }
}
