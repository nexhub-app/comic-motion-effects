# Changelog

All notable changes to this project are documented in this file. Versioning
follows [SemVer](https://semver.org/). `pubspec.yaml`, `lib/src/version.dart`
and `dart run bin/comic_motion.dart --version` share one version constant.

> The full changelog in Chinese — including all historical entries — lives in
> [doc/CHANGELOG_zh-CN.md](doc/CHANGELOG_zh-CN.md).

## 1.4.0 (2026-10-03)

Content-aware placement + hard-edged tension. **This release ships two
deliberate breaking changes, both approved as product decisions before
implementation (H1 and H2 below).** No JSON schema change, no new required
keys, no migration step — what moved is the *default values* and the
*meaning of* `legacy`, so every config that pins a value renders exactly as
before and only unpinned configs move.

### H1 — shipping defaults changed in place

- `quality.tier`: `legacy` → **`standard`**. Out-of-box output now uses the
  anti-aliased raster primitives, area-average / Catmull-Rom resampling,
  screen light blending and the quantization LUT.
- `parallax.amplitude`: `0.012` → **`0.030`**, with the matching §6.1 raises
  (`breathing.amplitude` 0.006 → 0.012, `ambient.opacity` 0.16 → 0.22,
  `mangaShake.amplitude` 0.009 → 0.018, `heartbeat.intensity` 0.012 → 0.020,
  `slowPush.pushFrac` 0.035 → 0.060). Complaint driving this round: the motion
  read as "almost no movement".
- `contentAware` → **`true`**, `panelAware` → **`true`** (see the placement
  section; each gate rolls back independently).
- `quality.dither`: back to **`false`** (R38). Error diffusion multiplies GIF
  bytes by ×2.2–2.4, which does not pay off on flat-ink + line-art source
  material; sharpness comes from the standard tier, not from dithering.
  `quality.ditherMode` keeps its `sierra` default but is *dormant* — it only
  picks a kernel once `dither: true` is set explicitly.
- Because keys equal to their default stay omitted, the serialized shape of the
  default config never changed; only the bytes each config renders to moved.

### H2 — `legacy` narrowed to "the old pixel algorithm"

- `tier: legacy` still freezes the *drawing* path (no AA raster, bilinear /
  nearest resampling, plain source-over ink, v1.2 quantizer) and remains
  selectable and losslessly round-trippable. It **no longer promises
  byte-identical output versus the 2026-09-14 v1.2 baseline**, because the
  seamless-loop work rewrote the shared time base for *both* arms — integer
  whole-cycle period alignment (R18), integer vertical cycle count (R19) —
  and the anti-phase layer stepping (R16) is a phase constant, not a pixel
  algorithm. None of those are tier-gated.
- Consequently the rollback drill on `presets/classic.json` reports **0/10**
  against the frozen v1.2 digests. That is the documented, sanctioned state,
  not a regression; within-version determinism (same seed + same params →
  identical bytes) is untouched.
- **One-off `configHash` re-baseline** (the only one in this release): the
  absolute fingerprints pinned in `test/engine_test.dart`,
  `test/polarity_test.dart` and `test/saliency_test.dart` — 11 literal sites
  in total (4 / 6 / 1), the only hash literals anywhere in the repo (nothing in
  `lib/`, `tool/` or the server package) — were re-anchored from printed
  actuals: 10 moved, 1 added for the new rollback preset. New anchors: default
  config `-2a0679b63611bcad`, `EffectConfig(fps: 12, durationSec: 3.0,
  maxDimension: 640)` (= `presets/classic.json`) `-55953db41ee98064`,
  `presets/legacy_v1.0.json` `-57e243b1ecfc30c`.
  The speed-lines legacy golden is the instructive case: its *rendered* digest
  was `-68ddcb969faac38c` in every 3.2→3.6d round, re-measured independently
  each time — that stability is the evidence that the legacy drawing path was
  never touched by the 3.6 series. The literal nevertheless moved onto that
  value because it had been stale since before 3.1 (`-5c5313f1ec3636db`), when
  the amplitude default still applied. The other four legacy digests
  (flash/sweep/focus/all) had not been re-printed since 3.1 at all: the digest
  map is a fail-fast loop, so the first red hid the rest and every per-round
  census was a lower bound. Their movement is the shared time base
  (R16/R18/R19), not the pixel path — exactly the distinction H2 draws.
- `presets/legacy_v1.0.json` (R40) is now the rollback file to reach for:
  v1.0.0 *numbers* + explicit `tier: legacy` + `dither: false` + both placement
  gates written as `false`. It is a **behavior-level** rollback, not a
  byte-level one (R46b). Its `durationSec` is `6.0` rather than v1.0.0's `3.0`
  — the single deliberate deviation — because only 6.0 represents
  `parallax.periodSec 6.0` exactly under the whole-cycle rule.

### Content-aware placement (Phase 1–2)

- New `AnchorMap` (`lib/src/content/`): saliency/activity field, subject box,
  non-max-suppressed focal anchors, per-panel anchors, computed once per render
  and threaded through the pipeline, the frame workers and the interaction-frame
  export (R37).
- Placement consumers: `focusLines` / `impactRings` anchor on the focal point
  instead of canvas center; particle seeding is weighted by the activity field
  instead of uniform-random; panel overlays clip to panel bounds; ink polarity
  adapts to local luminance.
- `contentAware` (per-effect anchoring) and `panelAware` (per-panel layering)
  are two orthogonal gates and roll back independently. Both are conditionally
  serialized with the omit-if-default idiom, so `"contentAware": false` /
  `"panelAware": false` persist and round-trip losslessly.
- JSON sanitize rule for both gates (documented in the catalog and the server
  API doc): a missing key or explicit `null` means "not said" → default `true`;
  only a strict boolean `true` enables the gate, and non-bool values (`1`,
  `"yes"`) are treated as `false` → the rollback arm.

### Tension (Phase 3)

- Anti-phase layer parallax (R16): neighbouring depth layers sweep opposite
  ways, parity taken from `depthRank` (F2) so it is stable across panels.
- `snapWave` easing (R3.3/R3.4) now shapes `mangaShake`, `speedLines` and
  `impactRings` at standard+ — a fast attack to the peak, then a hard cut
  (起—峰—断): the wave's negative lobe is clamped to zero, so the second half
  of the pulse is silent instead of a slow decay. For `impactRings` the ink
  window is exactly 0 for ph ≳ 0.539 (≈44% of the loop). This is deliberately
  *not* described as "快起慢落" — there is no long tail.
  The legacy arm keeps `sin` verbatim, and the shape difference is guarded by a
  rendered-pixel discriminator test (`test/snap_wave_passes_test.dart`) rather
  than a formula check.
- `periodSec` auto-aligns to a whole number of cycles over the clip (R18) and
  the vertical parallax axis to an integer cycle count (R19), so loops are
  seamless at any duration instead of drifting on the last frame.

### Presets, catalog and docs

- `presets/` is 42 files: the 40 showcase presets (single effects, combos and
  the three showcase bases) regenerated from the single-source generator, plus
  `classic.json` and the new `legacy_v1.0.json` anchor. Note that era labels
  ("v1.1/v1.2-era") describe effect lists, not tiers — after the regeneration
  only `legacy_v1.0.json` writes a `tier`; 40 presets omit the `quality`
  segment entirely and `dither_compare_forest.json` writes only
  `"dither": true` (it is the dither demo). R40's rollback anchor keeps its
  `"dither": false` written out by hand — that file expresses intent, not a
  `toJson()` emission.
- `param_catalog.dart`: `contentAware` and `panelAware` rows added (the catalog
  is the fifth lockstep source for defaults, guarded against the constructor);
  the `qualityTier` row corrected for H2; `strictRange` wording now states the
  actual out-of-range behavior per parameter (raw linear scaling / pass-internal
  clamp / trigonometric wrap / enum-string fallback) instead of implying a
  universal clamp.
- README (EN + zh), `comic_motion_server/docs/api.md`, `docs/deploy.md` and
  `doc/motion_catalog_v13.md` synced to the new defaults and the narrowed
  `legacy` wording; the CLI `--quality` help no longer claims v1.2 bytes.

### Record-only corrections and known limitations

- Commit `597aefb` ("presets re-emitted … with aligned periods") **overstated**
  what it did: the presets deliberately keep `periodSec` at 6.0 / 4.0 and the
  alignment is applied at render time by R18. History is not amended; the real
  semantics are stated here.
- **§6.1 stale-re-emission guard blind spot** (accepted by ruling): the preset
  guard asserts `value >= new default × 0.8`, and the old `breathing.amplitude`
  variant `0.010` coincides with a legitimate new value (`0.010` = 0.005 × 2.0),
  so a single-file stale re-emission of those two breathing presets is not
  caught. A batch drift still trips the other five keys. The floor was not
  raised back to the default (that would turn the committed presets red), and no
  generator data was changed for this.
- **Discarded saliency scan** (Ruling #14): layer export now pays one saliency
  scan whose result the renderer discards in that path. Documented as an
  intended trunk cost (render and export share one analysis entry point); no
  knob added.
- **`rich` remains byte-equivalent to `standard`** (reserved `supersample` /
  `mipLevels` have no consumer yet) — unchanged known deviation.
- **Multi-panel pages cost more at the 1600 cap, and breach two red lines**
  (measured, medians of 3 bench runs): a real two-panel page at the shipping
  default tier takes **8.17 s** against the `≤7 s` preview red line (breached
  in 2 of 3 runs) and peaks at **1033 MB**, which breaks the 780 MB
  `parallel=1` serial line (the 1150 MB multi-worker line still holds). Cause:
  `panelAware` (on by default since R39) keeps a layer raster per panel, so
  peak RSS scales with panel count, not only with working pixels — 647 MB
  single-page vs 1033 MB two-page at the same `maxDimension`. **No threshold
  was moved.** Mitigation for deployment: pass `memoryBudgetMb` (it degrades
  working resolution before OOM and records a warning), or cap
  `maxDimension` at 1080, or use ≥2 workers on such pages. Full before/after
  rows are in both READMEs' performance sections.

Test surface: 393 engine cases + server contract cases, all green, no skips.
`dart analyze lib tool test` clean.

## 1.3.2 (2026-09-29)


Publishing and documentation polish; no behavior changes. The
byte-reproducibility contract is untouched (253 core + 6 server tests green).

- **Runnable example** (`example/example.dart`): renders a short
  layered-effect sequence end to end (`MotionPipeline` with `onProgress` +
  `processFile`), so the package now ships a standard `example/` entry point.
- **Docs**: package description shortened; CHANGELOG fully in English (the
  historical Chinese changelog moved to `doc/CHANGELOG_zh-CN.md`).
- **Lint**: snake_case local names in `src/render/resampler.dart` renamed to
  lowerCamelCase; stale dartdoc references cleaned up.

## 1.3.1 (2026-09-28)

Release-oriented rework + runtime lifecycle + correctness protection +
high-fps and ecosystem, published together. The byte-reproducibility contract
held throughout (legacy pixel path and encoder bytes untouched; test guard
grew to 253 core + 6 server cases, all green).

### High-fps & ecosystem

- **Roadmap refresh** (`doc/roadmap.md`): implemented items removed; remaining
  = GPU particle effects (shader companion, phase 2), AI model depth (kept
  behind the `DepthEstimator` injection route), animated WebP fallback,
  multi-axis interaction frame sets (new).
- **Injectable AI depth (architecture)**: `DepthEstimator` is now an abstract
  interface (`estimate(RgbaImage) → DepthMap`); the built-in heuristic
  implementation was renamed `HeuristicDepthEstimator` (breaking rename,
  pixel output byte-identical, test-locked). `MotionPipeline(depthEstimator:)`
  accepts external ML estimators (e.g. tflite on the app side) while the core
  stays dependency-free. New `exportLayers` / `exportLayersFile`
  (`lib/src/layer_export.dart`): layered raster export to PNG texture set +
  `index.json` (`kind: layers`), pixel-identical to the pipeline's internal
  layering; output dir `<stem>_<contentHash8>_<configHash8>_layers/`.
  New `doc/external-depth.md` and `test/depth_interface_test.dart`.
- **Panel-aware layering (MVP, horizontal panels only)**: new `PanelSplitter`
  (horizontal whitespace scanning; ≥2 panels required, falls back to
  full-page otherwise) and `EffectConfig.panelAware` (opt-in, conditionally
  serialized — default false keeps the fingerprint unchanged). Per-panel
  independent depth/layering with cross-panel bleed eliminated (test-locked),
  panel-relative parallax normalization, deterministic in both parallel and
  serial runs, orthogonal to strip mode. New `test/panel_aware_test.dart`.
- **High-fps presets**: `encoding.apngDelay: 'exact'` (opt-in) writes exact
  fcTL fractional delays (60fps = 16.67ms; the default `cs` variant stays
  byte-identical to 1.3). **APNG rect inter-frame diffing** (`diffMode: rect`
  extended to APNG): worker returns full-frame RGBA, the main isolate diffs
  change rects → area frames (dispose=NONE/blend=SOURCE; 1x1 placeholder
  keeps timing), O(single frame) memory. New `tool/bench_high_fps.dart`
  (rect saves 41–57% for local motion; zero gain for full-frame motion) and
  `doc/high-fps.md`. `estimateCost` now covers APNG/rect.
- **Deterministic preview assets**: `tool/generate_showcase.dart
  --previews-only` produces 40 low-res previews (8fps, 1.5s, ≤360px, each
  GIF < 300KB) under `doc/previews/<demo>/` with a deterministic `index.json`
  (two runs are byte-identical, sha1-locked); `kEffectPreviewRefs` maps all
  32 effects to previews; README links.

### HarmonyOS reader-aligned effects (cumulative in 1.3.1)

- Roadmap and capability-boundary statement: pre-rendered motion graphics
  (GIF/APNG/frame sets), not realtime interactive rendering; realtime path
  tracked in `doc/roadmap.md`.
- **Flutter companion package `comic_motion_flutter`**: one-way dependency on
  the core (core stays pure Dart). `MotionGifView` (placeholder crossfade,
  playback control, reduce-motion, entrance frames) and `ParallaxGyroView`
  (gyro/touch/injected-stream parallax) + power-aware strategy +
  `PageCurlView` simulated page-curl turn. See that package's CHANGELOG.
- **APNG streaming encoder**: `OutputFormat.apng` (opt-in) + top-level
  `encodeApng` + `StreamingApngBuilder` (`addFrame`/`addEncodedPngFrame`/
  `finish`, O(single frame) memory) — reuses existing PNG IDAT payloads
  byte-for-byte; numPlays=0 loop semantics; parallel and serial output are
  byte-identical (test-locked); `PipelineResult.outputApng` /
  `MemoryPipelineResult.apngBytes`; plus `decodeApngScanlines` for consumers
  and tests.
- **Entrance frame sequences**: `exportEntranceFrames` / `exportEntranceFramesFile`
  — blur-to-sharp reveal with optional zoom (default 12 frames); last frame
  is byte-identical to the working-resolution original (test-locked); index
  JSON carries `loop: false, holdOnLast: true`.
- **Interactive parallax frame sets**: `exportInteractionFrames` /
  `exportInteractionFramesFile` — `steps` × `axis` (horizontal/vertical/both);
  `FrameCompositor.parallaxOverride`; `MotionCacheManager` recognizes all
  export kinds (`kind` field); `E_CANCELLED`/`E_TIMEOUT` semantics shared.

### Runtime lifecycle (cumulative in 1.3.1)

- **In-memory pipeline**: `processBytes({required input, maxPixels})` →
  `MemoryPipelineResult` (`gifBytes` / `paramsJsonBytes`, no paths); shared
  `_runCore` keeps memory and on-disk output byte-identical.
- **Cancellation / progress / timeout / keepPartial**: checkpointed at the
  main-isolate frame dispatch layer; timeout via deadline comparison; cancel
  cleans partial output and throws `MotionCancelledException`. New
  `lib/src/cancellation.dart`.
- **Background isolate entry points**: `processFileInBackground` /
  `processBytesInBackground` — full pipeline including decode off the main
  isolate; exceptions re-thrown across isolates; README "thread model"
  warning added; `example/04` demo.
- **Concurrency guard (opt-in)**: `MotionPipelineGuard` process-level FIFO
  semaphore (`configure(maxConcurrent)`, default 1).
- **One-shot render params**: top-level `dither` / `qualityTier` /
  `amplitude` / `directionDeg` (null = untouched; byte-equal serialization
  and configHash vs explicit nesting, matrix-tested).
- **Effect selection API**: `withEffect` / `withoutEffect` / `withEffects` /
  `clearEffects` — immutable, always return new instances.
- **Param catalog**: `ParamSpec` + `kRenderParamSpecs` + `kEffectNames` for
  app-side dynamic settings panels; persistence via
  `EffectConfig.toJsonString()` round-trip.
- **Webtoon strip mode**: `StripSplitter` (viewport-ratio slices, default
  9:16, optional overlap) + `processStrip` (per-slice standard pipeline,
  `<stem>_slice<NNN>_<hash8>/` dirs, slice-level configHash) +
  `kStripSafeEffects` whitelist; `MotionPipeline.processImage` as the decoded
  input entry; oversized tall images hint `E_TOO_LARGE` with strip guidance.
- **Input format matrix (docs)**: JPEG/PNG/static WebP; animated WebP/GIF
  decode to first frame (test-locked behavior contract); AVIF/HEIF rejected
  with `E_DECODE_CORRUPT`.
- **Cost estimation**: `estimateCost(config, {sourceWidth, sourceHeight})` →
  memory/time ranges + working resolution + frame count.
- **Mobile reference ranges (docs)**: draft/typical/low-end tiers in the
  README, explicitly not device-calibrated.

### Correctness & output consumption (cumulative in 1.3.1)

- **Content-hash cache keying**: output dirs renamed to
  `<stem>_<contentHash8>_<configHash8>` (strip slices included); re-downloaded
  files no longer hit stale renders. `PipelineResult.contentHash` added.
- **First/still frame APIs**: `renderStillFrame(File)` (single-frame render,
  skips GIF encode; t=0 pixel-identical to first frame) + optional
  `includeFirstFrame` on all entry points.
- **Cache manager**: `MotionCacheManager` (listEntries / totalSize /
  purgeLRU / purgePrefix / purgeAll; only deletes contract-matching dirs).
- **Frame-stream callback**: `onFrame(frameIndex, pngBytes)` — ordered,
  exactly once per frame, same bytes as `frames/frame_NNNN.png`.
- **GIF rect diffing (opt-in)**: `EncodingParams.encoding.diffMode: none|rect`
  (conditionally serialized; default keeps fingerprints unchanged);
  quantized-index diffing with disposal=1 sub-rect LZW encoding;
  GIF89a-spec reference decoder in tests; strip slices benefit automatically.
- **Web support status (docs)**: not supported — dart:io and Isolate.spawn
  dependencies documented.
- **rich tier**: documented as byte-equal to `standard`; `RenderTier.rich`
  deprecated (JSON still parses for compatibility).
- **GIF playback guide (docs)**: Flutter-side consumption chapter
  (Image/extended_image/instantiateImageCodec trade-offs, decode memory
  levers, cover placeholders, warm-up/pause/reduce-motion strategies).
- **Release-ready packaging**: package docs moved to `doc/` per pub layout.

### ⚠ BREAKING CHANGE

- Output directory naming: `<stem>_<configHash8>` →
  `<stem>_<contentHash8>_<configHash8>` (strip slices included). Old dirs are
  not recognized by the new layout; clean old caches on the consumer side.
- `EffectConfig.fromFile` moved to the IO boundary: use the top-level
  `effectConfigFromFile(path)` (barrel-exported; error wrapping and codes
  unchanged). `effect_config.dart` is now pure Dart (no dart:io).
- `EngineWorkerException.code` changed from a static constant to an instance
  field (value still `E_WORKER_CRASH`).

## 1.3.0

See [doc/CHANGELOG_zh-CN.md](doc/CHANGELOG_zh-CN.md) (Chinese changelog).
