// 合成多域语料生成器（重构方案 M0，`motion_redesign_plan_20261025.md` §6.1）。
//
// 把 2026-10-25 调研会话的网点/集中线合成实验工具化：确定性（种子化 LCG、
// 无时钟无随机）、零 AI，生成四个域的语料页 + 逐格 ground truth JSON，
// 供分域特征分布勘察（`corpus_survey.dart`）与黑白盲点单测使用。
//
// 盲点覆盖（调研 §8.2 实测坐实的两处分析层失效）：
// - C1 网点误判：`screentoneText` 面板 = 网点点阵 + 文字样斑点——斑点密度
//   特征把网点点数成文字笔画（实测 speckDensity 56.6 vs 阈值 3.5），需要
//   网点否决特征（dotPeriodicity/speckUniformity）区分；
// - C2 放射盲点：`concentrationAction` 面板 = 放射集中线——方向直方图均匀
//   （实测 dirCoh 0.236 < 动作阈值 0.30），需要会聚特征（convergenceCoh）。
//
// 用法：dart run tool/synthetic_pages.dart --out <dir> [--per-domain 30]
// 输出：<out>/<domain>/<stem>.png + <stem>.gt.json（逐格 ground truth）。
// 确定性：同参数两次运行逐字节一致（验收项）。
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:comic_motion/comic_motion.dart';

// 种子常量：写入生成物元数据，换种子 = 新语料版本（分布漂移可追溯）。
const int kSyntheticSeed = 20261025;

/// 确定性伪随机（LCG，无 dart:math.random）。
class Lcg {
  Lcg(this._state);
  int _state;
  int nextInt(int max) {
    _state = (_state * 6364136223846793005 + 1442695040888963407) & 0x7fffffffffffffff;
    return (_state >> 33) % max;
  }

  double nextDouble() => nextInt(1000000) / 1000000.0;
}

/// 格 ground truth 类别（与 PanelClass 四类 + 文字子语义对齐）。
/// narrative 细分 text（真文字格，应判静）与 detail（叙事细节格，
/// E2' 语义下同样判静但语义不同）。
enum GtClass { action, atmosphere, closeup, narrativeText, narrativeDetail }

String gtName(GtClass c) => switch (c) {
      GtClass.action => 'action',
      GtClass.atmosphere => 'atmosphere',
      GtClass.closeup => 'closeup',
      GtClass.narrativeText => 'narrative_text',
      GtClass.narrativeDetail => 'narrative_detail',
    };

// ---------- 面板绘制原语（全部确定性） ----------

void _fill(RgbaImage img, int v, [int g = -1, int b = -1]) =>
    _fillRect(img, 0, 0, img.width, img.height, v, g, b);

void _fillRect(
    RgbaImage img, int x0, int y0, int w, int h, int v, int g, int b) {
  final gr = g < 0 ? v : g;
  final br = b < 0 ? v : b;
  for (var y = y0; y < y0 + h && y < img.height; y++) {
    for (var x = x0; x < x0 + w && x < img.width; x++) {
      img.setPixel(x, y, v, gr, br);
    }
  }
}

