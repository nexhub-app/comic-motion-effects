import 'pipeline.dart';

import 'effect_config.dart';

/// 渲染成本预评估（R9）：基于既有桌面 bench 数据（`tool/bench.dart`）拟合
/// 的**经验估算**，供 App 在渲染前判断低端机可行性。
///
/// 拟合锚点（legacy 档、核心三效果、parallel=8 桌面数据）：
/// - 480p 草稿（~0.41Mpx × 24 帧）→ 峰值 RSS 377MB、233ms
/// - 1080p 典型（~2.07Mpx × 96 帧）→ 峰值 RSS 534MB、2.25s
/// - 1600 上限（1600×900 × 96 帧）→ 峰值 RSS 607MB、3.49s
/// - 1080p standard 档 4.26s；1080p 全 32 效果 standard 5.20s、628MB
///
/// RSS 与像素的关系受 VM 基线 / GC 波动影响很大，因此输出的是**区间**：
/// 下界为 parallel=1 的模型画像，上界为桌面默认并行度（kDefaultParallel）
/// 的保守画像 + VM 基线余量。低端机可行性判断**以 max 端为准**。
///
/// 所有数值均为经验估算，不构成性能承诺；真机参考区间另见 README。
class CostEstimate {
  const CostEstimate({
    required this.minPeakMemoryMb,
    required this.maxPeakMemoryMb,
    required this.minDurationMs,
    required this.maxDurationMs,
    required this.frameCount,
    required this.workingWidth,
    required this.workingHeight,
  });

  /// 估算峰值内存下界（MB，parallel=1 模型画像）。
  final int minPeakMemoryMb;

  /// 估算峰值内存上界（MB，桌面默认并行保守画像；低端机可行性以此判断）。
  final int maxPeakMemoryMb;

  /// 估算耗时下界（ms，桌面多核理想情形）。
  final int minDurationMs;

  /// 估算耗时上界（ms，低端单核近似）。
  final int maxDurationMs;

  /// 实际将渲染的帧数（frameCount，含 reducedMotion 静帧）。
  final int frameCount;

  /// 工作分辨率（maxDimension 降采样后）。无源尺寸时为保守正方形估计。
  final int workingWidth;
  final int workingHeight;

  /// 固定声明：经验估算、非承诺。
  String get note =>
      'empirical estimate fitted from desktop bench data; not a performance '
      'promise - judge low-end feasibility by the max bounds';

  Map<String, dynamic> toJson() => {
        'minPeakMemoryMb': minPeakMemoryMb,
        'maxPeakMemoryMb': maxPeakMemoryMb,
        'minDurationMs': minDurationMs,
        'maxDurationMs': maxDurationMs,
        'frameCount': frameCount,
        'workingWidth': workingWidth,
        'workingHeight': workingHeight,
        'note': note,
      };

  @override
  String toString() =>
      'CostEstimate(mem ${minPeakMemoryMb}..${maxPeakMemoryMb}MB, '
      'time ${minDurationMs}..${maxDurationMs}ms, '
      'frames $frameCount, working ${workingWidth}x$workingHeight)';
}

/// 估算一次渲染的内存/耗时区间。
///
/// [sourceWidth]/[sourceHeight] 提供时按 [EffectConfig.maxDimension] 推导
/// 实际工作分辨率；缺省时按 `maxDimension × maxDimension` 保守估计（偏大
/// 偏贵，适合「宁可信其不可行」的低端机预判）。
///
/// `parallel`/`memoryBudgetMb` 为执行期参数、不在 config 内：内存区间已
/// 覆盖 parallel=1（下界）与桌面默认并行（上界）两种画像。
CostEstimate estimateCost(EffectConfig config,
    {int? sourceWidth, int? sourceHeight}) {
  final maxDim = config.maxDimension;
  int w;
  int h;
  if (sourceWidth != null &&
      sourceHeight != null &&
      sourceWidth > 0 &&
      sourceHeight > 0) {
    final scale =
        maxDim / (sourceWidth > sourceHeight ? sourceWidth : sourceHeight);
    final s = scale < 1.0 ? scale : 1.0;
    w = (sourceWidth * s).round().clamp(1, maxDim);
    h = (sourceHeight * s).round().clamp(1, maxDim);
  } else {
    // 无源尺寸：保守正方形（偏大偏贵）。
    w = maxDim;
    h = maxDim;
  }
  final px = w * h;
  final frames = config.frameCount;

  // 内存：与管线预算模型同款保守公式（每 worker 一整套层栅格）。
  final perWorkerMb = px * 4 * (config.layerCount + 2) * 1.5 / (1024 * 1024);
  const vmBaseMb = 128.0;
  final minMem = (vmBaseMb + 2 * perWorkerMb).round();
  final maxMem = (384 + (kDefaultParallel + 1) * perWorkerMb).round();

  // 耗时：bench 拟合的 ns/帧像素。legacy 桌面多核 ~12ns、低端单核 ~100ns；
  // standard+（抗锯齿 + 面积平均）与重特效上探更高。
  final standard = config.quality.tier.atLeastStandard;
  final nsPerFramePxMin = standard ? 22.0 : 12.0;
  final nsPerFramePxMax = standard ? 160.0 : 100.0;
  final framePx = px.toDouble() * frames;
  final minMs = (framePx * nsPerFramePxMin / 1e6).round().clamp(1, 1 << 40);
  final maxMs = (framePx * nsPerFramePxMax / 1e6).round();

  return CostEstimate(
    minPeakMemoryMb: minMem,
    maxPeakMemoryMb: maxMem,
    minDurationMs: minMs,
    maxDurationMs: maxMs,
    frameCount: frames,
    workingWidth: w,
    workingHeight: h,
  );
}
