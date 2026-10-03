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
- 32 composable effects + 42 built-in presets
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

## ⚠️ Capability boundary

- This library outputs **pre-rendered animation assets** (GIF / APNG / frame
  sequences). It is **not** a real-time interactive rendering engine — even
  the interactive parallax path (V1) is a pre-rendered frame set sampled at
  discrete phases, played back frame-by-frame by the companion widgets.
- `realtime/index.html` at the repo root is a **reference implementation of
  page-turn gestures** (Canvas 2D demo) only — it is not produced by, or
  consumed through, this engine.
- A real-time GPU path exists as a **separate shader companion package**,
  [`comic_motion_shaders`](../comic_motion_shaders) — MVP renders
  parallax / breathing / lightSweep / vignette in real time over the
  `exportLayers` texture set via a single uber-shader. Particle-class
  effects remain on the roadmap; see [doc/roadmap.md](doc/roadmap.md).

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

### Concurrency: one render at a time on mobile

A single pipeline peaks at 300–600 MB of memory (see the performance
reference). Two concurrent pipelines add up directly and will OOM on mobile
devices. Keep mobile apps to **one render task at a time** — queue work
instead of stacking it. The opt-in `MotionPipelineGuard` is a process-wide
semaphore for exactly that (the library never enforces it on its own):

```dart
await MotionPipelineGuard.run(() =>
    MotionPipeline(config).processFile(input, outDir)); // queues when busy
```

`run` releases its slot when the body throws — including a
`MotionCancelledException` from a cancelled render. Desktop batch jobs may
raise `maxConcurrent` deliberately.

### One-stop render parameters & effect selection

Every CLI-tunable render parameter is a first-class
[EffectConfig] constructor parameter — no need to touch nested objects:

```dart
final config = EffectConfig(
  fps: 12, durationSec: 2.5, maxDimension: 800,   // timing / resolution
  layerCount: 3, seed: 42, outputFormat: OutputFormat.gif,
  dither: true, qualityTier: RenderTier.standard, // → quality.dither / quality.tier
  amplitude: 0.02, directionDeg: 45,              // → parallax.amplitude / directionDeg
  effects: [EffectKind.rain],
).withoutEffect(EffectKind.fog).withEffect(EffectKind.snow); // immutable chaining
```

- The convenience parameters (`dither` / `qualityTier` / `amplitude` /
  `directionDeg`) are nullable and map onto the existing nested fields —
  **byte-identical serialization and configHash** versus constructing the
  nested objects directly (equivalence-matrix tested). The default path's
  fingerprint is unchanged.
- Effect selection (`withEffect` / `withoutEffect` / `withEffects` /
  `clearEffects`) always returns a **new instance**; the original config is
  never mutated. Clearing everything yields static frames.
- Parameter catalog for auto-generated settings panels:
  `kRenderParamSpecs` (name / type / min / max / default / semantics, plus
  which ranges are fail-fast) and `kEffectNames` — no hardcoded ranges in
  the app.
- Persistence recommendation: store `config.toJsonString()` and restore
  with `EffectConfig.fromJson` — the hash round-trips, so it doubles as a
  cache key.

### Webtoon strip mode

Long webtoon strips (e.g. 800 × 10000+) get destroyed by `maxDimension`
downscaling, exceed the edge limit outright, and parallax-like effects
misalign across panels. `processStrip` slices the source by a viewport
ratio (default 9:16, optional overlap) and renders each slice through the
standard pipeline independently:

```dart
final strip = await processStrip(
  inputPath, outDir,
  config: EffectConfig(
      fps: 12, durationSec: 2, maxDimension: 800,
      effects: [EffectKind.rain, EffectKind.vignette]),
  viewportWidth: 9, viewportHeight: 16,
  overlapPx: 0, // crop semantics: adjacent slices share exactly N rows, no blending
);
for (final s in strip.slices) {
  print(s.slice.yStart);      // source-row window
  print(s.result.outputGif);  // `<stem>_slice<NNN>_<contentHash8>_<configHash8>/anim.gif`
}
```

- Per-slice `<stem>_slice<NNN>_<contentHash8>_<configHash8>` directories with
  independent configHash + per-slice content fingerprint + params.json —
  deterministic, naturally cache-friendly.