/// 文字样斑点：**去格点化**（真实字形不是等距点阵——位置/行长/行距全
/// 抖动，否则自相关把文字也数成网点）。笔画面积跨度大（1..24px）对齐
/// 真实文字的尺寸异质性（网点等尺寸点阵的 std/mean ≈0.1 以下）。
void _drawTextSpecks(RgbaImage img, int x0, int y0, int w, int h, Lcg rng,
    {int dark = 30}) {
  var gy = y0 + 2;
  while (gy < y0 + h - 3) {
    final rowStart = x0 + 2 + rng.nextInt(5);
    final rowPitch = 6 + rng.nextInt(4); // 行距 6..9 抖动
    var gx = rowStart;
    while (gx < x0 + w - 3) {
      final jx = rng.nextInt(3);
      final runLen = 1 + rng.nextInt(6); // 行长 1..6
      final thick = 1 + rng.nextInt(4); // 字高 1..4
      final skip = rng.nextInt(8) == 0; // 偶发空档（词间）
      if (!skip) {
        final kind = rng.nextInt(10);
        if (kind < 3) {
          // 竖笔画（真实字形方向多样：竖笔画成族会收敛于纵向无穷远，
          // 被会聚特征正确读成线族——文字夹具必须控制单向占比）。
          final vh = 2 + rng.nextInt(5);
          for (var dy = 0; dy < vh; dy++) {
            for (var dx = 0; dx < thick.clamp(1, 3); dx++) {
              final px = gx + dx + jx, py = gy + dy;
              if (px < x0 + w - 2 && py < y0 + h - 2) {
                img.setPixel(px, py, dark, dark, dark);
              }
            }
          }
          gx += thick.clamp(1, 3) + 3 + rng.nextInt(3);
          continue;
        } else if (kind < 6) {
          // 斜笔画（45°/135° 交替：方向直方图分散，不形成单 bin 族）。
          final dl = 2 + rng.nextInt(4);
          final up = rng.nextInt(2) == 0;
          for (var s = 0; s < dl; s++) {
            final px = gx + s + jx;
            final py = gy + (up ? dl - s : s);
            if (px < x0 + w - 2 && py < y0 + h - 2 && py >= y0) {
              img.setPixel(px, py, dark, dark, dark);
            }
          }
          gx += dl + 3 + rng.nextInt(3);
          continue;
        }
        for (var dy = 0; dy < thick; dy++) {
          for (var dx = 0; dx < runLen; dx++) {
            final px = gx + dx + jx, py = gy + dy;
            if (px < x0 + w - 2 && py < y0 + h - 2) {
              img.setPixel(px, py, dark, dark, dark);
            }
          }
        }
      }
      gx += runLen + 3 + rng.nextInt(3); // 字距 3..5
    }
    gy += rowPitch;
  }
}

/// 放射集中线：从灭点 (vpx, vpy) 向格内画辐射细线（C2 夹具主体）。
/// Bresenham 4 连通光栅化（真实笔画是连续线段——浮点步进 + 加宽会产生
/// 锯齿横向边缘，稀释会聚特征的边缘质量）。
void _drawConcentrationLines(RgbaImage img, double vpx, double vpy,
    {int count = 48, int dark = 25}) {
  for (var i = 0; i < count; i++) {
    final ang = 2 * math.pi * i / count + 0.13; // 确定性相位
    final r0 = 0.4 * math.max(img.width, img.height);
    final r1 = 1.6 * math.max(img.width, img.height);
    final x0 = vpx + math.cos(ang) * r0;
    final y0 = vpy + math.sin(ang) * r0;
    final x1 = vpx + math.cos(ang) * r1;
    final y1 = vpy + math.sin(ang) * r1;
    _thickLine(img, x0, y0, x1, y1, dark);
  }
}

/// SDF 粗线（逐像素到线段距离 ≤ 半宽）：真实直线的正确光栅化——
/// 边缘严格垂直于笔画轴（DDA 阶梯/Bresenham 对角步进都会在像素级
/// 打散梯度方向或碎化连通性）。
void _thickLine(RgbaImage img, double x0, double y0, double x1, double y1,
    int dark, {double halfWidth = 1.2}) {
  final minX = (math.min(x0, x1) - halfWidth - 1).floor();
  final maxX = (math.max(x0, x1) + halfWidth + 1).ceil();
  final minY = (math.min(y0, y1) - halfWidth - 1).floor();
  final maxY = (math.max(y0, y1) + halfWidth + 1).ceil();
  final vx = x1 - x0, vy = y1 - y0;
  final c2 = vx * vx + vy * vy;
  for (var y = minY; y <= maxY; y++) {
    if (y < 0 || y >= img.height) continue;
    for (var x = minX; x <= maxX; x++) {
      if (x < 0 || x >= img.width) continue;
      final wx = x - x0, wy = y - y0;
      var t = c2 > 0 ? (wx * vx + wy * vy) / c2 : 0.0;
      t = t.clamp(0.0, 1.0);
      final dx = wx - t * vx, dy = wy - t * vy;
      if (dx * dx + dy * dy <= halfWidth * halfWidth) {
        img.setPixel(x, y, dark, dark, dark);
      }
    }
  }
}

