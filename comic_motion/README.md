# comic_motion

[![CI](https://github.com/nexhub-app/comic-motion-effects/actions/workflows/ci.yml/badge.svg)](https://github.com/nexhub-app/comic-motion-effects/actions/workflows/ci.yml)

[English](README.md) | [简体中文](README_zh-CN.md)

A pure-Dart comic image motion engine. It splits a static comic page into
**depth layers** and renders HarmonyOS-reader-style **2.5D parallax +
breathing + ambient particles** motion, exporting animated GIF and PNG frame
sequences.

- Pure Dart, no native code, UI-free — embeds into any Dart/Flutter app.
  Only runtime dependency: the `image` package.
- Byte-for-byte reproducible output for the same seed + parameters
  (deterministic random seed + configHash)
- 32 composable effects + 38 built-in presets
- Multi-isolate parallel frame rendering: affects wall time only, never the
  output bytes

The CLI (single image / batch) and the HTTP API service live in the sibling
package **[comic_motion_server](../comic_motion_server)**; the two are
decoupled — embedding the engine pulls in no HTTP stack at all.

## Requirements

| Item | Requirement |
|---|---|
| Dart SDK | ≥ 3.4.0 |
| OS | Windows / Linux / macOS (pure Dart) |
| Network | Only for `dart pub get` |

## Embedding into a Flutter app

### Installation

pub.dev (recommended):

```yaml
dependencies:
  comic_motion: ^1.3.0
```

git directly:

```yaml
dependencies:
  comic_motion:
    git:
      url: https://github.com/nexhub-app/comic-motion-effects.git
      path: comic_motion
```

```dart
import 'package:comic_motion/comic_motion.dart';

final result = await MotionPipeline(EffectConfig(fps: 12), parallel: 4)
    .processFile(input, outDir);
```

`processFile` is async (it crosses isolates when parallelism > 1) — always
`await` it. The pipeline argument `parallel` is an execution-time parameter:
it never enters `EffectConfig`, so it cannot affect configHash or output
bytes.

### ⚠️ Threading model: don't render on the UI isolate

`processFile` / `processBytes` are `async`, but the **decode → downscale →
depth-estimation → layer-splitting → palette-probe** stages run
synchronously on the calling isolate (only later frame rendering is
dispatched to the worker pool). Calling them directly on the UI isolate
freezes the UI for hundreds of milliseconds to seconds. Two fixes:

1. **Use the background entry points** (recommended) — the whole pipeline,
   including decode, runs on a background isolate; progress and cancellation
   are bridged back to the caller:

   ```dart
   final token = MotionCancelToken();
   final result = await processFileInBackground(
     inputPath, outDir,
     config: EffectConfig(fps: 12, durationSec: 2.5, maxDimension: 800),
     parallel: 4,
     memoryBudgetMb: 256,
     cancelToken: token,
     onProgress: (done, total) => debugPrint('$done/$total'),
     timeout: const Duration(seconds: 30),
   );
   // user navigated away mid-render:
   token.cancel(); // stops dispatch at the next frame boundary, throws E_CANCELLED
   ```

   `processBytesInBackground({required Uint8List input, ...})` is the
   in-memory twin: bytes in, bytes out, no temporary files; the returned GIF
   bytes are byte-identical to the on-disk product.

2. **Wrap it yourself**: `Isolate.run(() => MotionPipeline(cfg)
   .processFile(in, out))` — fine for fire-and-forget calls, but progress
   and cancel cannot cross that isolate boundary.

Cancellation/timeout semantics (both sync and background entries): the
checkpoints live on the frame-scheduling layer (before dispatch / per
received frame / before each probe render) — an in-flight single-frame
render is never interrupted (frames are pure functions; the result is
discarded), so the granularity is one frame boundary. Cancelled runs delete
their partial output by default (`keepPartial: true` keeps it) and throw
`MotionCancelledException`; code `E_CANCELLED` for caller cancel, code
`E_TIMEOUT` when the `timeout` deadline passes (checked at the same
checkpoints). Progress counts probe frames and stops after cancel/timeout.

### Platform support matrix

| Platform | Status | Notes |
|---|---|---|
| Android / iOS | ✅ primary target | Pure Dart + isolates, no native plugins, no UI |
| Windows / macOS / Linux desktop | ✅ | Same code path as CLI/server |
| Web | 🚫 not yet | `dart:io` / isolate boundaries not yet converged (roadmap) |

### Recommended mobile parameters

| Parameter | Recommendation | Why |
|---|---|---|
| `maxDimension` | ≤ 1280 | Peak memory scales linearly with working pixels |
| `fps` / `durationSec` | 12 / 2-3 s | frameCount = fps × duration drives encode time and resident memory |
| `parallel` | 2-4 | Each worker holds a full copy of the layer rasters |
| `memoryBudgetMb` | Per device tier (e.g. 256 / 512) | Auto-degrades parallelism, then working resolution; degradations land in `warnings` |

### Memory budget API

```dart
final result = await MotionPipeline(
  EffectConfig(fps: 12, durationSec: 2.5, maxDimension: 1280),
  parallel: 4,
  memoryBudgetMb: 256, // execution-time only: not in EffectConfig, not in configHash
).processFile(input, outDir);
for (final w in result.warnings) {
  debugPrint(w); // budget-driven degradations (parallelism / resolution) are logged here
}
```

The budget model is a deliberately conservative heuristic (working pixels ×
layer count + safety factor): degrade early rather than OOM. When the budget
shrinks the working resolution the output pixels change with it — the result
is not byte-identical to an unbudgeted run, but the same budget + same input
still reproduces deterministically. Without `memoryBudgetMb` the pixel path
is untouched and the legacy byte-identity contract holds.

### Running the engine from source (repo developers)

```bash
git clone https://github.com/nexhub-app/comic-motion-effects.git
cd comic-motion-effects/comic_motion
dart pub get
dart run tool/generate_samples.dart     # generate 10 placeholder samples
dart run tool/smoke_test.dart           # one image → GIF + frames (~2-4 s)
```

Output lands in `build/smoke/01_portrait_<hash8>/`:

```
anim.gif                    # the animation
frames/frame_0000.png ...   # per-frame PNGs
params.json                 # full parameter replay file
```

## Render tiers (quality)

| Tier | Contents | Purpose |
|---|---|---|
| `legacy` (default) | v1.2 draw + encode paths | **Byte-identical** with historical output; the rollback carrier |
| `standard` | Anti-aliased raster primitives, box-average / Catmull-Rom resampling, screen light blending, smoothed depth upsample + feathered masks, layer edge stretch, GIF quantize LUT (optional sierra dither kernel) | Everyday rendering |
| `rich` | Same pipeline as `standard`; the reserved `supersample` and `mipLevels` knobs have no consumer yet (known deviation) | Comparison against standard |

Tiers only change the pixel path, never the effect list; `legacy` and
`presets/classic.json` are two independent rollback switches. The `sierra`
dither kernel requires `dither: true` + `quality.ditherMode: "sierra"` + a
non-legacy tier, all three at once.

## Reproduction promise and boundaries

Same seed + same parameters produce **byte-identical** output; the `legacy`
tier is byte-identical with v1.2 (rollback promise). Boundaries:

- **Dependency versions**: GIF/PNG encoding is delegated to the `image`
  package; byte-level reproducibility holds for the `image` range pinned in
  `pubspec.lock`. A downstream `pub upgrade` that crosses encoder
  implementations (palette/compression changes) may shift output bytes —
  reproduction-sensitive apps should keep `pubspec.lock` under version
  control.
- **configHash versioning**: configHash is a parameter fingerprint (currently
  the v1 algorithm), stored alongside a `version` field in `params.json`. If
  the hash algorithm or field serialization ever changes, it migrates behind
  a version prefix — old replay files are handled by their declared version,
  never silently invalidated.
- **Execution-time parameters are out of scope**: `parallel` and
  `memoryBudgetMb` are not part of configHash. `parallel` never affects
  pixels; `memoryBudgetMb` changes output pixels only when it shrinks the
  working resolution (see the memory budget API) — "same parameters" then
  means the actually effective working resolution.

## Effect catalog (32)

Effects compose freely via `EffectConfig.effects`; all loops are seamless
(first frame == last frame):

| Category | Effects |
|---|---|
| Core trio (on by default) | `parallax` 2.5D depth · `breathing` breathing zoom · `ambient` rising ambient particles |
| Weather | `rain` · `snow` · `fog` · `sakura` petals · `embers` sparks |
| Light | `fireflies` · `godRays` Tyndall beams · `starlight` · `lightning` · `shimmer` glints |
| Dynamics | `speedLines` · `impactFlash` · `slowPush` |
| Rhythm & tone | `heartbeat` pulse · `toneShift` · `vignette` |
| Accents | `lightSweep` · `dust` |
| Manga dynamics (v1.3) | `focusLines` concentration lines · `screenTone` halftone · `mangaShake` screen shake · `impactRings` shock rings · `brushStreak` brush streaks |
| Nature (v1.3) | `flame` · `smoke` · `bubbles` · `leaves` · `meteors` |
| Mood orchestration (v1.3) | `moodScript` envelope (draws nothing; re-weights amplitudes of the other effects by `tension`/`calm`/`burst`/`eerie`) |

## Built-in presets (presets/)

38 ready-made parameter sets, loadable via `EffectConfig.fromJson` (or
`--config` on the CLI):

| Group | Count | Notes |
|---|---|---|
| `classic` | 1 | Core trio + legacy tier + no dither; byte-reproduces v1.2 |
| v1.1/v1.2 single effects (legacy) | 16 | rain / snow / fog / embers / lightning / fireflies / godRays / starlight / shimmer / heartbeat / impact_duel / sakura / speedlines / slowpush / vignette / toneshift |
| dither comparison | 1 | `dither_compare_forest` (the only `dither: true` preset) |
| v1.2 combos (legacy) | 5 | combo_campfire / full_action / rain_lanterns / sakura_light / storm_night |
| v1.3 single effects (standard) | 10 | focus_lines / screen_tone / manga_shake / impact_burst / brush_streak / flame / smoke / bubbles / leaves / meteors |
| v1.3 mood envelopes | 2 | `mood_tension_build`, `mood_burst_impact` |
| v1.3 combos (standard) | 3 | combo_manga_impact / night_battle / peaceful_evening |

The 37 showcase presets are generated by `tool/generate_showcase.dart` as the
single source of truth — edit the generator, not the JSON (regeneration
would overwrite it).

## Project layout

```
lib/
  comic_motion.dart        # public exports
  src/
    version.dart           # single source of version truth (synced with pubspec)
    image_model.dart       # RGBA pixel model (flat Uint8List, zero-copy)
    image_io.dart          # decode/encode facade over the image package
    config_io.dart         # config file loading (IO edge; effect_config stays pure)
    depth_splitter.dart    # depth estimation + layer splitting (feathered edges)
    motion_math.dart       # effect math (parallax/breathing/particle trajectories)
    frame_compositor.dart  # frame compositor
    gif_writer.dart        # GIF encoding (quantize LUT + error-diffusion dither)
    effect_config.dart     # parameter system (JSON + configHash), pure Dart
    json_compat.dart       # compatibility JSON helpers
    pipeline.dart          # single-image pipeline
    worker_pool.dart       # parallel frame-render isolate pool
    background.dart        # background-isolate entry points (progress/cancel bridge)
    cancellation.dart      # MotionCancelToken + MotionCancelledException
    batch_runner.dart      # batch processing
    ledger.dart            # JSONL processing ledger (optional, size-rotating)
    render/
      quality.dart         # RenderTier definitions
      raster.dart          # anti-aliased raster primitives
      resampler.dart       # box-average + separable Catmull-Rom
      envelope.dart        # moodScript envelope curves
    effects/
      comic_pass.dart      # draw path for manga-dynamics effects
      particle_raster_pass.dart  # unified raster path for particle effects
presets/                   # 38 built-in presets
sample_images/             # 10 placeholder samples
tool/                      # sample/smoke/showcase/bench/gif-check scripts
test/engine_test.dart      # engine + config tests
test/render_test.dart      # render + effect tests
docs/                      # effect catalog, WebP research
example/                   # three runnable embedding examples
```

## Error handling

| Scenario | Behavior |
|---|---|
| Empty / corrupted / non-image file | `ImageDecodeException` (codes `E_DECODE_EMPTY`, `E_DECODE_CORRUPT`, `E_DECODE_NOT_FOUND`) |
| Oversized image (>64MB file, >12000px edge, or >40M pixels) | `ImageTooLargeException` (code `E_TOO_LARGE`; pixel budget configurable per device) |
| Bad JSON / wrong field type / unknown effect | `ConfigException` (codes `E_BAD_CONFIG`, `E_UNKNOWN_EFFECT`) |
| Parallel worker failed to start | Automatic serial fallback with `parallelFallback: true` |
| Worker crashed mid-render | `EngineWorkerException` (code `E_WORKER_CRASH`) — task fails, never silently degrades |
| Unknown `moodScript.mood` | Falls back to `calm` and records a `warnings` entry |

Failures never crash the caller and never abort a batch; everything is
recorded (ledger is optional for embedders and size-rotating).

## Performance reference

Measured by `tool/bench.dart` on a 1080p sample (`build/bench/bench_report.json`,
parallel=8):

| Scenario | Effects | Tier | Time | Peak RSS | Red line |
|---|---|---|---|---|---|
| 480p / 12fps / 2s (draft) | 3 | legacy | 233 ms | 377 MB | ≤450 ms ✅ |
| 1080p / 24fps / 4s (typical) | 3 | legacy | 2.25 s | 534 MB | ≤5 s ✅ |
| 1600 / 24fps / 4s (preview cap) | 3 | legacy | 3.49 s | 607 MB | ≤7 s ✅ |
| 1080p standard tier | 3 | standard | 4.26 s | 607 MB | — |
| 1080p all effects (worst case) | 32 | standard | 5.20 s | 628 MB | ≤9 s ✅ |

Parallelism scan (standard tier, 1080p, 96 frames, core trio): `1 → 16.67 s`,
`2 → 9.45 s`, `4 → 6.08 s`, `8 → 4.77 s`; all four GIFs **byte-identical**;
`parallel=1` peaks at 628 MB (red line 780 MB). Reproducibility: identical
SHA256/FNV-1a across runs; legacy tier byte-identical with v1.2
(`presets/classic.json` drill passed).

## Tests and benchmarks

```bash
dart test                      # automated tests
dart run tool/bench.dart       # perf + reproducibility + parallelism scan (exit 3 over red line)
dart run tool/gif_check.dart   # strict per-frame GIF decode verification
```

## Compatibility and deprecation policy

Breaking changes to the public API follow a `@Deprecated` cycle: the old
surface is annotated with migration notes and kept for at least one minor
release, then removed in the next major version. Structured exception codes
(`E_*`) are stable identifiers — new codes may appear, existing codes never
change meaning. v1.3.0 predates this policy (its breaking change of
`RgbaImage.data` without a deprecation cycle is the case that motivates it).

## License

[Apache-2.0](LICENSE)
