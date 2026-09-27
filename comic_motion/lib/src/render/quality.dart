/// 渲染质量档位。
///
/// [RenderTier.legacy] 逐字节复现 v1.2 的绘制与编码路径（回滚承诺的载体）；
/// [RenderTier.standard] 起启用抗锯齿光栅原语、面积平均重采样与 screen 光照
/// 混合。[RenderTier.rich] 目前与 standard 等价：[supersample] 尚无消费方。
library;

enum RenderTier {
  legacy,
  standard,
  rich;

  bool get atLeastStandard => this != RenderTier.legacy;
  bool get supersample => this == RenderTier.rich;

  static RenderTier parse(Object? name) => RenderTier.values.firstWhere(
        (t) => t.name == name,
        orElse: () => RenderTier.legacy,
      );
}
