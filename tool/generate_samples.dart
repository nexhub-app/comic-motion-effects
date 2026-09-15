import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Generates synthetic comic-style placeholder images with enough structure
/// (ink lines, skin tones, flat backgrounds, speed lines) for the depth
/// splitter to produce meaningful layers. Pure placeholder art for pipeline
/// validation; real copyrighted samples are supplied by the user.
void main(List<String> args) {
  final outDir = args.isNotEmpty ? args[0] : 'sample_images';
  Directory(outDir).createSync(recursive: true);
  final W = 900, H = 1300;

  _portrait(outDir, W, H); // 01 character half-body + sky
  _action(outDir, W, H); // 02 focus lines + silhouette
  _twoPanel(outDir, W, H); // 03 two panels
  _landscape(outDir, W, H); // 04 mountains + tiny figure
  _closeup(outDir, W, H); // 05 face closeup + effect lines
  _crowd(outDir, W, H); // 06 crowd rows
  print('Generated 6 placeholder samples in $outDir');
}

img.Image _canvas(int w, int h, int r, int g, int b) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return im;
}

void _ink(img.Image im, int x0, int y0, int x1, int y1, [int thickness = 3]) {
  img.drawLine(im,
      x1: x0,
      y1: y0,
      x2: x1,
      y2: y1,
      color: img.ColorRgb8(20, 18, 24),
      thickness: thickness);
}

/// Filled axis-aligned ellipse via per-row rect spans.
void _ellipse(img.Image im, int cx, int cy, int rx, int ry, img.ColorRgb8 c) {
  if (rx <= 0 || ry <= 0) return;
  for (var dy = -ry; dy <= ry; dy++) {
    final t = dy / ry;
    final half = (rx * math.sqrt(math.max(0.0, 1 - t * t))).round();
    if (half <= 0) continue;
    img.fillRect(im,
        x1: cx - half, y1: cy + dy, x2: cx + half, y2: cy + dy, color: c);
  }
}

void _portrait(String dir, int W, int H) {
  final im = _canvas(W, H, 176, 216, 232); // sky
  for (final c in [
    [150, 180, 60],
    [700, 260, 44],
    [420, 120, 36]
  ]) {
    _ellipse(im, c[0], c[1], c[2], c[2] ~/ 2, img.ColorRgb8(245, 248, 252));
  }
  // distant buildings (flat bg)
  final rnd = math.Random(7);
  for (var x = 0; x < W; x += 90) {
    final bh = 220 + rnd.nextInt(160);
    img.fillRect(im,
        x1: x,
        y1: H - 420 - bh,
        x2: x + 80,
        y2: H - 420,
        color: img.ColorRgb8(150, 160, 178));
    _ink(im, x, H - 420 - bh, x, H - 420, 2);
  }
  // ground
  img.fillRect(im,
      x1: 0, y1: H - 420, x2: W, y2: H, color: img.ColorRgb8(208, 196, 176));
  // character
  final cx = W ~/ 2;
  img.fillRect(im,
      x1: cx - 150,
      y1: H - 430,
      x2: cx + 150,
      y2: H,
      color: img.ColorRgb8(46, 52, 88)); // jacket
  img.fillRect(im,
      x1: cx - 40,
      y1: H - 500,
      x2: cx + 40,
      y2: H - 420,
      color: img.ColorRgb8(238, 204, 176)); // neck/chest
  _ellipse(im, cx, H - 640, 110, 120, img.ColorRgb8(238, 204, 176)); // face
  _ellipse(im, cx, H - 720, 124, 80, img.ColorRgb8(38, 32, 40)); // hair
  _ellipse(im, cx - 92, H - 705, 32, 65, img.ColorRgb8(38, 32, 40));
  _ellipse(im, cx + 92, H - 705, 32, 65, img.ColorRgb8(38, 32, 40));
  _ellipse(im, cx - 42, H - 645, 18, 15, img.ColorRgb8(24, 22, 30)); // eyes
  _ellipse(im, cx + 42, H - 645, 18, 15, img.ColorRgb8(24, 22, 30));
  _ink(im, cx - 30, H - 570, cx + 30, H - 570, 4);
  _ink(im, cx - 110, H - 520, cx - 90, H - 470, 3);
  _ink(im, cx + 110, H - 520, cx + 90, H - 470, 3);
  File('$dir\\01_portrait.png').writeAsBytesSync(img.encodePng(im));
}

void _action(String dir, int W, int H) {
  final im = _canvas(W, H, 244, 240, 232);
  final cx = W ~/ 2, cy = H ~/ 2;
  final rnd = math.Random(3);
  for (var i = 0; i < 64; i++) {
    final a = rnd.nextDouble() * 2 * math.pi;
    final r0 = 240.0 + rnd.nextDouble() * 60;
    const r1 = 900.0;
    _ink(im, (cx + r0 * math.cos(a)).toInt(), (cy + r0 * math.sin(a)).toInt(),
        (cx + r1 * math.cos(a)).toInt(), (cy + r1 * math.sin(a)).toInt(),
        2 + rnd.nextInt(4));
  }
  final ink = img.ColorRgb8(28, 26, 34);
  _ellipse(im, cx, cy - 160, 46, 50, ink); // head
  _ellipse(im, cx + 5, cy - 30, 75, 90, ink); // torso
  img.fillRect(im, x1: cx - 60, y1: cy + 40, x2: cx - 10, y2: cy + 240, color: ink);
  img.fillRect(im, x1: cx + 10, y1: cy + 40, x2: cx + 90, y2: cy + 220, color: ink);
  img.fillRect(im, x1: cx - 130, y1: cy - 90, x2: cx - 40, y2: cy - 30, color: ink);
  img.fillRect(im, x1: cx + 40, y1: cy - 100, x2: cx + 150, y2: cy - 20, color: ink);
  File('$dir\\02_action.png').writeAsBytesSync(img.encodePng(im));
}