/// 平行斜线族（速度线，45°，间隔 [gap]）。
void _drawSpeedLines(RgbaImage img, int gap, {int dark = 20}) {
  for (var s = -img.height; s < img.width + img.height; s += gap) {
    for (var t = 0; t < img.height; t++) {
      final x = s + t;
      if (x < 0 || x >= img.width) continue;
      img.setPixel(x, t, dark, dark, dark);
    }
  }
}

/// 实心剪影（人物/特写主体）：椭圆头部 + 肩部矩形，面积占比可配。
void _drawSilhouette(RgbaImage img, double cx, double cy, double scale,
    {int dark = 35}) {
  final rx = img.width * 0.18 * scale;
  final ry = img.height * 0.22 * scale;
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final dx = (x - cx) / rx, dy = (y - cy - ry * 0.2) / ry;
      final head = dx * dx + dy * dy <= 1;
      final shoulder =
          (y > cy + ry * 0.9) && (x - cx).abs() < rx * 1.7 * scale;
      if (head || shoulder) img.setPixel(x, y, dark, dark, dark);
    }
  }
}

/// 叙事细节：大圆斑阵列（r=10 > 斑点面积上限——scene_motion 测试教训：
/// 细节夹具不能用小暗斑，否则被数成文字；各向同性让 dirCoh 低）。
void _drawDetailCircles(RgbaImage img, {int dark = 90}) {
  for (var cy = 24; cy < img.height - 12; cy += 30) {
    for (var cx = 24; cx < img.width - 12; cx += 30) {
      for (var y = -10; y <= 10; y++) {
        for (var x = -10; x <= 10; x++) {
          if (x * x + y * y <= 100) {
            final px = cx + x, py = cy + y;
            if (px >= 0 && px < img.width && py >= 0 && py < img.height) {
              img.setPixel(px, py, dark, dark, dark);
            }
          }
        }
      }
    }
  }
}

/// 彩色网点（manhua 域）：周期彩点。
void _drawColorScreentone(RgbaImage img, Lcg rng) {
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final on = (x % 6) < 2 && (y % 6) < 2;
      if (on) {
        img.setPixel(x, y, 70, 90, 160);
      } else {
        img.setPixel(x, y, 240, 238, 232);
      }
    }
  }
  rng.nextInt(1);
}

// ---------- 面板变体（返回 ground truth 类别） ----------

typedef _Panel = (RgbaImage, GtClass);

/// C1 盲点（对齐调研实测形态）：白底 + 网点补丁 + 文字块——斑点密度
/// 把网点点数成文字笔画（实测 speckDensity 56.6 vs 阈值 3.5），网点
/// 否决特征必须在此拦截。
_Panel panelScreentoneText(int w, int h, Lcg rng) {
  final img = RgbaImage(width: w, height: h);
  _fill(img, 255);
  // 上半幅网点补丁（真实 C1：网点是贴在白底上的局部灰域）。
  _drawScreentoneRect(img, rng, 0, 0, w, h ~/ 2);
  _drawTextSpecks(img, w ~/ 8, h * 5 ~/ 8, w * 3 ~/ 4, h * 3 ~/ 8, rng);
  return (img, GtClass.narrativeText);
}

/// 白底上的网点补丁（区域限定）。
void _drawScreentoneRect(
    RgbaImage img, Lcg rng, int x0, int y0, int pw, int ph) {
  const period = 7, dot = 3;
  for (var y = y0; y < y0 + ph && y < img.height; y++) {
    for (var x = x0; x < x0 + pw && x < img.width; x++) {
      final gx = x % period, gy = y % period;
      final v = gx < dot && gy < dot ? 40 : 255;
      img.setPixel(x, y, v, v, v);
    }
  }
  rng.nextInt(1);
}

/// C2 盲点：放射集中线 + 中心剪影——dirCoh 低但语义是动作格。
_Panel panelConcentrationAction(int w, int h, Lcg rng) {
  final img = RgbaImage(width: w, height: h);
  _fill(img, 245);
  _drawSilhouette(img, w * 0.5, h * 0.42, 0.9);
  _drawConcentrationLines(img, w * 0.5, h * 0.42);
  return (img, GtClass.action);
}