- `kStripSafeEffects` lists the overlay-class effects that are safe across
  slice boundaries; anything else (parallax/breathing/slowPush/mangaShake…)
  is allowed but flagged experimental in `strip.warnings` (each slice
  estimates depth independently, so such motion can misalign at cuts).
- The whole-chapter pixel budget (40M px default) is enforced before
  slicing; oversized chapters raise `E_TOO_LARGE` with a strip-mode hint.
  Huge chapters: pass a larger `maxPixels` — per-slice working rasters stay
  small regardless of chapter height.

### Platform support matrix

| Platform | Status | Notes |
|---|---|---|
| Android / iOS | ✅ primary target | Pure Dart + isolates, no native plugins, no UI |
| Windows / macOS / Linux desktop | ✅ | Same code path as CLI/server |
| Web | 🚫 not supported | Core modules (`image_io` / `pipeline` / `worker_pool`) depend on `dart:io`, and `Isolate.spawn` is unavailable on Flutter Web. A port would mean web decode APIs and web workers — the long-term path, not a commitment |

### Output naming & content fingerprint

Product directories are named `<stem>_<contentHash8>_<configHash8>`
(`<stem>_slice<NNN>_<contentHash8>_<configHash8>` in strip mode). The two
hashes are orthogonal dimensions:

- `configHash8` — first 8 characters of the parameter fingerprint string.
  Same config ⇒ same value; for configs whose FNV-1a value has its top bit
  set this segment carries a leading `-` (the `configHash` string is a
  signed-int hex rendering — stable and carried verbatim).
- `contentHash8` — first 8 hex of the FNV-1a 64 fingerprint over the **input
  bytes** (`processImage` fingerprints the passed RGBA raster instead, since
  no file bytes exist there). Content fingerprints never enter
  `EffectConfig` serialization or configHash.

The content hash exists so that a re-downloaded or overwritten file with the
same name lands in a **new** directory — embedder cache logic of the form
"directory exists → skip rendering" can no longer serve a stale picture.
Note this is a **breaking change to the naming contract** (pre-1.3.1 caches
used `<stem>_<configHash8>`): old product directories are not recognized by
the new layout and must be cleaned up app-side (one-off `delete` of the cache
root is safe — it only ever contained engine products).

### Cache management

The naming contract above is the library's own — so the library ships the
cleanup tool (`MotionCacheManager`, `cache_manager.dart`):

```dart
final cache = MotionCacheManager(cacheRootDir);

for (final e in cache.listEntries()) {
  print('${e.stem} slice=${e.sliceIndex} ${e.byteSize}B ${e.modifiedAt}');
}
print(cache.totalSize());

// LRU purge: drop entries older than 30 days, then keep the newest 200
// within a 512 MB budget. Any combination of the three limits is valid.
final report = cache.purgeLRU(
    olderThan: const Duration(days: 30),
    maxEntries: 200,
    maxBytes: 512 << 20);
print(report); // purged entries + freed bytes

cache.purgePrefix('chapter_0042'); // one work: slices included
cache.purgeAll();
```

`purge*` methods only ever delete directories that **fully match the
library's naming contract**; unrecognized files and directories (the app's
own) are skipped untouched. Webtoon chapters render dozens of slice GIFs per
chapter — budget a periodic `purgeLRU` in long-running apps.

### Still frames & first-frame covers

Apps routinely need a poster frame before (or instead of) the animation.
Two ways, both at single-frame cost:

```dart
final config = EffectConfig(fps: 12, durationSec: 2.5, maxDimension: 800);

// 1) Standalone still: render time t once (default 0), PNG bytes out.
//    Skips GIF encoding and the palette probes entirely.
final png = await MotionPipeline(config, cancelToken: token, timeout: limit)
    .renderStillFrame(input: bytes); // bytes in
final png2 =
    await MotionPipeline(config).renderStillFrameFile(path); // path in
// GIF frame i corresponds to t = i / fps; t = 0 is the first frame.

// 2) Piggyback on a full render: attach the first frame for free — it is
//    the palette-probe frame the pipeline renders anyway.
final result = await MotionPipeline(config)
    .processFile(input, outDir, includeFirstFrame: true);
final cover = result.firstFramePng; // null when not requested
```

