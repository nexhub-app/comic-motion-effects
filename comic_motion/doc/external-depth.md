# External depth estimation (W6) — bring your own model

The engine's built-in `HeuristicDepthEstimator` is a pure-Dart heuristic
(ink density / local contrast / skin-tone cues) tuned for line art. For
photographic or dense 3D-ish artwork you may want a real ML depth model.
The core package stays **pure Dart with zero native dependencies** — the
model runs on the embedding side (App), and only the resulting depth map
crosses the boundary.

## The interface

```dart
abstract class DepthEstimator {
  /// Returns a depth map with values in [0,1] (0 = far, 1 = near).
  /// Any resolution works — the engine maps it back to the working
  /// resolution via nearest (legacy tier) or bilinear sampling
  /// (standard+ tier).
  DepthMap estimate(RgbaImage img);
}
```

Inject per pipeline instance (execution-time dependency — **not** part of
the configHash):

```dart
final pipeline = MotionPipeline(
  config,
  depthEstimator: MyTfliteDepthEstimator(), // null = built-in heuristic
);
final result = await pipeline.processFile(input, outDir);
```

Omitting the parameter keeps pixel output byte-identical to versions
before the interface existed (locked by tests).

## Implementing a tflite adapter (App side)

The model runs in your app (e.g. `tflite_flutter` plugin), produces a
float depth tensor, and the adapter maps it into `DepthMap`:

```dart
import 'dart:typed_data';
import 'package:comic_motion/comic_motion.dart';

class MyTfliteDepthEstimator implements DepthEstimator {
  MyTfliteDepthEstimator(this._runner); // your model handle

  final MyModelRunner _runner; // wraps tflite interpreter, lazy-loaded

  @override
  DepthMap estimate(RgbaImage img) {
    // 1) Feed the RGBA raster to the model (downscale to the model's
    //    input size, e.g. 256x256, normalize to [0,1]).
    // 2) Run inference → float tensor of relative depth.
    // 3) Normalize to [0,1] and flip if your model outputs inverse depth
    //    (MiDaS-style: smaller = nearer).
    final values = _runner.run(img); // Float32List, modelW x modelH in [0,1], 1 = near
    // 4) Wrap into DepthMap — any resolution, bilinear-mapped by the engine.
    return DepthMap(modelW, modelH, values);
  }
}
```

Practical notes:

1. **Orientation**: the engine treats **larger values as nearer**. Models
   like MiDaS output inverse depth (smaller = nearer) — invert before
   wrapping.
2. **Resolution**: any model output size works; the engine resamples.
   Feed the model at its native input size (256²–512² is plenty) — do
   **not** run inference at full working resolution.
3. **Isolates**: run inference on a background isolate and inject a
   synchronous `estimate` that reads a pre-computed map, or compute the
   map before entering the pipeline. The estimator is called once per
   panel; since v1.4 `panelAware` is on by default, a multi-panel page
   calls it once per panel (single-panel / no-gutter pages and
   `panelAware: false` call it once for the whole page).
4. **Determinism**: the engine is byte-reproducible for the same input +
   config + depth map. Your model must be deterministic for the same
   input (quantized tflite models are; enable fixed thread counts).
5. **panelAware interplay**: with `panelAware: true` the estimator runs
   per panel on the panel's crop — models see cropped panels, which
   usually improves per-subject depth quality.

## Debugging with exportLayers

Export the resulting layer stack as PNG textures + metadata to inspect
what your depth map produced:

```dart
final pipeline = MotionPipeline(config, depthEstimator: myEstimator);
final export = await pipeline.exportLayersFile(input, outDir);
// outDir/<stem>_<contentHash8>_<configHash8>_layers/
//   layer_00.png … layer_NN.png   (working resolution, rank order)
//   index.json                    (kind: layers, sizes, per-layer clip)
```

`index.json` records each layer's `rank` and — with `panelAware: true` —
its panel `clip` rect, which the shader companion package uses to
constrain per-panel drawing on the GPU.
