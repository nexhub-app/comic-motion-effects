# Changelog

本项目版本记录。版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## Unreleased（0.1.0 候选）

初始版本。Flutter 伴生包，单向依赖核心包 `comic_motion`（核心包保持纯
Dart、零 Flutter 依赖）。

- **MotionGifView**：GIF 播放视图——`firstFramePng` 占位 crossfade 无缝
  过渡（默认 150ms，`Duration.zero` 直切）、`playing`/`loop` 外部驱动
  （`loop: false` 播完停在末帧）、系统「减弱动态」静帧
  （`MediaQuery.disableAnimations`，不解码动画）、V2 入场帧序列前置播放
  （播完 holdOnLast 后无缝切入 GIF 循环）、字节变更自动重置重建。
- **ParallaxGyroView**：V1 交互帧集跟手视差——三驱动（sensors_plus 陀螺仪
  `tiltToPhase` 欧拉角归一化 `maxTiltDeg` 默认 15°、~60fps 节流 + 0.01
  死区；触摸拖动回退「半视口 = 满相位」+ `returnToCenter` 回中；
  `tiltStream` 注入流，非空时不订阅传感器——测试 mock 与自定义驱动挂点）；
  插值 `smooth` 相邻帧 alpha 混合或最近帧直切。
- **纯 Dart 辅助**（可脱离 Flutter 单测）：`loadInteractionSets`（磁盘目录）
  / `loadInteractionSetsFromIndexJson`（index.json 字节 + 取帧回调，资产/
  网络/WASM 通用）、`tiltToPhase` / `degToRad`。
- 测试：倾斜相位、帧集加载契约（kind/axis 校验、帧数一致性）、widget 测试
  （注入流相位→帧映射、smooth 混合、触摸回退与回中、空帧集兜底、占位
  过渡、减弱动态、入场序列、字节变更重置）。

> 发布时序：本包消费 engine 的 V1/V2 API（`exportInteractionFrames` /
> `exportEntranceFrames`），engine 需先发布包含对应 API 的版本，并把本包
> `pubspec.yaml` 依赖下限提到该版本（见核心包 `doc/release_checklist.md`
> 第二节）。
