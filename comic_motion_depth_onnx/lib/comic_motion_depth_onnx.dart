/// 端侧 ONNX 深度估算适配包：把 comic_motion 的 DepthEstimator 接缝接到
/// onnxruntime_v2（MiDaS v2.1 small 256，QDQ 静态 int8，17.6MB）。
///
/// 会话与原生句柄必须在目标 isolate 内创建（后台入口请用
/// `processBytesInBackground(depthEstimatorFactory: …)`，工厂在管线 isolate
/// 内执行——与引擎探针验证过的路径一致）。模型字节由宿主供给（下载/缓存/
/// 资产由宿主决定），本包不做任何网络与磁盘缓存。
library;

export 'src/onnx_depth_estimator.dart';
export 'src/onnx_subject_segmenter.dart';
export 'src/onnx_clip_panel_classifier.dart';