`renderStillFrame` shares the decode → downscale → split path with the full
pipeline, so a t=0 still is the same rendered frame as the GIF's first frame
(the GIF copy is palette-quantized). It honours `cancelToken` / `timeout`
(checked at entry and before render); `parallel` / `memoryBudgetMb` do not
apply — there is no worker pool. `includeFirstFrame` works on `processFile` /
`processBytes` / `processImage` and the background entries; the returned
bytes equal `frames/frame_0000.png` on disk.

### Frame-stream callbacks (progressive preview)

`MotionPipeline.onFrame` delivers every rendered frame as PNG bytes while
the pipeline runs — build a progressive preview, a thumbnail strip, or
stream frames elsewhere without touching the GIF:

```dart
final result = await MotionPipeline(config, parallel: 2, onFrame: (index, png) {
  // ordered by frame index, exactly one call per frame (probe frames
  // included); PNG bytes identical to frames/frame_NNNN.png on disk
  previewWidget.update(index, png);
}).processFile(input, outDir);
```

Where the callback runs: **on the isolate executing the pipeline** — the
calling isolate for the sync entries (the emit point is a synchronous
section, so heavy work inside the callback slows the render), and — for the
background entries (`processFileInBackground` / `processBytesInBackground`)
— the user callback is bridged over a `SendPort` and executes on the
calling isolate, same as `onProgress`. PNG encoding + cross-isolate
transfer happen only when `onFrame` is set (zero cost otherwise). The
callback coexists with `onProgress` and stops after cancel/timeout, like
every other checkpoint.

### GIF frame diffing (opt-in, mobile size)

The default `encoding.diffMode: none` encodes every frame full-canvas and is
part of the byte-reproduction contract. Webtoon chapters are the biggest
storage/traffic pain point, so `diffMode: rect` re-encodes each frame as
only the changed rectangle against the previous frame — the first frame
stays full-canvas, frames declare *do-not-dispose* so standard decoders
composite correctly, and a fully static tick becomes a 1×1 placeholder
frame that keeps the timing. Diffing happens on quantized palette indices;
dither/sierra error diffusion is per-frame independent, so determinism is
preserved:

```dart
final config = EffectConfig(
  fps: 12, durationSec: 2, maxDimension: 800,
  effects: [EffectKind.rain, EffectKind.vignette],
  encoding: EncodingParams(diffMode: 'rect'),
);
```

Strip mode routes every slice through the standard pipeline, so slices
benefit automatically. Expect roughly 2–5× smaller GIFs for webtoon-style
content (measure with your own material); the decoded result is
pixel-identical to `none` — locked by tests using a spec-compliant
compositor.

### Panel-aware layering (on by default since v1.4, W5)

Heuristic depth across panel borders is the main quality culprit for
multi-panel comic pages: panels slide against each other and content
bleeds across gutters. `panelAware` detects panel bands first
(horizontal white-gutter scan; sensitivity: near-white row ≥ 90% pixels
at luminance ≥ 245, gutter ≥ 0.5% page height, panel ≥ 6% page height,
fewer than 2 panels falls back to whole-page layering), then estimates
depth and splits layers **per panel**. Layers carry their panel bounds
(`LayerImage.clip`) and the compositor clips drawing to the panel —
cross-panel bleed is eliminated, and per-panel parallax amplitude is
normalized by in-panel depth rank so all panels move consistently. The
anti-phase step between adjacent depths keys on that same depth rank
(not on the flat layer index), so equal-depth layers in different panels
swing the same way.

```dart
final config = EffectConfig(
  fps: 24, durationSec: 2, maxDimension: 1080,
  effects: [EffectKind.parallax],
  panelAware: true, // default since v1.4; omitted from JSON when default
);
```

Passing `panelAware: false` is the rollback; it is the only case that
writes the key. Single-panel / no-gutter images fall back to whole-page
layering byte-identical to `panelAware: false`. Orthogonal with strip mode (each
slice runs the standard pipeline, panel detection applies within the
slice). Nested vertical sub-panels are future work.

