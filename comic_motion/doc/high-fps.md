# High-fps pre-render (APNG 60 fps) — tiers & guidance (W3)

60 fps is the perceptual target for "smooth as system animation" motion
effects. The engine supports it via **APNG + exact frame delay**
(`encoding.apngDelay: 'exact'`) and optional **rect inter-frame diff**
(`encoding.diffMode: 'rect'`). This doc records measured numbers and the
recommended parameter matrix.

## Frame delay precision

APNG fcTL stores the frame delay as a 16.16 fixed-point fraction
(`delay_num / delay_den`). Math and reality agree:

- Default `cs` tier: `delay_num = (100/fps).round()`, `delay_den = 100` —
  same rounding as GIF. At 60 fps this degrades to 20 ms = **50 fps**.
- `exact` tier (opt-in): `delay_num = 1`, `delay_den = fps` — 60 fps is
  expressed precisely as 1/60 s = **16.67 ms**. Verified by unit test
  parsing fcTL chunks back out of the produced container.

`exact` only affects the APNG path; GIF output bytes are untouched. With
the field absent (default), APNG output stays byte-identical to v1.3.

## Measured data (bench_high_fps)

`dart run tool/bench_high_fps.dart sample_images/02_action.png` — 60 fps,
2 s loop = 120 frames, seed 7, desktop (parallel workers), legacy tier,
no dither. Output size is deterministic (same seed → same bytes); timings
and RSS are indicative.

| Scenario | Container / diff | 360p | 540p | 720p | time vs full |
|---|---|---|---|---|---|
| lightSweep (local motion) | APNG full | 3294 KB | 6496 KB | 10490 KB | 1.0× |
| lightSweep (local motion) | APNG rect | **1954 KB (−41%)** | **3147 KB (−52%)** | **4463 KB (−57%)** | 1.2–1.3× |
| rain (global motion) | APNG full | 3235 KB | 6381 KB | 10335 KB | 1.0× |
| rain (global motion) | APNG rect | 3230 KB (±0) | 6368 KB (±0) | 10313 KB (±0) | 1.8–2.0× |
| rain (global motion) | GIF 24 fps full | — | — | 1660 KB | 0.65× |

Peak RSS at 540p/60fps: ~533 MB (parallel desktop run, same ballpark as
the 1080p/24fps legacy scenario). Rect diff adds one extra full-frame RGBA
buffer in the main isolate (O(single frame)), not per worker.

## Recommendation matrix

| maxDimension | fps | diffMode | dither | Use for |
|---|---|---|---|---|
| 360–540 | 60 | `none` | `false` | Default high-fps loop; any effect |
| 360–720 | 60 | `rect` | `false` | **Local-motion effects only** (lightSweep, impactFlash, screenTone pulses, small-region accents) |
| ≤540 | 60 | `rect` | `false` | Chat bubbles / inline preview cards where <5 MB matters |
| any | 24 | `none` | `true` | Photographic gradients where 256-color GIF banding shows; keep GIF for compatibility |
| any | 24 | `rect` | — | GIF fallback where the consumer cannot decode APNG |

Rules of thumb:

1. **diffMode: rect pays off only when motion is spatially local.** The
   diff bounding box of a full-frame effect (rain, snow, focusLines,
   mangaShake's whole-frame shake) is the whole canvas — zero size win,
   ~2× encode time. Local sweeps/impacts shrink 40–57%.
2. **exact delay is free** — always enable it for APNG at ≥30 fps;
   otherwise 60 fps silently plays at 50 fps.
3. **True color vs palette:** APNG is ~6× GIF's size for the same frame
   budget (真彩色 vs 256 色). If size is the binding constraint, prefer
   24 fps GIF; if smoothness is the binding constraint, prefer 60 fps
   APNG with `rect` where motion allows.
4. **2 s loop is the sweet spot**: 120 frames at 60 fps keeps a 720p APNG
   around 10 MB full / 4.5 MB rect (local motion) — acceptable for local
   assets, still heavy for network delivery. Shorten `durationSec` before
   dropping fps.

## API

```json
{
  "outputFormat": "apng",
  "fps": 60,
  "durationSec": 2.0,
  "encoding": { "diffMode": "rect", "apngDelay": "exact" }
}
```

- `encoding.apngDelay`: `'cs'` (default, byte-compatible) | `'exact'`.
- `encoding.diffMode`: `'none'` (default) | `'rect'` — applies to the GIF
  path (quantized-index diff) and, since W3, the APNG path (byte-exact
  RGBA diff → region frames with fcTL offsets; unchanged pixels persist
  via `dispose_op = NONE`).
- `estimateCost` accounts for the APNG/rect paths (output-size and time
  multipliers) so apps can pre-check feasibility on low-end devices.
