/// Comic motion engine — pure Dart backend for turning static comic pages
/// into HarmonyOS-Reader-style layered motion (parallax / breathing / ambient).
///
/// The package is UI-free and can be embedded into any Dart/Flutter project.
library;

export 'src/batch_runner.dart';
export 'src/depth_splitter.dart';
export 'src/effect_config.dart';
export 'src/frame_compositor.dart';
export 'src/gif_writer.dart';
export 'src/image_io.dart';
export 'src/image_model.dart';
export 'src/motion_math.dart';
export 'src/ledger.dart';
export 'src/pipeline.dart';

/// CLI version constant re-exported for tooling.
const String comicMotionVersion = '1.0.0';