/// 平行速度线（既有 dirCoh 特征的正样本，回归锚）。
_Panel panelSpeedLines(int w, int h, Lcg rng) {
  final img = RgbaImage(width: w, height: h);
  _fill(img, 205);
  _drawSpeedLines(img, 6);
  return (img, GtClass.action);
}

/// 氛围：平滑渐变天空。
_Panel panelAtmosphere(int w, int h, Lcg rng, {bool color = false}) {
  final img = RgbaImage(width: w, height: h);
  if (color) {
    for (var y = 0; y < h; y++) {
      final t = y / math.max(1, h - 1);
      final r = (180 + 40 * t).round();
      final g = (205 + 25 * t).round();
      final b = (235 - 20 * t).round();
      for (var x = 0; x < w; x++) {
        img.setPixel(x, y, r, g, b);
      }
    }
  } else {
    for (var y = 0; y < h; y++) {
      final t = y / math.max(1, h - 1);
      final v = (215 + 30 * t).round();
      for (var x = 0; x < w; x++) {
        img.setPixel(x, y, v, v, v);
      }
    }
  }
  rng.nextInt(1);
  return (img, GtClass.atmosphere);
}

/// 特写：大面积剪影占格 ≥ 30%。
_Panel panelCloseup(int w, int h, Lcg rng, {bool color = false}) {
  final img = RgbaImage(width: w, height: h);
  if (color) {
    _fill(img, 235, 215, 205);
  } else {
    _fill(img, 240);
  }
  _drawSilhouette(img, w * 0.5, h * 0.35, 1.9,
      dark: color ? 60 : 35);
  return (img, GtClass.closeup);
}

/// 叙事细节：大圆斑阵列。
_Panel panelNarrativeDetail(int w, int h, Lcg rng) {
  final img = RgbaImage(width: w, height: h);
  _fill(img, 245);
  _drawDetailCircles(img);
  return (img, GtClass.narrativeDetail);
}

/// 真文字格：白底 + 斑点（网点否决必须不误伤本格）。
_Panel panelDialogText(int w, int h, Lcg rng) {
  final img = RgbaImage(width: w, height: h);
  _fill(img, 255);
  _drawTextSpecks(img, 4, 4, w - 8, h - 8, rng);
  return (img, GtClass.narrativeText);
}

/// manhua 彩色网点 + 剪影。
_Panel panelColorScreentone(int w, int h, Lcg rng) {
  final img = RgbaImage(width: w, height: h);
  _drawColorScreentone(img, rng);
  _drawSilhouette(img, w * 0.5, h * 0.4, 1.1, dark: 30);
  return (img, GtClass.closeup);
}

// ---------- 页面装配 ----------

/// 在 [page] 的格矩形 [rect] 内绘制变体 [v]（子图坐标平移）。
GtClass _stamp(RgbaImage page, PixelRect rect, _Panel Function(int, int, Lcg) v,
    Lcg rng) {
  final (panel, gt) = v(rect.width, rect.height, rng);
  for (var y = 0; y < rect.height; y++) {
    for (var x = 0; x < rect.width; x++) {
      final o = (y * rect.width + x) * 4;
      page.setPixel(rect.x + x, rect.y + y, panel.data[o], panel.data[o + 1],
          panel.data[o + 2]);
    }
  }
  return gt;
}

