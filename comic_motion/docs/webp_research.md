# Animated WebP 输出：调研与路线建议（v1.3.1 调研结论）

> P2 任务「animated WebP 输出」的调研交付物。结论：**image 包（锁定 ≥4.10）
> 已具备动画 WebP 编码能力，无需自研或引第三方依赖**，建议作为 opt-in
> 新输出格式在后续版本实现。

## 一、image 包能力盘点（以 lock 锁定的 4.10.1 为准）

| 能力 | 状态 | 证据 |
|---|---|---|
| WebP 解码（VP8/VP8L/VP8X） | ✅ 早已支持 | `src/formats/webp/*`（引擎解码通路已在用） |
| VP8 有损编码 | ✅ | `vp8_encoder.dart` 全套（量化/率失真/概率模型/token） |
| VP8L 无损编码 | ✅ | `vp8l_encoder.dart`（huffman/backward refs/color cache/optimal parse） |
| **动画容器** | ✅ | `webp_encoder.dart`：`ANMF` chunk、`frameDuration`、`loopCount`、`hasAnimation` |
| alpha | ✅ | `alphaQuality` 参数 |
| 纯 Dart | ✅ | 与现有 `image` 依赖同包，无原生代码 |

对照说明：引擎 v1.3.0 定版时 `image ^4.2.2` 区间内的旧版**没有** WebP 编码器
（这正是当时搁置 WebP 的原因）；当前 lock 解析到 4.10.1，编码器已齐。

## 二、方案对比

| 维度 | A：image 包 WebPEncoder（推荐） | B：自研 VP8 编码 | C：引第三方（如 flutter_webp / FFI libwebp） |
|---|---|---|---|
| 依赖树 | 零新增 | 零新增 | 新增原生/FFI 依赖，破坏「纯 Dart」卖点 |
| 工作量 | 小（适配输出通路） | 极大（VP8 率失真 + 熵编码，人月级） | 中（绑定 + 各平台构建） |
| 逐字节复现 | 同锁定版本内确定 | 可控 | 受平台 libwebp 版本影响，**最难保证** |
| 体积收益 | lossy 下 GIF 的 1/3~1/2，lossless 也优于 GIF | 同左 | 同左 |
| 真彩色 | ✅（摆脱 256 色调色板） | ✅ | ✅ |
| Web/移动兼容 | 纯 Dart，全平台 | 纯 Dart | Android/iOS 可、Web/桌面差 |

## 三、推荐实现方案（A 的落地要点）

1. **opt-in 新档位**：`OutputFormat.webp`（或 `both` 扩展语义），不触碰既有
   GIF/PNG 路径，`legacy` 档逐字节契约不受影响。新增字段走条件序列化，
   未启用时 configHash 不变（红线 #2）。
2. **内存画像与流式差距**：`WebPEncoder` 需要整帧序列在内存
   （`image.addFrame` 模型），不像引擎 GIF 是流式 O(单帧)。1080p×96 帧约
   800MB，**必须限制帧数/分辨率或分块转码**。建议：
   - 先按 `maxFrames` 与 `memoryBudgetMb` 估算，超预算即降级到 GIF 并写
     `warnings`（复用 P1-3 降级语义）；
   - 中期再评估「分段编码 + WebP 相邻段拼接」或给 image 包提流式方案。
3. **参数暴露**：`webp: {lossless, quality, method}` 三参数，默认
   `lossless: false, quality: 80`；全部条件序列化。
4. **确定性验证**：同输入同参数编码两次逐字节对比 + 三平台 CI 各跑一遍，
   通过后才能进「复现承诺」清单（见 README 复现边界）。
5. **验收标准**：体积对比基准（bench 增 WebP 场景）；GIF↔WebP 同参产物
   视觉一致性抽检；`gif_check.dart` 对应的 `webp_check.dart` 严格解码校验。

## 四、GIF 帧间差分 与 条漫 strip 模式（同批 P2 设计提案）

### GIF 帧间差分（opt-in 编码选项）

- 现状：每帧全量 LZW。差分（disposal=do-not-dispose + 变化区域局部
  LZW）可降 2~5 倍，天气/粒子类效果收益最大（变化区域小）。
- 关键约束：**纯 opt-in**（`gif: {frameDiffing: true}` 条件序列化），
  默认关闭，legacy 档永远全量编码——逐字节契约零风险。
- 实现要点：合成时按帧与前一帧做像素 diff（允许每帧一个矩形 bounding
  box 即可，GIF 单帧只支持一个区域）；粒子效果天然稀疏，bbox 常小于
  全图 1/4；对全帧大面积变化（toneShift/lightSweep）自动回退全量帧。
- 验收：`gif_check.dart` 逐帧解码校验 + 与全量编码的视觉逐帧等价 +
  体积基准进 bench。

### 条漫 strip 模式（长图切片）

- API：`MotionPipeline.processStrip(input, {sliceHeight, overlap})` →
  逐片 `<stem>_<hash8>/slice_NNN/anim.gif`。
- 效果白名单（跨片独立渲染安全集）：rain / snow / fog / sakura / embers /
  fireflies / godRays / starlight / lightning / shimmer / lightSweep /
  dust / bubbles / leaves / meteors / flame / smoke / vignette /
  toneShift —— 这些是逐像素/局部效果，切片间无耦合。
- parallax 类（parallax/breathing/slowPush/heartbeat/漫画动势五件）跨
  分格会错位，标 `experimental`：允许传入但文档声明切片边界视差不连续。
- 切片处深度分层独立估算（每片自带 DepthEstimator），重叠带（建议
  ≥64px）用于过渡融合。