void _twoPanel(String dir, int W, int H) {
  final im = _canvas(W, H, 250, 250, 246);
  img.drawRect(im,
      x1: 40,
      y1: 40,
      x2: W - 40,
      y2: H ~/ 2 - 30,
      color: img.ColorRgb8(30, 28, 34),
      thickness: 6);
  final fx = W ~/ 2, fy = 320;
  _ellipse(im, fx, fy, 140, 150, img.ColorRgb8(240, 208, 180));
  _ellipse(im, fx - 40, fy - 22, 20, 18, img.ColorRgb8(22, 20, 28));
  _ellipse(im, fx + 40, fy - 22, 20, 18, img.ColorRgb8(22, 20, 28));
  _ink(im, fx - 40, fy + 70, fx + 40, fy + 70, 5);
  img.drawRect(im,
      x1: 40,
      y1: H ~/ 2 + 10,
      x2: W - 40,
      y2: H - 40,
      color: img.ColorRgb8(30, 28, 34),
      thickness: 6);
  _ellipse(im, W - 210, H ~/ 2 + 110, 50, 50, img.ColorRgb8(250, 224, 150));
  img.fillRect(im,
      x1: 50,
      y1: H - 260,
      x2: W - 50,
      y2: H - 50,
      color: img.ColorRgb8(120, 150, 120));
  for (var x = 60; x < W - 100; x += 130) {
    img.fillRect(im,
        x1: x,
        y1: H - 420,
        x2: x + 90,
        y2: H - 260,
        color: img.ColorRgb8(96, 120, 104));
  }
  File('$dir\\03_two_panel.png').writeAsBytesSync(img.encodePng(im));
}

void _landscape(String dir, int W, int H) {
  final im = _canvas(W, H, 200, 224, 238);
  _ellipse(im, W - 190, 160, 50, 50, img.ColorRgb8(252, 236, 170));
  img.fillPolygon(im, vertices: [
    img.Point(0, 700),
    img.Point(220, 380),
    img.Point(430, 700)
  ], color: img.ColorRgb8(150, 170, 190));
  img.fillPolygon(im, vertices: [
    img.Point(300, 700),
    img.Point(600, 300),
    img.Point(900, 700)
  ], color: img.ColorRgb8(120, 146, 172));
  img.fillRect(im,
      x1: 0, y1: 700, x2: W, y2: H, color: img.ColorRgb8(170, 190, 150));
  final ink = img.ColorRgb8(30, 28, 36);
  _ellipse(im, 450, 780, 20, 20, ink);
  img.fillRect(im, x1: 438, y1: 800, x2: 462, y2: 880, color: ink);
  _ink(im, 430, 700, 470, 700, 2);
  File('$dir\\04_landscape.png').writeAsBytesSync(img.encodePng(im));
}

void _closeup(String dir, int W, int H) {
  final im = _canvas(W, H, 250, 244, 238);
  final rnd = math.Random(11);
  for (var i = 0; i < 30; i++) {
    final x = rnd.nextInt(W), y = rnd.nextInt(H ~/ 2);
    _ink(im, x, y, x + 60 + rnd.nextInt(90), y + 12 + rnd.nextInt(30), 2);
  }
  final cx = W ~/ 2, cy = 620;
  _ellipse(im, cx, cy, 260, 310, img.ColorRgb8(242, 210, 182));
  _ellipse(im, cx - 205, cy - 260, 85, 100, img.ColorRgb8(40, 34, 44));
  _ellipse(im, cx + 205, cy - 260, 85, 100, img.ColorRgb8(40, 34, 44));
  final ink = img.ColorRgb8(18, 16, 26);
  _ellipse(im, cx - 100, cy - 25, 50, 35, ink);
  _ellipse(im, cx + 100, cy - 25, 50, 35, ink);
  _ink(im, cx - 170, cy - 90, cx - 40, cy - 110, 8);
  _ink(im, cx + 40, cy - 110, cx + 170, cy - 90, 8);
  _ink(im, cx - 50, cy + 190, cx + 50, cy + 190, 6);
  File('$dir\\05_closeup.png').writeAsBytesSync(img.encodePng(im));
}

void _crowd(String dir, int W, int H) {
  final im = _canvas(W, H, 214, 200, 188);
  img.fillRect(im, x1: 0, y1: 0, x2: 140, y2: H, color: img.ColorRgb8(150, 138, 128));
  img.fillRect(im, x1: W - 140, y1: 0, x2: W, y2: H, color: img.ColorRgb8(150, 138, 128));
  final rnd = math.Random(21);
  for (var row = 0; row < 4; row++) {
    final y = 480 + row * 200;
    for (var x = 120; x < W - 140; x += 150) {
      final jitter = rnd.nextInt(40);
      final s = 1.0 + row * 0.25;
      _ellipse(
          im,
          x + jitter + (35 * s).toInt(),
          y - (45 * s).toInt(),
          (35 * s).toInt(),
          (45 * s).toInt(),
          img.ColorRgb8(240 - row * 8, 206 - row * 8, 178 - row * 6));
      img.fillRect(im,
          x1: x + jitter,
          y1: y,
          x2: (x + jitter + 70 * s).toInt(),
          y2: (y + 130 * s).toInt(),
          color: img.ColorRgb8(52 + row * 10, 58 + row * 8, 84 + row * 6));
      _ink(im, x + jitter + 35, y - 90, x + jitter + 35, y - 60, 3);
    }
  }
  File('$dir\\06_crowd.png').writeAsBytesSync(img.encodePng(im));
}

