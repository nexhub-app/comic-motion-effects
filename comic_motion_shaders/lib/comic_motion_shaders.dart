/// comic_motion_shaders —— GPU 实时化伴生包（W7 MVP）。
///
/// 消费核心包 comic_motion W6 `exportLayers` 导出的分层纹理，
/// 用单一 uber-shader（uniform 开关切换）实时渲染四件参数化变换效果：
/// parallax（分层视差）/ breathing（呼吸缩放）/ lightSweep（扫光）/
/// vignette（暗角）。粒子类效果的 GPU 化为后续版本（见 roadmap）。
///
/// 确定性说明：实时路径由 uniform（时钟/交互）驱动，无 seed 概念，
/// 核心包的逐字节复现契约不适用于本包。
library;

export 'src/layer_loader.dart' show decodeLayerTextures;
export 'src/motion_uniforms.dart'
    show
        MotionUniforms,
        kFloatCount,
        kMaxLayers,
        sweepPositionFor;
export 'src/realtime_motion_view.dart' show RealtimeMotionView, kShaderAsset;
