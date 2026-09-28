# Changelog

## 0.1.0 (W7)

- 新增 `RealtimeMotionView`：FragmentShader 实时渲染分层纹理（消费核心包
  W6 `exportLayers` 产物），Ticker 驱动呼吸相位与扫光位置，视差 uniform
  由外部信号（触摸/陀螺仪）直驱；`playing=false` 冻结时钟。
- 新增 uber-shader `assets/shaders/comic_motion.frag`（单一 fragment
  shader + uniform 开关切换四件参数化变换效果：parallax / breathing /
  lightSweep / vignette；4 sampler 分层输入，空槽 1x1 透明纹理占位）。
- 新增 `MotionUniforms`：uniform 映射纯逻辑（布局契约常量 `kIndex*`、
  值域钳制、深度因子定长化 `depthFactors`）。
- 新增 `decodeLayerTextures`：W6 分层 PNG 字节 → `ui.Image` 列表（上限 4 层）。
- example：程序化占位分层纹理 + slider/FilterChip 实时调参演示。
- 测试：uniform 布局契约/钳制/时钟映射单测（shader 本体渲染依赖运行时，
  golden 测试标注为可选后续项）。
