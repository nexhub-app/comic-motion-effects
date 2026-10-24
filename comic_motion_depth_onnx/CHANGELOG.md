# Changelog

All notable changes to this project are documented in this file.

## 0.1.0 (2026-10-24)

Initial release: opt-in on-device depth estimation for comic_motion.

- `DepthSession` seam isolating `onnxruntime_v2` types behind a minimal
  interface; unit tests run against a fake session (no native runtime in
  the test path).
- `OrtSessionAdapter` — thin production adapter (session creation and
  inference must happen inside the consuming isolate).
- `OnnxDepthEstimator` — MiDaS v2.1 small 256 (NCHW preprocessing,
  ImageNet normalization, min-max normalized output), line-for-line the
  configuration verified in the end-to-end probe.
- Real-model integration test (self-skipping when the machine-local QDQ
  model is absent): model load + single estimate + deterministic
  background-chain runs.

### Known limitations

- CPU execution provider only; Windows verified, other platforms follow
  `onnxruntime_v2`'s matrix without individual verification.
- The host supplies model bytes; no networking or caching in this package.
