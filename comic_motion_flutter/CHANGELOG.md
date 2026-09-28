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

### 第五轮 W1：PageCurlView 仿真卷页翻页

- **PageCurlView**：`realtime/index.html` Canvas 参考实现的 Flutter 移植，
  对齐鸿蒙翻页手感的五种行为——卷页曲率（纵向条带 + 圆柱投影压缩近似，
  拖拽速度决定软硬，`curlStrips` 默认 28）、拖拽跟手（进度 = 位移/视宽）、
  松手回弹过冲（阈值/速度双判据 + 1.045 峰值 rubber-band，未过阈值原路
  弹回）、双层光影（条带高光/纸背透色/折轴落影/页缘阴影）、idle 呼吸
  微动（±0.4%、6s 周期，画布变换零栅格成本）。
- **页面内容按需截屏**（第五轮方案确认）：平时显示原生 widget；拖拽/
  点击翻页开始的瞬间经 RepaintBoundary 抓 front/back 两页 `ui.Image`
  （pixelRatio 钳制 [1,3]、长边 2048 封顶），截屏失败退化为瞬时切页；
  提交翻页时目标页快照直接晋升为当前页快照（零重复截屏）。
- **性能**：手势帧 `CustomPainter` + repaint listenable 局部重绘——零
  widget 重建、builder 子树按页码缓存不重调；页码/内容源变更自动失效
  重抓。
- **钩子与回退**：`onPageTurnStart`/`onPageTurnEnd` 供 App 自接音效/触觉
  （不引 audio/vibration 依赖）；系统「减弱动态」回退平移淡入淡出
  （不截屏、无呼吸）；`enableTapTurn` 点击半屏翻页、页边界保护、
  `initialPage`/`turnDuration`/`commitThreshold`/`commitVelocity` 可调。
- 测试：点击翻页回调时序（Start 起步触发、End 补间完成 committed）、
  页边界保护、短拖回弹（committed=false）、长拖提交、进度跟手映射
  （`progressOf` 测试探针）、减弱动态换页、拖拽帧零 builder 重调、
  销毁冒烟。example 新增卷页翻页演示页。

> 发布时序：本包消费 engine 的 V1/V2 API（`exportInteractionFrames` /
> `exportEntranceFrames`），engine 需先发布包含对应 API 的版本，并把本包
> `pubspec.yaml` 依赖下限提到该版本（见核心包 `doc/release_checklist.md`
> 第二节）。
