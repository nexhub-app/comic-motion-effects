/// Comic motion engine — pure Dart backend for turning static comic pages
/// into HarmonyOS-Reader-style layered motion (parallax / breathing / ambient).
///
/// The package is UI-free and can be embedded into any Dart/Flutter project.
library;

export 'src/background.dart';
export 'src/batch_runner.dart';
export 'src/cache_manager.dart';
export 'src/cancellation.dart';
export 'src/config_io.dart';
export 'src/cost_estimate.dart';
export 'src/depth_splitter.dart';
export 'src/effect_config.dart';
export 'src/entrance.dart';
export 'src/frame_compositor.dart';
export 'src/gif_writer.dart';
export 'src/guard.dart';
export 'src/image_io.dart';
export 'src/image_model.dart';
export 'src/interaction.dart';
export 'src/json_compat.dart';
export 'src/motion_math.dart';
export 'src/ledger.dart';
export 'src/param_catalog.dart';
export 'src/pipeline.dart';
export 'src/render/envelope.dart';
export 'src/render/quality.dart';
export 'src/render/raster.dart';
export 'src/render/resampler.dart';
export 'src/strip.dart';
export 'src/version.dart';
export 'src/worker_pool.dart';
