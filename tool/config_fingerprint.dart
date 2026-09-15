import 'package:comic_motion/comic_motion.dart';

/// Prints config fingerprints (hash + canonical JSON) for regression locking.
/// Run: dart run tool/config_fingerprint.dart
void main() {
  final cases = <String, EffectConfig>{
    'default': EffectConfig(),
    'demo_640': EffectConfig(
        fps: 12, durationSec: 3.0, maxDimension: 640),
  };
  for (final e in cases.entries) {
    print('== ${e.key} ==');
    print(e.value.configHash);
    print(e.value.toJsonString());
    print('');
  }
}
