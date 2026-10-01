import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:comic_motion/comic_motion.dart';

RgbaImage whitePage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var i = 0; i < img.pixelCount; i++) img.setPixel(i % w, i ~/ w, 250, 250, 250);
  return img;
}
void inkBlob(RgbaImage img, int cx, int cy, int r) {
  for (var y = cy - r; y <= cy + r; y++)
    for (var x = cx - r; x <= cx + r; x++)
      if (x >= 0 && y >= 0 && x < img.width && y < img.height &&
          (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r)
        img.setPixel(x, y, 20, 20, 20);
}

/// Gray circular blob of luminance [v] — a weaker sibling of [inkBlob].
void _blob(RgbaImage img, int cx, int cy, int r, int v) {
  for (var y = cy - r; y <= cy + r; y++)
    for (var x = cx - r; x <= cx + r; x++)
      if (x >= 0 && y >= 0 && x < img.width && y < img.height &&
          (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r)
        img.setPixel(x, y, v, v, v);
}

void main() {
  test('activity peaks on dark ink blob, low on blank margin', () {
    final img = whitePage(64, 64);
    inkBlob(img, 32, 32, 8);
    final a = const SaliencyAnalyzer().activity(img, 64, 64);
    double at(int x, int y) => a[y * 64 + x];
    expect(at(32, 32), greaterThan(0.35));
    expect(at(2, 2), lessThan(at(32, 32) * 0.4));
  });

  test('activity stays absolute: near-white noise page max < 0.05', () {
    // Regression guard for R3: activity must be in ABSOLUTE units. A min/max
    // normalization ramp would push this low-contrast field's max toward 1.0
    // (its range exceeds the ramp's 1e-6 flat-field guard), breaking the
    // activity-weighted-particle fallback; <0.05 proves activity stayed
    // absolute. Fixture is a near-white page (base 250) with deterministic
    // ±2 per-pixel jitter (channels stay in [245,252]) — no ink, no RNG.
    final img = RgbaImage(width: 64, height: 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final jitter = ((x * 3 + y * 7) % 5) - 2; // deterministic, in [-2,2]
        final v = (250 + jitter).clamp(245, 252);
        img.setPixel(x, y, v, v, v);
      }
    }
    final a = const SaliencyAnalyzer().activity(img, 64, 64);
    final maxV = a.reduce((x, y) => x > y ? x : y);
    expect(maxV, lessThan(0.05));
  });

  test('subjectBox encloses the dark blob only', () {
    final img = whitePage(64, 64);
    inkBlob(img, 32, 32, 8);
    final s = const SaliencyAnalyzer();
    final box = s.subjectBox(s.activity(img, 64, 64), 64, 64);
    expect(box.x, lessThanOrEqualTo(25));
    expect(box.y, lessThanOrEqualTo(25));
    expect(box.x + box.width, greaterThanOrEqualTo(40));
    expect(box.y + box.height, greaterThanOrEqualTo(40));
    expect(box.width, lessThan(50));
  });

  test('anchors: two blobs → weight-ordered, darker ranks first', () {
    // NOTE: `subjectBox` returns only the LARGEST connected component, so this
    // box covers just the left ink blob; it proves in-blob (ring-maxima)
    // ordering. The cross-blob ranking claim is pinned by the next test, which
    // passes a box spanning BOTH blobs.
    final img = whitePage(64, 64);
    inkBlob(img, 16, 32, 6); // darker+higher-contrast → higher activity
    _blob(img, 48, 32, 6, 90); // mid gray
    final s = const SaliencyAnalyzer();
    final act = s.activity(img, 64, 64);
    final an = s.anchors(act, 64, 64, s.subjectBox(act, 64, 64));
    expect(an.length, greaterThanOrEqualTo(2));
    expect(an.first.nx, lessThan(0.5));
    expect(an.first.weight, greaterThanOrEqualTo(an[1].weight));
  });

  test('anchors rank every dark-blob anchor above every gray-blob anchor', () {
    // A full-canvas box makes BOTH blobs candidate sources, so this is the
    // test that actually proves cross-blob ranking (darker wins over weaker
    // regardless of scan position or cluster size). The mid-gray value 90 is
    // verified to clear the `mean + stddev` candidate threshold inside the
    // full-canvas box (probe: gray side yields an anchor at activity ~0.48 vs
    // the ink side ~0.62), so neither side can be silently empty.
    final img = whitePage(64, 64);
    inkBlob(img, 16, 32, 6); // dark ink, cx=16 → nx < 0.5
    _blob(img, 48, 32, 6, 90); // mid gray, cx=48 → nx > 0.5
    final s = const SaliencyAnalyzer();
    final act = s.activity(img, 64, 64);
    final an = s.anchors(act, 64, 64, const PixelRect(0, 0, 64, 64));

    final dark = an.where((a) => a.nx < 0.5).toList(); // left ink blob side
    final gray = an.where((a) => a.nx > 0.5).toList(); // right gray blob side
    expect(dark, isNotEmpty, reason: 'ink blob must yield an anchor');
    expect(gray, isNotEmpty, reason: 'gray blob must yield a real candidate');

    // Discriminating property: the weakest dark anchor still outranks the
    // strongest gray one, i.e. ordering is by activity not by blob locality.
    // Flipping the weight sort direction fails here.
    final minDark =
        dark.map((a) => a.weight).reduce((x, y) => x < y ? x : y);
    final maxGray =
        gray.map((a) => a.weight).reduce((x, y) => x > y ? x : y);
    expect(minDark, greaterThanOrEqualTo(maxGray));
    // And the whole list really is weight-descending.
    for (var i = 1; i < an.length; i++) {
      expect(an[i - 1].weight, greaterThanOrEqualTo(an[i].weight));
    }
  });

  test('anchors break exact weight ties row-major on a portrait grid', () {
    // Two candidates with IDENTICAL activity → both get weight 1.0, so only
    // the scan-order tie-break can order them. On this 4x8 grid the tie-break
    // must use the grid HEIGHT (row-major index = ny*h + nx): (x=3,y=1) has
    // index 7 and precedes (x=0,y=2) at index 8. Keying it by the grid WIDTH
    // (the bug) instead flips them on any non-square grid.
    final g = Float64List(4 * 8);
    for (var i = 0; i < g.length; i++) {
      g[i] = 0.1;
    }
    g[1 * 4 + 3] = 0.9; // (x=3, y=1) — row-major index 7
    g[2 * 4 + 0] = 0.9; // (x=0, y=2) — row-major index 8
    final an = const SaliencyAnalyzer()
        .anchors(g, 4, 8, const PixelRect(0, 0, 4, 8));
    expect(an.length, 2);
    expect(an[0].weight, 1.0);
    expect(an[1].weight, 1.0);
    expect(an[0].nx, 3 / 4);
    expect(an[0].ny, 1 / 8);
    expect(an[1].nx, 0.0);
    expect(an[1].ny, 2 / 8);
  });

  test('analyze with two panels keeps both halves and both rects', () {
    // Exercises the densest coordinate path in analyze(): canvas-pixel →
    // grid mapping, per-panel `_activityRegion` sub-grid, `merged.setRange`,
    // the per-panel anchor remap `(gx0 + a.nx * pw) / aw` and the union
    // subject box. workScale 1.0 makes grid == canvas so coords are exact.
    final img = whitePage(64, 64);
    inkBlob(img, 16, 32, 6); // left panel
    inkBlob(img, 48, 32, 6); // right panel
    final m = const SaliencyAnalyzer(workScale: 1.0).analyze(img, panels: [
      const PixelRect(0, 0, 32, 64),
      const PixelRect(32, 0, 32, 64),
    ]);
    expect(m.panels.length, 2);
    expect(m.width, 64);
    expect(m.height, 64);

    final left = m.anchors.where((a) => a.nx < 0.5).toList();
    final right = m.anchors.where((a) => a.nx > 0.5).toList();
    expect(left, isNotEmpty, reason: 'left panel anchors must survive the remap');
    expect(right, isNotEmpty, reason: 'right panel anchors must survive the remap');
    // Remapped anchors stay inside their own panel's canvas-normalized half
    // (blob centres are at nx 0.25 / 0.75; local un-remapped coords would
    // both cluster near 0.25 and leave the right half empty).
    expect(
        m.anchors.every((a) => (a.nx - 0.25).abs() < 0.1 || (a.nx - 0.75).abs() < 0.1),
        isTrue);
    // Union subject box spans the gutter between the two panels.
    expect(m.subjectBox.x, lessThan(32));
    expect(m.subjectBox.x + m.subjectBox.width, greaterThan(32));
  });

  test('analyze downscales to the workScale grid by default (M4)', () {
    // Default workScale 0.5 — the grid-downscaling path the explicit
    // workScale 1.0 tests above pin away.
    final img = whitePage(40, 40);
    inkBlob(img, 20, 20, 5);
    final m = const SaliencyAnalyzer().analyze(img);
    expect(m.width, 20);
    expect(m.height, 20);
    expect(m.activity.length, 400);
    expect(m.anchors, isNotEmpty);
    // Anchors and activityAt stay canvas-normalized across the downscale.
    expect(
        m.anchors
            .every((a) => a.nx >= 0 && a.nx <= 1 && a.ny >= 0 && a.ny <= 1),
        isTrue);
    // subjectBox is grid coords: the blob box, not the full-grid fallback.
    expect(m.subjectBox.width, lessThan(m.width));
    expect(m.subjectBox.height, lessThan(m.height));
  });

  test('analyze skips degenerate panels instead of crashing', () {
    final img = whitePage(40, 40);
    inkBlob(img, 12, 20, 5);

    // A single out-of-canvas rect takes the `panels.length <= 1` branch, so
    // the whole canvas is analyzed: no crash, anchors still found.
    final one = const SaliencyAnalyzer(workScale: 1.0)
        .analyze(img, panels: [const PixelRect(1000, 1000, 10, 10)]);
    expect(one.panels.length, 1);
    expect(one.anchors, isNotEmpty);

    // Two out-of-canvas rects reach the multi-panel branch, where the
    // `px1 <= px0` clamp guard skips every panel, the merged grid stays empty
    // and the union box falls back to the full grid (`ux1 < 0`).
    final none = const SaliencyAnalyzer(workScale: 1.0).analyze(img, panels: [
      const PixelRect(1000, 1000, 10, 10),
      const PixelRect(1200, 1200, 10, 10),
    ]);
    expect(none.anchors, isEmpty);
    expect(none.subjectBox.x, 0);
    expect(none.subjectBox.y, 0);
    expect(none.subjectBox.width, none.width);
    expect(none.subjectBox.height, none.height);

    // A panel that is inside the canvas but rounds to zero grid cells
    // (`gx1 <= gx0` at workScale 0.5) is skipped without losing the valid one.
    final thin = const SaliencyAnalyzer().analyze(img, panels: [
      const PixelRect(0, 0, 20, 40),
      const PixelRect(39, 0, 1, 40),
    ]);
    expect(thin.panels.length, 2);
    expect(thin.anchors, isNotEmpty);
    expect(thin.anchors.every((a) => a.nx < 0.5), isTrue);
  });

  test('analyze returns an unmodifiable panels list on both branches', () {
    // Consistency: the multi-panel branch already stores `List.unmodifiable`;
    // the single-panel branch must not hand out a growable literal.
    final img = whitePage(40, 40);
    inkBlob(img, 20, 20, 5);
    final single = const SaliencyAnalyzer(workScale: 1.0).analyze(img);
    expect(() => single.panels.add(const PixelRect(0, 0, 1, 1)),
        throwsUnsupportedError);
    final multi = const SaliencyAnalyzer(workScale: 1.0).analyze(img, panels: [
      const PixelRect(0, 0, 20, 40),
      const PixelRect(20, 0, 20, 40),
    ]);
    expect(() => multi.panels.add(const PixelRect(0, 0, 1, 1)),
        throwsUnsupportedError);
  });

  test('analyze single-panel returns full-canvas map', () {
    final img = whitePage(40, 40);
    inkBlob(img, 20, 20, 5);
    // workScale: 1.0 pins the analysis grid to the canvas size so
    // activity.length == 40*40 exactly; with the default 0.5 the grid is
    // downscaled per M4 (workScale bound on O(pixels) cost).
    final m = const SaliencyAnalyzer(workScale: 1.0).analyze(img);
    expect(m.panels.length, 1);
    expect(m.activity.length, 40 * 40);
    expect(m.anchors, isNotEmpty);
  });

  // ---- Task 1.5: AnchorMap threaded through the render pipeline ----
  //
  // Plumb-only contract: NOTHING in the draw path consumes the map yet (that
  // is Task 2.1). So contentAware must be a pure add-on: default false keeps
  // serialization + configHash byte-for-byte unchanged, and rendered output is
  // on == off == baseline. The compositor just accepts + stores the map.
  group('Task 1.5: AnchorMap plumbing', () {
    test('fromRasters stores the passed AnchorMap (field-equal)', () {
      final img = whitePage(64, 64);
      inkBlob(img, 32, 32, 8);
      final map = const SaliencyAnalyzer().analyze(img);
      final c = FrameCompositor.fromRasters(
        base: Uint8List(64 * 64 * 4),
        layers: const [],
        w: 64,
        h: 64,
        config: EffectConfig(),
        anchors: map,
      );
      expect(c.anchors, isNotNull);
      expect(identical(c.anchors, map), isTrue,
          reason: 'compositor carries the exact map handed in');
      expect(c.anchors!.activity.length, map.activity.length);
      expect(c.anchors!.anchors.length, map.anchors.length);
      expect(c.anchors!.subjectBox, map.subjectBox);
      expect(c.anchors!.panels.length, map.panels.length);
    });

    test('compositor built WITHOUT anchors has null anchors (legacy path)',
        () {
      final c = FrameCompositor.fromRasters(
        base: Uint8List(64 * 64 * 4),
        layers: const [],
        w: 64,
        h: 64,
        config: EffectConfig(),
      );
      expect(c.anchors, isNull);
    });

    test('contentAware default false is not serialized; configHash unchanged',
        () {
      expect(EffectConfig().toJson().containsKey('contentAware'), isFalse,
          reason: '默认 false 不写入 → configHash 与旧版一致');
      expect(EffectConfig().configHash, '-477687d5e8bded5f',
          reason: 'classic default hash must NOT move (Task 3.7 gates it)');
      expect(
          EffectConfig.fromJson({'effects': ['rain']})
              .toJson()
              .containsKey('contentAware'),
          isFalse);
      final on = EffectConfig(contentAware: true);
      expect(on.toJson()['contentAware'], true);
      expect(EffectConfig.fromJson(on.toJson()).configHash, on.configHash,
          reason: 'on-config round-trips through the conditional key');
    });

    test('plumb-only: contentAware on==off==baseline, on is deterministic',
        () async {
      final page = whitePage(64, 80);
      inkBlob(page, 32, 40, 10);
      final bytes = Uint8List.fromList(ImageIO.encodePngFrame(page));
      Map<String, dynamic> cfgJson([bool ca = false]) => <String, dynamic>{
            'effects': ['parallax'],
            'fps': 8,
            'durationSec': 1.0,
            'maxDimension': 64,
            'outputFormat': 'gif',
            'seed': 7,
            if (ca) 'contentAware': true,
          };
      final off = EffectConfig.fromJson(cfgJson());
      final on = EffectConfig.fromJson(cfgJson(true));
      final baseline =
          (await MotionPipeline(off).processBytes(input: bytes)).gifBytes!;
      final a = (await MotionPipeline(on).processBytes(input: bytes)).gifBytes!;
      final b = (await MotionPipeline(on).processBytes(input: bytes)).gifBytes!;
      final off2 =
          (await MotionPipeline(off).processBytes(input: bytes)).gifBytes!;
      expect(a, equals(b),
          reason: 'contentAware on 双跑（真实 isolate/worker 路径）逐字节确定');
      expect(off2, equals(baseline),
          reason: 'contentAware off == 未改动基线');
      expect(a, equals(baseline),
          reason: 'plumb-only: on==off==baseline until Task 2.1');
    });
  });
}
