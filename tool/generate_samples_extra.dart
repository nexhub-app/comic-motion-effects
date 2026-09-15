import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Extra placeholder samples 07-10 (different compositions for batch demo).
void main(List<String> args) {
  final outDir = args.isNotEmpty ? args[0] : 'sample_images';
  Directory(outDir).createSync(recursive: true);
  const W = 900, H = 1300;
  _nightCity(outDir, W, H);
  _forest(outDir, W, H);
  _speechBubble(outDir, W, H);
  _duel(outDir, W, H);
  print('Generated 4 more samples (07-10) in $outDir');
}

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

void _ink(img.Image im, int x0, int y0, int x1, int y1, [int t = 3]) {
  img.drawLine(im,
      x1: x0, y1: y0, x2: x1, y2: y1, color: img.ColorRgb8(20, 18, 24), thickness: t);
}

img.Image _canvas(int w, int h, int r, int g, int b) {
  final im = img.Image(width: w, height: h, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return im;
}

void _nightCity(String dir, int W, int H) {
  final im = _canvas(W, H, 24, 28, 52);
  final rnd = math.Random(33);
  for (var i = 0; i < 60; i++) {
    // stars
    img.fillCircle(im,
        x: rnd.nextInt(W), y: rnd.nextInt(H ~/ 3), radius: 1,
        color: img.ColorRgb8(240, 240, 220));
  }
  for (var x = 0; x < W; x += 110) {
    final bh = 300 + rnd.nextInt(300);
    img.fillRect(im,
        x1: x, y1: H - 300 - bh, x2: x + 95, y2: H - 300,
        color: img.ColorRgb8(58, 62, 92));
    // lit windows
    for (var wy = H - 300 - bh + 20; wy < H - 320; wy += 34) {
      for (var wx = x + 10; wx < x + 85; wx += 24) {
        if (rnd.nextBool()) {
          img.fillRect(im,
              x1: wx, y1: wy, x2: wx + 10, y2: wy + 16,
              color: img.ColorRgb8(250, 224, 140));
        }
      }
    }
  }
  img.fillRect(im, x1: 0, y1: H - 300, x2: W, y2: H,
      color: img.ColorRgb8(34, 36, 48));
  // street lamp glow
  _ellipse(im, W - 140, H - 420, 26, 26, img.ColorRgb8(250, 230, 160));
  img.fillRect(im, x1: W - 146, y1: H - 400, x2: W - 134, y2: H - 300,
      color: img.ColorRgb8(60, 60, 70));
  File('$dir\\07_night_city.png').writeAsBytesSync(img.encodePng(im));
}

void _forest(String dir, int W, int H) {
  final im = _canvas(W, H, 168, 200, 160);
  final rnd = math.Random(45);
  // back trees
  for (var x = 40; x < W; x += 120) {
    img.fillRect(im, x1: x, y1: 300, x2: x + 22, y2: 900,
        color: img.ColorRgb8(96, 116, 88));
    _ellipse(im, x + 11, 260, 70, 110, img.ColorRgb8(88, 128, 84));
  }
  // near trees
  for (final x in [0, 260, 560, 820]) {
    img.fillRect(im, x1: x, y1: 200, x2: x + 34, y2: 1000,
        color: img.ColorRgb8(64, 80, 60));
    _ellipse(im, x + 17, 150, 96, 140, img.ColorRgb8(58, 104, 62));
  }
  // path
  img.fillPolygon(im, vertices: [
    img.Point(W ~/ 2 - 60, 1000), img.Point(W ~/ 2 + 60, 1000),
    img.Point(W ~/ 2 + 260, H), img.Point(W ~/ 2 - 260, H)
  ], color: img.ColorRgb8(196, 178, 140));
  // walker
  final cx = W ~/ 2;
  _ellipse(im, cx, 950, 18, 18, img.ColorRgb8(30, 28, 36));
  img.fillRect(im, x1: cx - 14, y1: 968, x2: cx + 14, y2: 1060,
      color: img.ColorRgb8(30, 28, 36));
  for (var i = 0; i < 10; i++) {
    img.fillCircle(im,
        x: rnd.nextInt(W), y: 200 + rnd.nextInt(300), radius: 2,
        color: img.ColorRgb8(250, 250, 230));
  }
  File('$dir\\08_forest.png').writeAsBytesSync(img.encodePng(im));
}

void _speechBubble(String dir, int W, int H) {
  final im = _canvas(W, H, 246, 242, 234);
  // room bg
  img.fillRect(im, x1: 0, y1: 900, x2: W, y2: H,
      color: img.ColorRgb8(180, 164, 148));
  img.fillRect(im, x1: 60, y1: 160, x2: 380, y2: 620,
      color: img.ColorRgb8(140, 170, 190)); // window
  img.drawRect(im, x1: 60, y1: 160, x2: 380, y2: 620,
      color: img.ColorRgb8(60, 56, 66), thickness: 8);
  // character
  const cx = 620;
  _ellipse(im, cx, 520, 96, 108, img.ColorRgb8(240, 206, 178));
  _ellipse(im, cx, 440, 108, 70, img.ColorRgb8(44, 36, 46));
  _ellipse(im, cx - 36, 528, 14, 12, img.ColorRgb8(24, 22, 30));
  _ellipse(im, cx + 36, 528, 14, 12, img.ColorRgb8(24, 22, 30));
  img.fillRect(im, x1: cx - 120, y1: 640, x2: cx + 120, y2: 1000,
      color: img.ColorRgb8(96, 60, 60));
  // big speech bubble
  _ellipse(im, 380, 220, 250, 130, img.ColorRgb8(255, 255, 255));
  img.fillPolygon(im, vertices: [
    img.Point(480, 330), img.Point(540, 330), img.Point(470, 400)
  ], color: img.ColorRgb8(255, 255, 255));
  for (var i = 0; i < 3; i++) {
    img.fillRect(im,
        x1: 220, y1: 190 + i * 34, x2: 520, y2: 190 + i * 34 + 12,
        color: img.ColorRgb8(60, 60, 70));
  }
  File('$dir\\09_speech_bubble.png').writeAsBytesSync(img.encodePng(im));
}

void _duel(String dir, int W, int H) {
  final im = _canvas(W, H, 232, 226, 214);
  // ground + horizon
  img.fillRect(im, x1: 0, y1: 900, x2: W, y2: H,
      color: img.ColorRgb8(150, 142, 128));
  // left figure
  const lx = 250, rx = 650, cy = 620;
  for (final spec in [
    [lx, 1],
    [rx, -1]
  ]) {
    final int cx = spec[0];
    final int dirSign = spec[1];
    _ellipse(im, cx, cy - 120, 52, 56, img.ColorRgb8(240, 206, 178));
    _ellipse(im, cx, cy - 190, 60, 44, img.ColorRgb8(40, 34, 44));
    img.fillRect(im, x1: cx - 70, y1: cy - 60, x2: cx + 70, y2: cy + 180,
        color: dirSign > 0
            ? img.ColorRgb8(70, 80, 110)
            : img.ColorRgb8(110, 70, 70));
    // arm pointing inward
    img.fillRect(im,
        x1: cx + (dirSign > 0 ? 60 : -160), y1: cy - 40,
        x2: cx + (dirSign > 0 ? 160 : -60), y2: cy - 10,
        color: img.ColorRgb8(240, 206, 178));
  }
  // clash spark center
  _ellipse(im, W ~/ 2, cy - 40, 44, 44, img.ColorRgb8(255, 250, 210));
  _ellipse(im, W ~/ 2, cy - 40, 24, 24, img.ColorRgb8(255, 255, 255));
  final rnd = math.Random(77);
  for (var i = 0; i < 24; i++) {
    final a = rnd.nextDouble() * 2 * math.pi;
    final r0 = 60 + rnd.nextDouble() * 40, r1 = r0 + 40 + rnd.nextDouble() * 80;
    _ink(im,
        (W ~/ 2 + r0 * math.cos(a)).toInt(), (cy - 40 + r0 * math.sin(a)).toInt(),
        (W ~/ 2 + r1 * math.cos(a)).toInt(), (cy - 40 + r1 * math.sin(a)).toInt(),
        2);
  }
  File('$dir\\10_duel.png').writeAsBytesSync(img.encodePng(im));
}
