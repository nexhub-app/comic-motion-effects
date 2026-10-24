import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';

import 'onnx_depth_estimator.dart' show DepthSession;

/// u2netp 主体分割器（Phase D）：把 comic_motion 的 [SubjectSegmenter]
/// 接缝接到 onnxruntime_v2（U²-Net 轻量版 u2netp，QDQ 静态 int8，约
/// 1.5-2MB）。与 [OnnxDepthEstimator] 同款架构：会话经 [DepthSession]
/// 注入（onnxruntime 类型隔离 + 单测假会话），预处理/后处理与官方 U²-Net
/// 数据装载器逐行对应。
///
/// - 预处理：双线性缩放到 `size×size`（默认 320 = u2netp 输入）+ /255 +
///   ImageNet mean/std（官方 data_loader 口径，绿色通道 std=0.227）+ NCHW。
/// - 后处理：u2netp 导出图的第一个输出即最终 sigmoid 概率图（d0），**直通
///   不做 min-max 归一化**（归一会破坏「显著性概率」语义）；像素空间重采样
///   与连通域分析交给 core 的 [SubjectMask.fromProbability]。
///
/// 会话必须在目标 isolate 内创建（后台入口
/// `processBytesInBackground(subjectSegmenterFactory: …)`，与深度工厂同一
/// 传递语义）。模型字节由宿主供给，本包不做网络与磁盘缓存。
class OnnxSubjectSegmenter extends SubjectSegmenter {
  OnnxSubjectSegmenter(
    this.session, {
    this.size = 320,
    this.mean = const [0.485, 0.456, 0.406],
    this.std = const [0.229, 0.227, 0.225],
    String? cacheTag,
    this.minBlobFrac = kSubjectMinBlobFrac,
    this.minBlobArea = kSubjectMinBlobArea,
  }) : _cacheTag = cacheTag;

  final DepthSession session;

  /// 模型输入边长（正方形）。默认 320 = u2netp。
  final int size;

  /// 预处理归一化参数（官方 U²-Net data_loader 口径）。
  final List<double> mean;
  final List<double> std;

  /// 碎域过滤参数（透传 [SubjectMask.fromProbability]）。
  final double minBlobFrac;
  final int minBlobArea;

  final String? _cacheTag;

  @override
  String get cacheTag => _cacheTag ?? 'u2netp$size';

  @override
  SubjectMask segment(RgbaImage panel) {
    // 增强通路契约「永不抛」：任何失败（模型缺失/形状不符/推理异常）降级
    // 为空掩码，管线回落到不钳制的既有行为，渲染不中断。
    try {
      final s = size;
      final input = Float32List(3 * s * s);
      final sx = panel.width / s, sy = panel.height / s;
      final px = List<int>.filled(4, 0);
      for (var y = 0; y < s; y++) {
        for (var x = 0; x < s; x++) {
          panel.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, px);
          input[0 * s * s + y * s + x] = (px[0] / 255.0 - mean[0]) / std[0];
          input[1 * s * s + y * s + x] = (px[1] / 255.0 - mean[1]) / std[1];
          input[2 * s * s + y * s + x] = (px[2] / 255.0 - mean[2]) / std[2];
        }
      }
      final prob = session.run(input, <int>[1, 3, s, s]);
      if (prob.length != s * s) {
        throw StateError('unexpected prob size ${prob.length} != ${s * s}');
      }
      return SubjectMask.fromProbability(
        prob: prob,
        probWidth: s,
        probHeight: s,
        width: panel.width,
        height: panel.height,
        minBlobFrac: minBlobFrac,
        minBlobArea: minBlobArea,
      );
    } catch (_) {
      return SubjectMask.empty(panel.width, panel.height);
    }
  }
}
