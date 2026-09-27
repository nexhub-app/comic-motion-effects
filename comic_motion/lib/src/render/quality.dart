/// 渲染质量档位。
///
/// [RenderTier.legacy] 逐字节复现 v1.2 的绘制与编码路径（回滚承诺的载体）；
/// [RenderTier.standard] 起启用抗锯齿光栅原语、面积平均重采样与 screen 光照
/// 混合。[RenderTier.rich] 目前与 standard 逐字节等价（已废弃，见其注释）。
library;

enum RenderTier {
  legacy,
  standard,

  /// 与 [standard] 渲染结果逐字节一致——预留的 `supersample` / `mipLevels`
  /// 尚无消费方。新代码请用 [standard]；JSON 的 `"tier": "rich"` 仍按本档
  /// 解析（废弃 ≠ 移除，按 README 兼容政策保留）。
  @Deprecated('rich renders byte-identical to standard; use RenderTier.standard')
  rich;

  bool get atLeastStandard => this != RenderTier.legacy;
  bool get supersample => this == RenderTier.rich;

  static RenderTier parse(Object? name) => RenderTier.values.firstWhere(
        (t) => t.name == name,
        orElse: () => RenderTier.legacy,
      );
}
