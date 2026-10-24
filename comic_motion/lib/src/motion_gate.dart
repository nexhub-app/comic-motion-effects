import 'depth_splitter.dart';
import 'image_model.dart';

/// 动效门槛接缝（运行期依赖）：管线在深度估算之后、帧渲染之前询问
/// 「该页该不该动」。返回 false 时输出与 `reducedMotion` 同形态的
/// 单帧静态图。
///
/// 与 [DepthEstimator] 同级：执行期依赖，不进 EffectConfig、不参与
/// configHash；缺省 null = 永远动画（既有路径逐字节零变化）。
abstract class MotionGate {
  const MotionGate();

  /// [working] 为工作分辨率底图；[depths] 为本页深度图——整页路径一张，
  /// panelAware 多格路径逐格一张（顺序与层生成序一致）。
  bool shouldAnimate(RgbaImage working, List<DepthMap> depths);
}

/// A1 分布勘察定值（30 页样本 region-wrapped 深度 spread）：样本全部为
/// 内容页（最低 0.2256），连续无谷——真平坦页（近空白）恒值场 spread
/// 近 0，故取最低内容页一半作安全余量。只许数据改它，不许对任何单页调它。
const double kDefaultDepthSpreadMin = 0.11;

/// A1 分布勘察定值：region-wrapped 深度 spread 的 60 分位（最近秩，实测
/// 0.6534，取 0.65）——内容页典型幅度基准。视差幅度按
/// clamp(spread / kRef, 0, 1) 缩放：浅深度页面按比例少动，减少视差割裂感；
/// ≥kRef 的页面满幅。
const double kDepthSpreadRef = 0.65;

/// 内置门槛：深度分位跨度（p90-p10）低于 [minSpread] 判为「深度平坦」，
/// 不值得动。跨格路径任一格达标即动画（一格有内容就该动那一格）。
class DepthSpreadGate extends MotionGate {
  const DepthSpreadGate({this.minSpread = kDefaultDepthSpreadMin});

  final double minSpread;

  @override
  bool shouldAnimate(RgbaImage working, List<DepthMap> depths) {
    for (final d in depths) {
      if (depthSpread(d) >= minSpread) return true;
    }
    return false;
  }
}

/// 深度分位跨度 p90-p10（最近秩分位，与 LayerSplitter 阈值分位同口径）。
/// OnnxDepthEstimator 输出已 min-max 归一化 → 值域 [0,1] 可跨图比较；
/// 内置 HeuristicDepthEstimator 同为 min-max 归一化的平滑场，spread 接近 1，
/// 默认路径不会被误伤。
double depthSpread(DepthMap d) {
  final sorted = List<double>.from(d.data)..sort();
  double q(double p) => sorted[(p * (sorted.length - 1)).round()];
  return q(0.90) - q(0.10);
}
