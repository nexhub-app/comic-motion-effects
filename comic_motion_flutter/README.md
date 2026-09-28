# comic_motion_flutter

[English](README.md) | [简体中文](README_zh-CN.md)

Flutter companion package for
[**comic_motion**](../comic_motion) — ready-made widgets that consume the
engine's rendered output so embedding apps write no decoding/animation code.

The core package stays **pure Dart** (zero Flutter deps); this package is a
one-way dependent companion:

```
comic_motion (pure Dart engine)  ←  comic_motion_flutter (widgets)
                                 ←  comic_motion_server (CLI / HTTP)
```

## Widgets

### MotionGifView — playback of the full-render output

| Capability | Detail |
|---|---|
| Seamless placeholder | `firstFramePng` shown instantly, crossfades out (default 150ms, `Duration.zero` = hard cut) when the GIF's first frame finishes decoding |
| Playback control | `playing` externally driven pause/resume; `loop: false` holds on the last frame |
| Reduced motion | Honors `MediaQuery.disableAnimations` — static placeholder, no codec (`respectReducedMotion`) |
| Entrance frames | Optional V2 entrance PNG sequence plays first (blur → sharp reveal), then hands over to the GIF loop |

```dart
MotionGifView(
  gifBytes: gif,            // MemoryPipelineResult.gifBytes / anim.gif
  firstFramePng: cover,     // MemoryPipelineResult.firstFramePng
  entranceFrames: entrance, // optional: exportEntranceFrames output
)
```

### ParallaxGyroView — interactive parallax over V1 frame sets

Three input drivers (injected stream wins if provided):

1. **Gyroscope** (default) — accelerometer → normalized tilt phase
   (`maxTiltDeg`, default 15°), throttled to ~60fps with a 0.01 dead zone;
2. **Touch fallback** (`touchFallback`) — pan gesture maps half-viewport drag
   to full phase; desktops and gyro-less devices work out of the box;
3. **Injected stream** (`tiltStream`) — `Stream<Offset>` in [-1,1]; no sensor
   subscription. This is the test/mock and custom-driver (joystick etc.) hook.

Interpolation (`smooth`): `true` (default) blends the two neighboring frames
with alpha; `false` switches to the nearest frame (zero-overhead baseline).

```dart
final sets = await loadInteractionSets(interactiveDir); // disk
// or: loadInteractionSetsFromIndexJson(indexBytes, loadFrame: ...) // assets

ParallaxGyroView(frames: sets.first) // both-export: pick axis per view
```

## Pure-Dart helpers (unit-testable without Flutter)

- `loadInteractionSets(dir)` — load `<...>_interactive/` from disk;
- `loadInteractionSetsFromIndexJson(bytes, loadFrame:)` — load from any
  byte store (assets, network, WASM) via a fetch callback;
- `tiltToPhase(ax, ay, az, maxTiltRad)` — accelerometer → `(phaseX, phaseY)`,
  the reference tilt model (roll/pitch atan2 normalization).

## Memory notes

- Frame-set PNGs stay resident via `Image`'s decode cache (global
  `ImageCache` bound). Keep frame-set resolution ≤ ~1.5× the display size.
- `MotionGifView` decodes through `ui.instantiateImageCodec`; heavy render
  work belongs to the core package's background entry points
  (`processFileInBackground` etc.) — see the core README's threading model.

## Installation

```yaml
dependencies:
  comic_motion_flutter: ^0.1.0
```

Inside this monorepo the packages wire up with `pubspec_overrides.yaml`
path deps; see `comic_motion_flutter/pubspec_overrides.yaml`.

## Requirements

| Item | Requirement |
|---|---|
| Flutter | ≥ 3.22 (Dart ≥ 3.4.0) |
| Core package | `comic_motion: ^1.3.0` |
| Sensors (optional) | `sensors_plus ^6.1.1` — only used when `tiltStream` is null |

## License

Apache-2.0. See [LICENSE](LICENSE).