/// 生成一页：2×N 网格或条带布局，逐格变体由确定性 LCG 挑选；
/// 每页保证至少一个 C1（screentoneText）与一个 C2（concentrationAction）
/// 盲点面板（方案 §6.1「黑白盲点进单测」的页面级覆盖）。
(RgbaImage, List<(PixelRect, GtClass)>) _makePage(
    String domain, int w, int h, List<int> cols, List<int> rows, int gutter,
    List<_Panel Function(int, int, Lcg)> variants, int seed, Lcg rng,
    {required bool ensureBlindspots}) {
  final page = RgbaImage(width: w, height: h);
  _fill(page, 255);
  final rects = <PixelRect>[];
  var y = 0;
  for (var ri = 0; ri < rows.length; ri++) {
    final rh = rows[ri];
    var x = 0;
    for (var ci = 0; ci < cols.length; ci++) {
      final cw = cols[ci];
      rects.add(PixelRect(x + gutter, y + gutter, cw - 2 * gutter,
          rh - 2 * gutter));
      x += cw;
    }
    y += rh;
  }
  // 每页固定注入两个盲点面板（第 0 格 = C1、第 1 格 = C2，页面布局确定）。
  final gts = <(PixelRect, GtClass)>[];
  for (var i = 0; i < rects.length; i++) {
    final r = rects[i];
    if (r.width < 40 || r.height < 40) {
      gts.add((r, GtClass.narrativeDetail));
      continue;
    }
    _Panel Function(int, int, Lcg) v;
    if (ensureBlindspots && i == 0) {
      v = panelScreentoneText;
    } else if (ensureBlindspots && i == 1) {
      v = panelConcentrationAction;
    } else {
      v = variants[rng.nextInt(variants.length)];
    }
    gts.add((r, _stamp(page, r, v, rng)));
  }
  return (page, gts);
}

/// 走一遍四域装配（供调用方与测试复用同一段布局逻辑）。
List<(String, RgbaImage, List<(PixelRect, GtClass)>)> generateDomain(
    String domain, int count, int seed) {
  final out = <(String, RgbaImage, List<(PixelRect, GtClass)>)>[];
  for (var i = 0; i < count; i++) {
    final rng = Lcg(seed + i * 7919);
    final (page, gts) = switch (domain) {
      'bw' => _makePage(
          domain,
          600,
          400,
          [300, 300],
          [200, 200],
          12,
          [
            panelSpeedLines,
            panelAtmosphere,
            panelCloseup,
            panelNarrativeDetail,
            panelDialogText,
          ],
          seed + i * 7919,
          rng,
          ensureBlindspots: true),
      'manhwa' => _makePage(
          domain,
          800,
          2400,
          [800],
          [800, 800, 800],
          16,
          [
            panelSpeedLines,
            panelAtmosphere,
            panelCloseup,
            panelNarrativeDetail,
            panelDialogText,
            panelScreentoneText,
          ],
          seed + i * 7919,
          rng,
          ensureBlindspots: true),
      'manhua' => _makePage(
          domain,
          720,
          960,
          [360, 360],
          [480, 480],
          10,
          [
            panelAtmosphere,
            panelCloseup,
            panelColorScreentone,
            panelDialogText,
            panelNarrativeDetail,
          ],
          seed + i * 7919,
          rng,
          ensureBlindspots: true),
      _ => throw ArgumentError('unknown domain: $domain'),
    };
    out.add(('${domain}_p${i.toString().padLeft(3, '0')}', page, gts));
  }
  return out;
}

void main(List<String> args) {
  String outDir = 'build/corpus';
  var perDomain = 30;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--out') outDir = args[i + 1];
    if (args[i] == '--per-domain') perDomain = int.parse(args[i + 1]);
  }
  final domains = ['bw', 'manhwa', 'manhua'];
  var files = 0;
  for (final domain in domains) {
    final dir = '$outDir/$domain';
    io.Directory(dir).createSync(recursive: true);
    for (final (stem, page, gts) in generateDomain(domain, perDomain, kSyntheticSeed)) {
      io.File('$dir/$stem.png')
          .writeAsBytesSync(ImageIO.encodePngFrame(page));
      final gt = {
        'stem': stem,
        'domain': domain,
        'seed': kSyntheticSeed,
        'width': page.width,
        'height': page.height,
        'panels': [
          for (final (rect, gt) in gts)
            {
              'rect': {
                'x': rect.x,
                'y': rect.y,
                'w': rect.width,
                'h': rect.height,
              },
              'gt': gtName(gt),
            }
        ],
      };
      io.File('$dir/$stem.gt.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(gt));
      files += 2;
    }
  }
  io.stdout.writeln('synthetic corpus: $files files under $outDir '
      '(domains=$domains, perDomain=$perDomain, seed=$kSyntheticSeed)');
}
