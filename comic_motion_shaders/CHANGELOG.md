# Changelog

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
