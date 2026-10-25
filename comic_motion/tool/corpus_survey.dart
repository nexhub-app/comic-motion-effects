// 多域特征分布勘察（重构方案 M0，`motion_redesign_plan_20261025.md` §6.1）。
//
// 对每个语料域逐页分格提取画面特征（`extractPanelMotionFeatures` 全量，
// 含 M1 的 dotPeriodicity/speckUniformity/convergenceCoh），落盘分域 TSV +
// 分布汇总报告。阈值定值纪律：只看分布自然谷，禁止逐页标注调参。
//
// 用法：
//   dart run tool/corpus_survey.dart --pages <dir> --domain <name> --out <dir>
//   （--pages 省略时对 build/corpus 下三个合成域各跑一遍）
//
// 输出：<out>/features_<domain>.tsv 与 <out>/distribution_report.txt。
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:comic_motion/comic_motion.dart';

const _featureNames = [
  'speckDensity',
  'whiteFrac',
  'dirCoherence',
  'edgeFrac',
  'dotPeriodicity',
  'speckUniformity',
  'convergenceCoh',
];

void main(List<String> args) {
  final outDir = _arg(args, '--out') ?? 'build/corpus';
  io.Directory(outDir).createSync(recursive: true);

  // 单域模式：--pages 指定目录（如 30 页彩页语料）。
  final pagesDir = _arg(args, '--pages');
  final domainName = _arg(args, '--domain') ?? 'color';
  if (pagesDir != null) {
    final maxDim = int.tryParse(_arg(args, '--max-dim') ?? '');
    _surveyDomain(pagesDir, domainName, outDir, gtDir: null, maxDim: maxDim);
    return;
  }
  // 默认：三个合成域（生成器产物）。
  for (final domain in ['bw', 'manhwa', 'manhua']) {
    final dir = '$outDir/$domain';
    if (!io.Directory(dir).existsSync()) {
      io.stderr.writeln('missing $dir — run synthetic_pages.dart first');
      io.exitCode = 2;
      return;
    }
    _surveyDomain(dir, domain, outDir, gtDir: dir);
  }
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

void _surveyDomain(String pagesDir, String domain, String outDir,
    {String? gtDir, int? maxDim}) {
  final files = io.Directory(pagesDir)
      .listSync()
      .whereType<io.File>()
      .where((f) =>
          f.path.toLowerCase().endsWith('.png') ||
          f.path.toLowerCase().endsWith('.jpg'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    io.stderr.writeln('no page images under $pagesDir');
    io.exitCode = 2;
    return;
  }

  final rows = <List<String>>[];
  // 逐格 ground truth（合成域）：按文件名配对 <stem>.gt.json。
  var gtMatched = 0, gtTotal = 0;
  for (final f in files) {
    final bytes = f.readAsBytesSync();
    final src = ImageIO.decode(bytes);
    // 勘察口径两档：
    // - [maxDim] 非空（引擎同款口径，用于真实语料回归）：整页 boxDownscale
    //   到引擎 maxDimension → 分格 → 特征（与渲染主干同序）。
    // - [maxDim] 空（合成域）：分格在原生（≤2048 上限）；特征在逐格 ≤512
    //   （面板级工作尺度——条漫长页若整页降采样会把网点/文字细结构抹掉）。
    final splitBase = maxDim != null ? boxDownscale(src, maxDim) : boxDownscale(src, 2048);
    final sx = src.width / splitBase.width, sy = src.height / splitBase.height;
    final panels = const PanelSplitter().split(splitBase);
    final stem = f.uri.pathSegments.last.split('.').first;
    final gts = _loadGroundTruth(gtDir, stem);
    for (var i = 0; i < panels.length; i++) {
      final rp = panels[i];
      // 换算回源分辨率格矩形。
      final rect = PixelRect(
          (rp.x * sx).round().clamp(0, src.width - 1),
          (rp.y * sy).round().clamp(0, src.height - 1),
          math.max(2, (rp.width * sx).round()),
          math.max(2, (rp.height * sy).round()));
      final rw = math.min(rect.width, src.width - rect.x);
      final rh = math.min(rect.height, src.height - rect.y);
      if (rw < 8 || rh < 8) continue;
      final subFull = RgbaImage(width: rw, height: rh);
      for (var y = 0; y < rh; y++) {
        subFull.data.setRange(y * rw * 4, (y + 1) * rw * 4, src.data,
            ((rect.y + y) * src.width + rect.x) * 4);
      }
      final sub = maxDim != null ? splitBaseCrop(splitBase, rp) : boxDownscale(subFull, 512);
      final feat = extractPanelMotionFeatures(sub);
      String gt = '';
      if (gts != null) {
        gtTotal++;
        gt = _matchGt(gts, rect, 1, 1, 1, 1);
        if (gt.isNotEmpty) gtMatched++;
      }
      rows.add([
        domain,
        stem,
        '$i',
        '${rect.x},${rect.y},$rw,$rh',
        if (gts != null) gt else '-',
        feat.speckDensity.toStringAsFixed(4),
        feat.whiteFrac.toStringAsFixed(4),
        feat.dirCoherence.toStringAsFixed(4),
        feat.edgeFrac.toStringAsFixed(4),
        feat.dotPeriodicity.toStringAsFixed(4),
        feat.speckUniformity.toStringAsFixed(4),
        feat.convergenceCoh.toStringAsFixed(4),
        feat.vpX.toStringAsFixed(4),
        feat.vpY.toStringAsFixed(4),
      ]);
    }
  }

  final tsvPath = '$outDir/features_$domain.tsv';
  final header = [
    'domain',
    'stem',
    'panel',
    'rect',
    if (gtDir != null) 'gt',
    ..._featureNames,
    'vpX',
    'vpY',
  ];
  io.File(tsvPath).writeAsStringSync('${header.join('\t')}\n'
      '${rows.map((r) => r.join('\t')).join('\n')}\n');

  final report = StringBuffer()
    ..writeln('== domain $domain: ${files.length} pages, '
        '${rows.length} panels ==');
  for (var fi = 0; fi < _featureNames.length; fi++) {
    _reportColumn(report, rows, _featureNames[fi], fi);
  }
  if (gtDir != null) {
    report.writeln('gt IoU>=0.5 matched: $gtMatched/$gtTotal');
  }
  io.File('$outDir/distribution_report.txt')
      .writeAsStringSync(report.toString());
  io.stdout.writeln(report.toString());
}

Map<String, dynamic>? _loadGroundTruth(String? gtDir, String stem) {
  if (gtDir == null) return null;
  final f = io.File('$gtDir/$stem.gt.json');
  if (!f.existsSync()) return null;
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

/// 从 splitBase 裁格子图（引擎同款口径：特征直接吃工作分辨率栅格）。
RgbaImage splitBaseCrop(RgbaImage base, PixelRect r) {
  final sub = RgbaImage(width: r.width, height: r.height);
  for (var y = 0; y < r.height; y++) {
    sub.data.setRange(y * r.width * 4, (y + 1) * r.width * 4, base.data,
        ((r.y + y) * base.width + r.x) * 4);
  }
  return sub;
}

/// GT 匹配：GT 矩形与格矩形同在源分辨率坐标，取格中心点包含。
String _matchGt(Map<String, dynamic> gts, PixelRect rect, int srcW, int srcH,
    int workW, int workH) {
  final panels = gts['panels'] as List<dynamic>;
  for (final p in panels) {
    final r = p['rect'] as Map<String, dynamic>;
    final gx = (r['x'] as num).toDouble(), gy = (r['y'] as num).toDouble();
    final gw = (r['w'] as num).toDouble(), gh = (r['h'] as num).toDouble();
    final cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2;
    if (cx >= gx && cx < gx + gw && cy >= gy && cy < gy + gh) {
      return p['gt'] as String;
    }
  }
  return '';
}

void _reportColumn(StringBuffer sb, List<List<String>> rows, String name,
    int col) {
  // 列偏移：domain, stem, panel, rect, [gt] 之后。
  final base = rows.first.length - _featureNames.length - 2;
  final values = rows.map((r) => double.parse(r[base + col])).toList()
    ..sort();
  double q(double p) => values[(p * (values.length - 1)).round()];
  sb.writeln('$name: min=${q(0).toStringAsFixed(4)} '
      'p25=${q(0.25).toStringAsFixed(4)} p50=${q(0.5).toStringAsFixed(4)} '
      'p75=${q(0.75).toStringAsFixed(4)} max=${q(1).toStringAsFixed(4)}');
}
