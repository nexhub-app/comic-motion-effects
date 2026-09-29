# Changelog

All notable changes to this project are documented in this file. Versioning
follows [SemVer](https://semver.org/). `pubspec.yaml`, `lib/src/version.dart`
and `dart run bin/comic_motion.dart --version` share one version constant.

> The full changelog in Chinese — including all historical entries — lives in
> [doc/CHANGELOG_zh-CN.md](doc/CHANGELOG_zh-CN.md).

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
