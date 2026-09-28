# comic_motion_shaders

GPU 实时化伴生包（W7 MVP）：用单一 uber-shader（uniform 开关切换）实时渲染
分层纹理动效——**parallax（分层视差）/ breathing（呼吸缩放）/ lightSweep（扫光）/
vignette（暗角）**。输入为核心包 `comic_motion` W6 `exportLayers` 导出的
分层纹理集（RGBA PNG，远→近序）。粒子类效果的 GPU 化为后续版本（见
核心包 `doc/roadmap.md`）。

本包独立于核心包与 `comic_motion_flutter`，不进核心依赖图。

## 实时 shader vs 预渲染帧集：怎么选

| 维度 | RealtimeMotionView（本包） | MotionGifView / ParallaxGyroView（flutter 包） |
|---|---|---|
| 原理 | FragmentShader 每帧实时采样分层纹理 | 预渲染 GIF 帧集 / 交互帧序列 |
| 精度 | 无限精度（uniform 连续可变，无帧率上限） | 受预渲染 fps 与帧数约束 |
| 功耗 | GPU 持续参与（每帧计算） | 解码后播放，GPU 占用低 |
| 适配设备 | 高配手机 / 桌面端 / 大屏 | 低端设备 / 列表流 / 批量卡片 |
| 一致性 | 时钟驱动，每次观感略异（相位随机起点） | 逐字节复现契约（同 seed 同 config） |
| 交互跟手 | 视差 uniform 即时响应（触摸/陀螺仪直驱） | ParallaxGyroView 帧序列插值 |

**选择指引**：详情页大图、翻页、交互密集的「主视觉」用本包；列表流缩略图、
多卡片同屏、低端机型兜底用帧集。两者消费同一份 `exportLayers` 分层产物，
观感可对齐。

## 确定性说明

核心包的逐字节复现契约（同 seed + 同 config → 同输出字节）**不适用于
本包**：实时路径由 uniform（时钟/交互）驱动，无 seed 概念，输出随时间
连续变化。分层纹理本身仍是确定性导出。

## uniform 契约

`assets/shaders/comic_motion.frag` 声明 19 个 float uniform + 4 个 sampler；
Dart 侧 `MotionUniforms.toFloats()` 按下表索引序列化（`kIndex*` 常量即此表）。
改动任一侧必须同步另一侧并更新本表。

| 索引 | uniform | 含义 | 值域（钳制后） |
|---|---|---|---|
| 0 | uParallaxOn | 视差开关 | 0/1 |
| 1 | uParallaxX | 最大 uv 偏移（画布宽分数） | [-1, 1] |
| 2 | uParallaxY | 最大 uv 偏移（画布高分数） | [-1, 1] |
| 3–6 | uDepth0..3 | 层深度因子（0 = 基准层不位移） | [0, 1]，定长 4 |
| 7 | uBreathingOn | 呼吸开关 | 0/1 |
| 8 | uZoom | 呼吸幅度 | [0, 0.5] |
| 9 | uPhase | 呼吸相位（宿主时钟） | [0, 1] |
| 10 | uSweepOn | 扫光开关 | 0/1 |
| 11 | uSweepPos | 扫光中心（可滑入滑出） | [-0.5, 1.5] |
| 12 | uSweepWidth | 扫光半带宽 | [1e-4, 0.5] |
| 13 | uSweepIntensity | 扫光强度 | [0, 1] |
| 14 | uVignetteOn | 暗角开关 | 0/1 |
| 15 | uVignetteStrength | 暗角强度 | [0, 1] |
| 16 | uVignetteSoftness | 暗角柔度 | [0, 1] |
| 17–18 | uSize | 画布像素尺寸 | > 0 |
| sampler 0–3 | uTex0..3 | 分层纹理（远→近，即 exportLayers 层序） | — |

层纹理不足 4 张时宿主侧以 1x1 透明纹理占位空槽；层数上限 4。
panelAware（分格感知）层 PNG 为「全画布透明 + 格内内容」，alpha 混合
天然不串色，本 shader 不消费 clip 元数据（MVP 简化）。

## 用法

```dart
import 'package:comic_motion_shaders/comic_motion_shaders.dart';

// 1. 拿到 W6 导出的分层 PNG 字节（exportLayers 内存结果或落盘 layer_NN.png）
final layers = await decodeLayerTextures(layerPngBytes); // 远→近序，≤4 层

// 2. 实时渲染（视差可由触摸/陀螺仪直驱；呼吸/扫光由内部 Ticker 驱动）
RealtimeMotionView(
  layers: layers,
  parallaxShift: Offset(dx, dy), // 手势/传感器回调里 setState 更新
  breathing: true,
  sweep: true,
  vignette: false,
);
```

`layers` 所有权归调用方，不再使用时自行 `dispose()`。
完整演示见 `example/`（程序化占位层 + slider 实时调参）：

```bash
cd example && flutter run
```

## 平台支持矩阵

FragmentShader（`FragmentProgram.fromAsset`）要求 Flutter 3.7+ 与
Impeller/Skia 的 SPIR-V 支持。以下矩阵由实测回填（当前未在真机验证，
以 Flutter 官方支持矩阵为准）：

| 平台 | 后端 | 状态 |
|---|---|---|
| Android | Impeller | 预期可用，待真机回填 |
| Android | Skia（旧机型） | 预期可用，待真机回填 |
| iOS | Impeller | 预期可用，待真机回填 |
| Windows / macOS / Linux | Skia | 预期可用，待真机回填 |
| Web | CanvasKit / SKSL | FragmentShader 路径受限，待验证 |

若目标 Flutter 版本在特定平台禁用 fragment shader，本包视图会因
`FragmentProgram.fromAsset` 失败而保持 `SizedBox.shrink()`（安全降级，
不崩溃）。

## 测试

```bash
flutter test # uniform 映射逻辑单测（布局契约/钳制/时钟映射）
```
