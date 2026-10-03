/// 渲染质量档位。
///
/// [RenderTier.legacy] 冻结的是 v1.2 的**像素算法**（不抗锯齿的光栅、双线性/
/// 最近邻重采样、纯 source-over 落墨、v1.2 量化通路）；v1.4 起它**不再**承诺
/// 「输出与 v1.2 逐字节一致」——改时间基的无缝修复（整数周期对齐 R18、竖向整数
/// 循环数 R19）与层反相相位常数（R16）对两条臂同时生效，不受档位门控（H2）。
/// [RenderTier.standard]（v1.4 出厂默认）起启用抗锯齿光栅原语、面积平均重采样与
/// screen 光照混合。[RenderTier.rich] 目前与 standard 逐字节等价（已废弃，见其注释）。
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
