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

## Background-isolate entry points

The `processFileInBackground` / `processBytesInBackground` helpers take an
optional **estimator factory** instead of an estimator instance — the model
and any native runtime must be created *inside* the background isolate:

```dart
final result = await processBytesInBackground(
  input: pageBytes,
  config: config,
  depthEstimatorFactory: () => RegionCoherentDepthEstimator(
    inner: OnnxDepthEstimator.load(modelPath), // your model, loaded here
    detailMinArea: 64,
  ),
);
```

The factory is called once per background run; its closure must be sendable
(top-level/static functions, or closures capturing only sendable values —
a `String` model path is fine, an open native handle is not). If the factory
throws, the error propagates to the caller like any pipeline error.

## Region-coherent post-process (recommended wrapper)

Smooth ML depth fields get cut by the engine's 3-layer quantization: flat
colour regions (speech bubbles, banners) and line art fragment across
layers, so text ghosts during parallax. `RegionCoherentDepthEstimator` is a
pure-Dart wrapper that makes depth **piecewise constant per connected
same-colour region** and per ink component, which removes that tearing
while keeping subject/background separation:

```dart
final estimator = RegionCoherentDepthEstimator(
  inner: myModelEstimator, // any DepthEstimator
  colorBits: 5,            // colour quantization (5 => 32768 buckets)
  inkThreshold: 100,       // BT.601 luminance below this = ink
  detailMinArea: 64,       // small regions inherit the nearest large region
);
```

- Values keep the inner estimator's scale (region means are affine-invariant);
  normalize your model output to [0,1] before wrapping.
- `detailMinArea > 0` snaps small regions (light lettering, screen-tone
  details) onto the surrounding large region so they move with it; `0`
  reproduces the raw region-mean behaviour.
- Cost is one extra pure-Dart pass per page (tens of ms at 720 px working
  resolution, measured on desktop).

### The `constantValued` flag (layer-split contract)

The wrapper sets `DepthMap.constantValued = true` on its output. The layer
splitter reads this flag to pick threshold semantics suited to
**piecewise-constant** depth fields: thresholds fall on the midpoint
between neighbouring distinct values, and layer membership is hard 0/1
instead of the ±0.03 soft ramp. Without it, a constant-valued region whose
mean sits near a threshold lands *entirely* on the ramp — the whole region
goes translucent, the base image bleeds through, and text doubles during
parallax (each layer applies its own offset).

If your estimator also produces piecewise-constant maps (region means,
segmentation-style quantization), set the flag on the returned `DepthMap`
the same way. Smooth continuous depth fields must leave it `false` — the
default keeps the soft-ramp behaviour and stays byte-identical to the
pre-flag engine.

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
5. **panelAware interplay**: since v1.4 this is the default, and the
   estimator runs per panel on the panel's crop — models see cropped
   panels, which usually improves per-subject depth quality. Pass
   `panelAware: false` (or feed a single-panel page) to get one whole-page
   call instead.

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