### High-fps APNG (opt-in, 60 fps)

`outputFormat: apng` supports two extra encoding knobs (see
[doc/high-fps.md](doc/high-fps.md) for measured numbers and the full
recommendation matrix):

- `encoding.apngDelay: 'exact'` writes the fcTL delay as the precise
  fraction `1/fps` — required at 60 fps, where the default centisecond
  tier silently degrades to 20 ms (50 fps). Default output stays
  byte-identical to v1.3.
- `encoding.diffMode: 'rect'` on the APNG path diffs consecutive frames
  byte-exact in RGBA and encodes only the changed region (fcTL region
  frames, `dispose_op = NONE` compositing). Local-motion effects
  (lightSweep, impact accents) shrink 40–57% at 60 fps; full-frame motion
  (rain, snow, mangaShake) gains nothing — keep `none` there.

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
still reproduces deterministically. Without `memoryBudgetMb` the pixel path is
untouched and output stays byte-stable for the chosen tier (v1.4 narrowed the
`legacy` promise to the old *drawing algorithm* — see "Reproduction promise and
boundaries"; determinism itself is unchanged).

### GIF playback in Flutter (consumption guide)

The engine is UI-free: it hands over GIF files/bytes and stops there. How to
*play* them is the app's decision — this section is practical guidance for
embedders, not an API, and the library itself picks up no UI dependency.

**Player widget options** (all of them decode through the same `dart:ui`
codec — choose by control surface, not picture quality):

| Option | Good at | Watch out |
|---|---|---|
| Built-in `Image` (`Image.file` / `Image.memory` / `Image.network`) | Zero extra dependency; animated GIFs play and loop out of the box | No playback control — no pause/resume/seek; "pausing" means swapping the widget for a static frame |
| `extended_image` (third-party) | `GifImage` gives `autoPlay`, pause/resume, frame stepping | Extra dependency; same codec underneath, so decode memory is unchanged |
| `instantiateImageCodec` from `dart:ui` (DIY) | Frame timing and caching fully under your control | You own the decode loop, the frame cache and the dispose lifecycle |

**Decode memory.** A playing GIF keeps its decoder alive with at least one
decoded RGBA frame resident (`width × height × 4` bytes); every simultaneously
playing GIF adds another on top. Levers, by leverage:

- Save at render time: `frameCount = fps × durationSec` and `maxDimension`
  decide how big the product is — a 480p/12fps/2s GIF is far cheaper to
  display (and to store) than a 1280p/24fps/4s one.
- Decode at display size: pass `cacheWidth` / `cacheHeight` so a GIF shown in
  a 400-px card decodes at 400 px instead of its native size.
- Cap the number of playing GIFs per screen (1–3): per-frame decoding is
  recurring CPU, which on mobile is battery and thermals.

**List pages (feeds / chapter grids).** The engine's GIFs loop seamlessly
(first frame == last frame), which makes one frame a natural poster:

- Render with `outputFormat: OutputFormat.both` and use
  `result.frameDir/frame_0000.png` as the cover/placeholder until (or instead
  of) playback; in memory mode (`processBytes`) there is no frame PNG — decode
  the GIF's first frame client-side or keep disk mode for cover flows.
- Prewarm above-the-fold GIFs with `precacheImage` before the transition
  lands; keep list virtualization on so off-screen items dispose their
  decoders, or swap playing GIFs back to their cover frame when scrolled away
  (`extended_image` can pause instead).
- Respect the OS reduced-motion setting (`MediaQuery.disableAnimations`):
  show the cover frame; the engine's `reducedMotion` render option produces
  the matching single-frame product at render time.

### Running the engine from source (repo developers)

```bash
git clone https://github.com/nexhub-app/comic-motion-effects.git
cd comic-motion-effects/comic_motion
dart pub get
dart run tool/generate_samples.dart     # generate 10 placeholder samples
dart run tool/smoke_test.dart           # one image → GIF + frames (~2-4 s)
```

Output lands in `build/smoke/01_portrait_<contentHash8>_<configHash8>/`:

```
anim.gif                    # the animation
frames/frame_0000.png ...   # per-frame PNGs
params.json                 # full parameter replay file
```

## Input format matrix

Decoding is delegated to the pure-Dart `image` package (behavior pinned by
tests; the animated-WebP contract below is locked by a test so a dependency
upgrade cannot silently drift):

| Format | Status | Behavior |
|---|---|---|
| JPEG | ✅ supported | Baseline decoder, full decode path |
| PNG | ✅ supported | Baseline decoder, full decode path |
| WebP (static, VP8 lossy) | ✅ supported | Full decode path |
| WebP (static, VP8L lossless) | ✅ supported | Full decode path |
| WebP (extended header, VP8X) | ✅ supported | Canvas-size aware |
| **WebP (animated)** | ⚠️ **first frame only** | Decodes successfully; the engine renders from frame 0 and discards the remaining animation frames (measured on `image` 4.10.1 — the animation itself is never animated) |
| **GIF (incl. animated)** | ⚠️ **first frame only** | Also decodes successfully (`image` ships a GIF decoder); the engine renders from the decoded first frame, animation frames discarded |
| AVIF / HEIF | 🚫 not supported | Rejected as `E_DECODE_CORRUPT`; transcode to PNG/JPEG/WebP first |

Corrupted / disguised files take these error paths:

| Input | Code |
|---|---|
| 0-byte file / empty bytes | `E_DECODE_EMPTY` |
| File not found (path input) | `E_DECODE_NOT_FOUND` |
| Text file disguised as an image | `E_DECODE_CORRUPT` |
| Corrupt or truncated bitstream | `E_DECODE_CORRUPT` |
| Header-declared dimensions exceed the pixel budget | `E_TOO_LARGE` (rejected **before** raster allocation — pixel bombs never allocate) |
| Long-strip-shaped rejection (height > 2 × width) | `E_TOO_LARGE` + message hinting at strip mode (`processStrip`) |

## Render tiers (quality)

| Tier | Contents | Purpose |
|---|---|---|
| `standard` (default since v1.4) | Anti-aliased raster primitives, box-average / Catmull-Rom resampling, screen light blending, smoothed depth upsample + feathered masks, layer edge stretch, GIF quantize LUT (error-diffusion kernel selectable, **off by default** since R38) | Everyday rendering |
| `legacy` | The **old pixel algorithm**: no AA, bilinear/nearest resampling, plain source-over ink, v1.2 draw path | Rollback carrier for the *look*, not a byte promise — see the reproduction promise below (H2) |
| `rich` | **Byte-identical to `standard` today** — the reserved `supersample` / `mipLevels` knobs have no consumer yet (known deviation) | Deprecated: pick `standard` instead; `"tier": "rich"` in JSON still resolves to this tier (deprecation ≠ removal) |

Tiers only change the pixel path, never the effect list. `legacy` (the old
pixel algorithm) and `presets/legacy_v1.0.json` (the v1.0.0 *numbers* with
`tier: legacy` pinned) are two independent rollback switches — and both are
behavior-level, since v1.4 narrowed what `legacy` freezes (H2 / R46b). The
`sierra` dither kernel requires `dither: true` + `quality.ditherMode: "sierra"`
+ a non-legacy tier, all three at once; since R38 the first of those is off by
default, so out of the box neither kernel runs and `ditherMode` is dormant.

## Reproduction promise and boundaries

Same seed + same parameters produce **byte-identical** output. What each tier
promises (v1.4, H2): within a release, any tier is byte-stable; `legacy`
reproduces the v1.2 *drawing algorithm* but is **no longer byte-identical with
v1.2 output**, because two loop-closure fixes rewrite the time base on *both*
arms — the period snap to an integer number of cycles (R18) and the integer
vertical cycle count (R19) — plus the anti-phase layer stepping (R16). The
rollback drill on `presets/classic.json` therefore reports 0/10 against the
2026-09-14 v1.2 baseline, and that is the sanctioned, documented state rather
than a regression. Boundaries:

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

### Preview assets (doc/previews/)

Every cataloged effect ships a first-frame `preview.png` + a low-spec looping
`preview.gif` (8 fps, 1.5 s, ≤360 px, each GIF under a 300 KB budget) under
`doc/previews/<demo>/`. `index.json` maps each demo to its category, asset
paths, actual render dimension and GIF size — generated by
`tool/generate_showcase.dart --previews-only` as the single source of truth.
Generation is deterministic (same seed → byte-identical output); previews that
exceed the budget automatically step down a fixed dimension ladder
(360→280→220→170→130), so do not hand-edit these files.
`kEffectPreviewRefs` in `lib/src/param_catalog.dart` cross-references each
effect to its preview path for programmatic access.

## Built-in presets (presets/)

42 ready-made parameter sets, loadable via `EffectConfig.fromJson` (or
`--config` on the CLI):

| Group | Count | Notes |
|---|---|---|
| `classic` | 1 | Core trio only. Carries **no `quality` segment**, so it follows the shipping default tier (standard since v1.4) and the v1.4 amplitudes — it is *not* the v1.2 byte rollback carrier any more |
| v1.1/v1.2-era single effects | 16 | rain / snow / fog / embers / lightning / fireflies / godRays / starlight / shimmer / heartbeat / impact_duel / sakura / speedlines / slowpush / vignette / toneshift |
| dither comparison | 1 | `dither_compare_forest` (the only `dither: true` preset) |
| v1.2-era combos | 5 | combo_campfire / full_action / rain_lanterns / sakura_light / storm_night |
| v1.3 single effects | 10 | focus_lines / screen_tone / manga_shake / impact_burst / brush_streak / flame / smoke / bubbles / leaves / meteors |
| v1.3 mood envelopes | 2 | `mood_tension_build`, `mood_burst_impact` |
| v1.3 combos (standard) | 3 | combo_manga_impact / night_battle / peaceful_evening |
| showcase bases | 3 | `classic_base` / `dust_motes` / `light_sweep_hall` — the single-source fixtures `tool/generate_showcase.dart` renders previews from; usable as configs too |
| v1.0.0 rollback anchor | 1 | `legacy_v1.0.json` — v1.0.0 *numbers* (amplitude 0.012 / breathing 0.006 / ambient 0.16, 12fps, 640px, 96 frames) with `tier: legacy` + `dither: false` + both placement gates off, all written explicitly. **Behavior-level** rollback, not byte-level (R40 / R46b): `durationSec` is 6.0 rather than v1.0.0's 3.0, because only 6.0 represents `parallax.periodSec 6.0` exactly under the integer-period rule. Its `configHash` is pinned by a dedicated test |

"v1.1/v1.2-era" / "v1.3" in the group names above date the **effect list**, not
the render tier. Only `legacy_v1.0.json` writes a `tier` at all — the other 41
write no tier and therefore render at the shipping default, which is `standard`
since v1.4 (H1); the one exception inside that group is
`dither_compare_forest.json`, which writes `"dither": true` and no tier. The
showcase presets were re-emitted by `tool/generate_showcase.dart` under the
"omit a key equal to its default" idiom, so their whole `quality` segment is now
elided (15 files lost 4 lines each; rendering semantics unchanged). Pin
`"tier": "legacy"` in the JSON (or load `legacy_v1.0.json`) to keep the old
algorithm; `contentAware` / `panelAware` are unpinned everywhere except
`legacy_v1.0.json`, so both placement gates are on out of the box (R30 / R39).

The 40 showcase presets are generated by `tool/generate_showcase.dart` as the
single source of truth — edit the generator, not the JSON (regeneration
would overwrite it). `classic.json` and the `legacy_v1.0.json` rollback anchor
are not part of that demo set.

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
    guard.dart             # opt-in concurrency semaphore (MotionPipelineGuard)
    param_catalog.dart     # program-readable render parameter catalog
    strip.dart             # webtoon strip mode (slicing + processStrip)
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
presets/                   # 42 built-in presets
sample_images/             # 10 placeholder samples
tool/                      # sample/smoke/showcase/bench/gif-check scripts
test/engine_test.dart      # engine + config tests
test/render_test.dart      # render + effect tests
doc/                       # effect catalog, WebP research
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

Measured by `tool/bench.dart` on `sample_images/01_portrait.png` (900×1300),
engine 1.4.0, parallel=8, **median of 3 runs** (2026-10-03; the last run's
detail is in `build/bench/bench_report.json`). Peak RSS is the process
high-water mark, so the later rows of a run share one value rather than being
independent measurements.

| Scenario | Effects | Tier | Time | Peak RSS | Red line |
|---|---|---|---|---|---|
| 480p / 12fps / 2s (draft) | 3 | legacy | 301 ms | 389 MB | ≤450 ms ✅ |
| 1080p / 24fps / 4s (typical) | 3 | legacy | 2.61 s | 554 MB | ≤5 s ✅ |
| 1600 / 24fps / 4s (preview cap) | 3 | legacy | 3.73 s | 643 MB | ≤7 s ✅ |
| 1600 / 24fps / 4s — **shipping default tier** | 3 | standard (engine default) | 5.66 s | 647 MB | ≤7 s ✅ |
| 1080p / 24fps / 4s standard | 3 | standard | 3.95 s | 647 MB | — |
| 1080p / 24fps / 4s, 19 effects (v1.2 floor) | 19 | legacy | 3.05 s | 647 MB | — |
| 1080p / 24fps / 4s, 19 effects, rich | 19 | rich | 4.24 s | 647 MB | — |
| 1080p all effects (worst case) | 32 | standard | 5.14 s | 647 MB | ≤9 s ✅ |

Parallelism scan (standard tier, 1080p, 96 frames, core trio): `1 → 13.66 s`,
`2 → 8.95 s`, `4 → 5.62 s`, `8 → 4.02 s`; all four GIFs **byte-identical**
(FNV `-287a4af0a4b1fe73`); `parallel=1` peaks at 647 MB (red line 780 MB).
Reproducibility: the bench GIF digested to `1d8b6c35a0a57643` in all three
runs, and changing a parameter still changes the digest (sensitivity gate).
The legacy-tier rows are measured with `tier: legacy` pinned and are kept as
the historical floor — v1.4 ships standard, so read the standard rows for
out-of-box cost (the default-tier row is the one to plan against: **+52%**
over legacy at the 1600 cap). The v1.2 *byte* reproduction drill is no longer
green by design (see "Reproduction promise and boundaries": classic drill 0/10
since H2/R46b); `presets/legacy_v1.0.json` is the behavior-level rollback
anchor instead.

**Multi-panel input costs more than the corpus placeholder, and breaches two
red lines.** A real two-panel page (1800×2600, built by nearest-neighbour ×2
upscale of `sample_images/03_two_panel.png`, staged at
`build/bench/in_twopanel_1800x2600.png`) run through the same scenarios:

| Scenario | Effects | Tier | Time | Peak RSS | Red line |
|---|---|---|---|---|---|
| 1600 / 24fps / 4s — **shipping default tier** | 3 | standard (engine default) | 8.17 s | 1033 MB | ❌ >7 s (2 of 3 runs; 6.57 s passed once) |
| 1600 / 24fps / 4s, legacy | 3 | legacy | 5.40 s | 1023 MB | ≤7 s ✅ |
| `parallel=1` serial sweep | 3 | standard | 11.57 s | 1033 MB | ❌ >780 MB (all 3 runs) |
| 1080p all effects | 32 | standard | 4.47 s | 1033 MB | ≤9 s ✅ |

Per-panel layering (`panelAware`, on by default since R39) keeps a layer raster
per panel, so peak RSS grows with panel count rather than only with working
pixels — 1033 MB versus 647 MB on the single-page sample at the same
`maxDimension`. Thresholds were **not** moved to accommodate this. Practical
consequences: on comic strips / multi-panel pages at the 1600 cap, pass
`memoryBudgetMb` (the budget path degrades working resolution before OOM and
records a warning) or drop `maxDimension` to ≤1080; and treat `parallel=1` on
such a page as out of spec for the 780 MB serial line (use ≥2 workers, where
the 1150 MB line holds: `2 → 6.74 s`, `4 → 4.56 s`, `8 → 3.37 s`). Determinism
is unaffected on this input either: its bench GIF digested to `647695f0b0644120`
in all three runs and the whole parallel sweep produced one identical byte
stream (`-65ae766127adf731`), serial included. One further one-off breach on
that input: the draft row hit 531 ms > 450 ms in one of the three runs (373 ms
and 390 ms in the other two) — run-to-run jitter, and no threshold was moved
for it.

### Mobile reference ranges (rough)

The desktop numbers above **do not transfer to phones** (fewer big cores,
thermal throttling, different memory behavior). The ranges below are rough
estimates for guidance — derived from the desktop bench with mobile
parallelism and thermal assumptions folded in, **not yet calibrated on real
devices**; treat them as order-of-magnitude, and use `estimateCost(...)` +
the `warnings` degradations for the actual device:

| Scenario | Config | Typical wall time | Guidance |
|---|---|---|---|
| Draft (in-feed preview) | 480p, 12fps, 2s, core trio, parallel 2 | ~0.5–1.5 s | Mid-tier Snapdragon / Dimensity |
| Typical | 1080p, 24fps, 4s, core trio, parallel 2–4 | ~4–10 s | Render on demand, not while scrolling |
| Low-end device | 720p, 12fps, 2s, core trio, parallel 1–2 | ~1–3 s | Cap `maxDimension` ≤ 720, always pass `memoryBudgetMb` |

Rules of thumb on phones: keep `parallel` ≤ 4 (each worker copies the full
layer rasters); always pass `memoryBudgetMb` and surface its `warnings`;
prefer the draft config for scrolling previews and render the typical
config on demand; run one render at a time (see the concurrency section).

## Tests and benchmarks

```bash
dart test                      # automated tests
dart run tool/bench.dart       # perf + reproducibility + parallelism scan (exit 3 over red line)
dart run tool/gif_check.dart   # strict per-frame GIF decode verification
```

## Ecosystem

One-way dependency: the core stays pure Dart and knows nothing about its
companions.

| Package | Role |
|---|---|
| **comic_motion** (this package) | Pure-Dart rendering engine — depth layers, effects, encoding |
| [comic_motion_server](../comic_motion_server) | CLI (single/batch) + HTTP API service |
| [comic_motion_flutter](../comic_motion_flutter) | Flutter widgets: `MotionGifView` (placeholder crossfade, playback control, entrance frames), `ParallaxGyroView` (gyro/touch/injected-stream parallax), plus asset/disk frame-set loaders |

## Compatibility and deprecation policy

Breaking changes to the public API follow a `@Deprecated` cycle: the old
surface is annotated with migration notes and kept for at least one minor
release, then removed in the next major version. Structured exception codes
(`E_*`) are stable identifiers — new codes may appear, existing codes never
change meaning. v1.3.0 predates this policy (its breaking change of
`RgbaImage.data` without a deprecation cycle is the case that motivates it).

**v1.4.0 ships two deliberate breaking changes** (both approved as product
decisions, not API oversights — see `CHANGELOG.md`):

- **H1 — shipping defaults changed in place**, no new keys and no migration
  path: `quality.tier` `legacy → standard`, `contentAware` `false → true`,
  `panelAware` `false → true`, `parallax.amplitude` `0.012 → 0.030` (and the
  matching amplitude raises), while `dither` went back to `false`. Existing
  configs that *pin* a value are untouched — only unpinned configs move.
  Because the default config's serialized shape never changed (equal-to-default
  keys stay omitted), this moves no JSON schema; it moves the bytes each
  config renders to, hence the one-off `configHash` re-baseline in this release.
- **H2 — the meaning of `legacy` narrowed** from "byte-identical with v1.2" to
  "the v1.2 *pixel algorithm*". Seamless-loop fixes that rewrite the time base
  apply to both arms (integer period snap R18, integer vertical cycles R19) and
  the anti-phase layer stepping (R16) is a phase constant, not a pixel
  algorithm — so `legacy` output no longer replays the 2026-09-14 v1.2
  baseline (the drill reports 0/10 and that is the documented state).
  `presets/legacy_v1.0.json` is the rollback file to reach for: v1.0.0 numbers
  + `tier: legacy` + both placement gates off, behavior-level rather than
  byte-level (R46b).

## License

[Apache-2.0](LICENSE)
