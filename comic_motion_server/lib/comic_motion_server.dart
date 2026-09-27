/// CLI and HTTP API service for the [comic_motion] engine.
///
/// The engine itself lives in `package:comic_motion` and has no dependency
/// on this package; embedders who only need the rendering pipeline should
/// depend on that package alone.
library;

export 'src/api_service.dart';
export 'src/cli.dart';
