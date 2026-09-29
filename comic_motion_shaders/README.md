# comic_motion_shaders

GPU realtime companion package (MVP): renders layered-texture motion with a
single uber-shader (uniform switches) — **parallax / breathing / lightSweep /
vignette**. The input is a layered texture set (RGBA PNG, far-to-near order)
exported by the core engine's `exportLayers` API in
[`comic_motion`](https://pub.dev/packages/comic_motion). GPU particle effects
are planned for a later release (see the core package's `doc/roadmap.md`).

This package is independent from the core engine and from
`comic_motion_flutter`; it is not part of their dependency graph.

## Realtime shader vs pre-rendered frame sets: how to choose

| Aspect | RealtimeMotionView (this package) | MotionGifView / ParallaxGyroView (flutter package) |
|---|---|---|
| Mechanism | FragmentShader samples layered textures every frame | Pre-rendered GIF frame sets / interaction frame sequences |
| Precision | Unlimited (uniforms vary continuously, no frame cap) | Bounded by pre-rendered fps and frame count |
| Power | GPU active every frame | Decode once, play back; low GPU load |
| Target devices | High-end phones / desktop / large screens | Low-end devices / list flows / batch cards |
| Determinism | Clock-driven, subtle variation per run (random phase start) | Byte-reproducible contract (same seed + config) |
| Interaction | Parallax uniform reacts instantly (touch/gyro) | Frame-sequence interpolation |

**Guidance**: use this package for hero images, page turns and
interaction-heavy main visuals; use frame sets for list thumbnails, many
cards on screen, and low-end fallback. Both consume the same `exportLayers`
output, so the look can be aligned.

## Determinism note

The core engine's byte-reproducibility contract (same seed + same config →
same output bytes) does **not** apply here: the realtime path is driven by
uniforms (clock/interaction), has no seed, and changes continuously over
time. The layered textures themselves are still exported deterministically.

## Uniform contract

`assets/shaders/comic_motion.frag` declares 19 float uniforms + 4 samplers;
`MotionUniforms.toFloats()` serializes them in the index order below (the
`kIndex*` constants mirror this table). Changing either side requires
updating the other and this table.

| Index | uniform | Meaning | Range (after clamping) |
|---|---|---|---|
| 0 | uParallaxOn | parallax switch | 0/1 |
| 1 | uParallaxX | max uv offset (fraction of canvas width) | [-1, 1] |
| 2 | uParallaxY | max uv offset (fraction of canvas height) | [-1, 1] |
| 3–6 | uDepth0..3 | per-layer depth factor (0 = base layer, no shift) | [0, 1], fixed length 4 |
| 7 | uBreathingOn | breathing switch | 0/1 |
| 8 | uZoom | breathing amplitude | [0, 0.5] |
| 9 | uPhase | breathing phase (host clock) | [0, 1] |
| 10 | uSweepOn | light sweep switch | 0/1 |
| 11 | uSweepPos | sweep center (can slide in/out) | [-0.5, 1.5] |
| 12 | uSweepWidth | sweep half bandwidth | [1e-4, 0.5] |
| 13 | uSweepIntensity | sweep intensity | [0, 1] |
| 14 | uVignetteOn | vignette switch | 0/1 |
| 15 | uVignetteStrength | vignette strength | [0, 1] |
| 16 | uVignetteSoftness | vignette softness | [0, 1] |
| 17–18 | uSize | canvas pixel size | > 0 |
| sampler 0–3 | uTex0..3 | layered textures (far-to-near, exportLayers order) | — |

When fewer than 4 layer textures are provided, empty slots are filled with
1x1 transparent placeholder textures; the layer cap is 4. panelAware layers
are "full-canvas transparent + in-panel content" PNGs, so alpha blending
never bleeds across panels; this shader does not consume clip metadata
(MVP simplification).

## Usage

```dart
import 'package:comic_motion_shaders/comic_motion_shaders.dart';

// 1. Get layered PNG bytes from exportLayers (in-memory result or layer_NN.png files)
final layers = await decodeLayerTextures(layerPngBytes); // far-to-near, ≤4 layers

// 2. Render in real time (parallax driven by touch/gyro; breathing/sweep by internal Ticker)
RealtimeMotionView(
  layers: layers,
  parallaxShift: Offset(dx, dy), // update via setState in gesture/sensor callbacks
  breathing: true,
  sweep: true,
  vignette: false,
);
```

You own the `layers` list; dispose it when done. A full demo (procedural
placeholder layers + live sliders) lives in `example/`:

```bash
cd example && flutter run
```

## Platform support matrix

`FragmentProgram.fromAsset` requires Flutter 3.7+ and SPIR-V support from
Impeller/Skia. The matrix below reflects desktop analysis only (not yet
verified on physical devices; defer to the official Flutter support matrix):

| Platform | Backend | Status |
|---|---|---|
| Android | Impeller | Expected to work, pending device verification |
| Android | Skia (older devices) | Expected to work, pending device verification |
| iOS | Impeller | Expected to work, pending device verification |
| Windows / macOS / Linux | Skia | Expected to work, pending device verification |
| Web | CanvasKit / SKSL | FragmentShader path limited, pending verification |

If a Flutter build disables fragment shaders on a given platform, the view
degrades safely to `SizedBox.shrink()` when `FragmentProgram.fromAsset`
fails — no crash.

## Testing

```bash
flutter test # uniform mapping unit tests (layout contract / clamping / clock mapping)
```

## Documentation

Chinese documentation: [README_zh-CN.md](README_zh-CN.md).
