# comic_motion_depth_onnx

ONNX (MiDaS) on-device depth estimator for
[comic_motion](https://pub.dev/packages/comic_motion): implements the
engine's `DepthEstimator` seam with `onnxruntime_v2`. **Opt-in** — the core
engine keeps zero native dependencies; pulling in this package (and the
ONNX runtime it wraps) is the host's decision.

## Model

- MiDaS v2.1 small, 256×256 input, **QDQ static int8** (~17.6 MB).
- The host supplies the model bytes (download / cache / bundled asset —
  your policy); this package does no networking and no disk caching.
- QDQ (quantize-dequantize) is the only quantization layout this runtime
  loads for this model — dynamic int8 does not load.
- Works on every platform `onnxruntime_v2` supports. Windows CPU EP is
  verified end-to-end; Android / iOS / macOS / Linux follow that plugin's
  matrix and are not individually verified — if a platform fails, check
  the execution-provider loading first.

## Usage

```dart
import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_depth_onnx/comic_motion_depth_onnx.dart';

final result = await processBytesInBackground(
  input: pageBytes,
  config: EffectConfig.fromJson(const {
    'effects': ['parallax'],
    'fps': 12,
    'durationSec': 3.0,
    'maxDimension': 720,
    'layerCount': 3,
    'panelAware': false,
    'outputFormat': 'gif',
    'seed': 7,
    'holdSec': 4.0,
  }),
  // ML depth + region-coherent wrap (stable inside author-drawn regions).
  depthEstimatorFactory: () => RegionCoherentDepthEstimator(
      inner: OnnxDepthEstimator(OrtSessionAdapter.fromFile(modelPath)),
      detailMinArea: 64),
  // Motion gate: pages whose (region-wrapped) depth spread is too flat
  // render as a single static frame instead of a pointless animation.
  motionGateFactory: () => const DepthSpreadGate(),
);
```

## Threading & lifecycle

- Sessions and native handles must be created **inside the isolate that
  uses them**. Pass a factory (as above) to the background entries — the
  factory runs once inside the pipeline isolate. Never construct an
  `OrtSessionAdapter` on the UI isolate and ship the instance over.
- One session per pipeline run is the supported pattern. Long-lived hosts
  may hold a session themselves and release it per `onnxruntime_v2`'s
  semantics (`OrtSession.release()`); this package adds no global state
  beyond `OrtEnv`.
- Unit tests in this package run against a fake `DepthSession`; the
  real-model integration test self-skips when the model file is absent
  (override the path with `MIDAS_QDQ_MODEL`).

## Known limitations

- CPU execution provider only (no GPU/NNAP configuration surface yet).
- The estimator returns a 256×256 depth map (model input size); the
  engine's region-coherent wrapper upsamples it to the working resolution.
- Not verified: GPU EPs, mobile platforms, web (unsupported by
  `onnxruntime_v2`).
