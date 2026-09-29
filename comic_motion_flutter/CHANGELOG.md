# Changelog

All notable changes to this project are documented in this file. Versioning
follows [SemVer](https://semver.org/).

## Unreleased

- **Dependencies**: `sensors_plus` `^6.1.1` → `^7.0.0`. The 7.0.0 breaking
  changes are Android build-side only (AGP ≥8.12.1, Gradle wrapper ≥8.13,
  Kotlin 2.2.0); the Dart event API is unchanged. Apps building for Android
  must meet the new toolchain requirements; iOS/desktop/Web are unaffected.

## 0.1.0

Initial release. Flutter companion package; depends one-way on the core
`comic_motion` engine (which stays pure Dart with zero Flutter dependencies).

- **MotionGifView**: GIF playback view — `firstFramePng` placeholder with
  seamless crossfade (default 150ms, `Duration.zero` for a hard cut),
  external `playing`/`loop` control (`loop: false` holds the last frame),
  system reduce-motion static frame (`MediaQuery.disableAnimations`, no
  decode), entrance frame sequence played before the GIF loop, automatic
  rebuild on byte change.
- **ParallaxGyroView**: touch/gyro parallax over interaction frame sets —
  three drivers: sensors_plus gyroscope (`tiltToPhase` euler-angle
  normalization, `maxTiltDeg` default 15°, ~60fps throttle + 0.01 dead
  zone), touch drag fallback ("half viewport = full phase") with
  `returnToCenter`, and a `tiltStream` injection stream (when non-null the
  sensors are not subscribed — test mocks and custom drivers); `smooth`
  alpha blending between adjacent frames or nearest-frame hard cut.
- **Pure Dart helpers** (unit-testable without Flutter): `loadInteractionSets`
  (disk directory) / `loadInteractionSetsFromIndexJson` (index.json bytes +
  frame-fetch callback, usable from assets/network/WASM), `tiltToPhase` /
  `degToRad`.
- Tests: tilt-phase mapping, frame-set loading contract (kind/axis validation,
  frame-count consistency), widget tests (injected phase→frame mapping,
  smooth blending, touch fallback and re-centering, empty frame-set fallback,
  placeholder transition, reduce motion, entrance sequence, rebuild on byte
  change).

### Power-aware motion strategy

- **Three-signal aggregation mixin `MotionPowerAware`** (new file
  `lib/src/power_aware.dart`, reusable by custom views): lifecycle
  (suppress when leaving `resumed`, on by default), viewport
  (`pauseWhenNotVisible` opt-in — lazy self-check driven by scroll
  notifications: intersect the RenderBox global rect with the window, freeze
  when scrolled out and restore when back; scroll-based visibility only,
  static occlusion is not detected), and an app policy hook
  (`enableMotion: bool Function()?` — low-battery and other policies are up
  to the app; **this package adds no battery dependency**). Aggregation
  changes fire `onMotionSuppressed` / `onMotionRestored`.
- **MotionGifView**: suppression terminates the frame pump loop (generation
  invalidation, same path as `playing: false`); the bootstrap pump checks
  the aggregated state first. Default parameters
  (`pauseWhenNotVisible: false`, null hook) behave exactly as before.
- **ParallaxGyroView**: suppression fully disconnects sensor/injected
  subscriptions (zero ongoing cost) and reconnects automatically on restore;
  subscription state is driven uniformly by `_syncInput`.
- Tests: freeze-restore transitions across all three paths (viewport /
  lifecycle / hook), 3 cases each (GIF asserted via multi-frame pump
  advance, Gyro via injected phase→frame mapping).

### PageCurlView simulated page-curl turn

- **PageCurlView**: Flutter port of the Canvas reference implementation,
  matching five behaviors of the target page-turn feel — curl curvature
  (vertical strips + cylindrical-projection compression approximation, drag
  speed controls stiffness, `curlStrips` default 28), drag tracking (progress
  = displacement / viewport width), release overshoot (threshold + velocity
  dual criteria, 1.045 peak rubber-band, plain bounce-back below threshold),
  dual-layer lighting (strip highlight / paper back / fold shadow / page-edge
  shadow), and idle breathing micro-motion (±0.4%, 6s period, zero raster
  cost via canvas transform).
- **On-demand page snapshot** (confirmed during design): normally shows the
  native widget; the instant a drag/tap turn starts, both front/back pages
  are captured through a RepaintBoundary as `ui.Image` (pixelRatio clamped to
  [1,3], long edge capped at 2048); capture failure degrades to an instant
  page switch; committing a turn promotes the target snapshot to the current
  page snapshot (zero duplicate capture).
- **Performance**: gesture frames use `CustomPainter` + repaint listenable
  partial repaints — zero widget rebuilds; builder subtrees are cached per
  page; page-index/content-source changes invalidate and re-capture
  automatically.
- **Hooks and fallbacks**: `onPageTurnStart`/`onPageTurnEnd` let apps attach
  their own sound/haptics (no audio/vibration dependencies); system
  reduce-motion falls back to a translate+fade transition (no capture, no
  breathing); `enableTapTurn` tap-half-screen turning, page boundary
  protection, adjustable `initialPage`/`turnDuration`/`commitThreshold`/
  `commitVelocity`.
- Tests: tap-turn callback ordering (Start fired at gesture start, End after
  the commit tween), page boundary protection, short-drag bounce
  (committed=false), long-drag commit, progress tracking (`progressOf` test
  probe), reduce-motion page change, zero builder rebuilds during drags,
  dispose smoke test. The example app gained a page-curl demo page.

> Release ordering: this package consumes the engine's interaction/entrance
> APIs (`exportInteractionFrames` / `exportEntranceFrames`); the engine must
> publish a version containing them first, and this package's
> `pubspec.yaml` lower bound must be raised accordingly (see the core
> package's `doc/release_checklist.md`, section 2).
