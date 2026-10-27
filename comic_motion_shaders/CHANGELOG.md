# Changelog

## 0.2.0 (2026-10-25)

- **Camera + focus uniform block**: `MotionUniforms` gains an additive tail —
  camera block at indices 19..25 (`on`, `mode`, `anchor`, `zoomSpan`,
  `driftAmp`, `phase`) and focus block at 26..27 (`on`, `scaleMul`).
  `kFloatCount` 19 → 28; the existing 0..18 layout contract is untouched, so
  callers that only set parallax/breathing/sweep/vignette keep working.
- **`comic_motion.frag`** declares and applies the new uniforms: a
  full-canvas affine around the program anchor (`pushIn` via a cosine
  round-trip, `drift` via sine plus coverage zoom). Phase 0 is the rest
  identity, so the first frame is still the author's drawing. The focus block
  raises the camera span and parallax amplitude by `scaleMul` and falls back
  when focus is off.
- **`withPackProgram` / `cameraPhaseFor`**: map a core `MotionProgram` to
  uniforms, so `program.json` and the shader consume the same data. Whole-cycle
  phase alignment; `tempoMul` applies at the host phase.
- Requires `comic_motion: ^1.9.0` (the program types land in that version).
  Layout-contract / mapping / clamping tests: 10 → 17.

## 0.1.1 (2026-09-29)

- **Docs**: added an English README (the Chinese version now lives at
  `README_zh-CN.md`); package description shortened.

## 0.1.0

Initial release.

- **`RealtimeMotionView`**: FragmentShader realtime rendering of layered
  textures (consumes the core engine's `exportLayers` output). A Ticker
  drives the breathing phase and sweep position; parallax uniforms are driven
  directly by external signals (touch/gyroscope). `playing: false` freezes
  the clock.
- **Uber-shader** `assets/shaders/comic_motion.frag`: a single fragment
  shader with uniform switches for four parameterized transforms — parallax /
  breathing / lightSweep / vignette; 4 sampler inputs, empty slots filled
  with 1x1 transparent placeholders.
- **`MotionUniforms`**: pure-Dart uniform mapping (layout contract constants
  `kIndex*`, range clamping, fixed-length `depthFactors`).
- **`decodeLayerTextures`**: layered PNG bytes → `ui.Image` list (up to 4
  layers).
- Example: procedural placeholder layers + slider/FilterChip live tuning.
- Tests: uniform layout contract / clamping / clock mapping unit tests
  (golden tests of the shader itself are an optional follow-up).
