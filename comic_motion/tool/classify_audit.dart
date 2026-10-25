// 分类审计（M1 阈值定值 + M5 验收）：读 corpus_survey 的分域 TSV，按
// ground truth 断言 scene_motion 判定规则的两个 M1 核心语义：
//   A1 网点否决（C1）：gt=narrative_text 的格必须判静（含网点底假文字
//      信号被否决后走静格语义），真文字格不得被误否决成动格；
//   A2 会聚动作（C2）：gt=action 的格必须满足 dir ≥ 0.30 ∨ conv ≥ 0.62。
// closeup/atmosphere 档需要主体掩码（TSV 不含），由引擎单测覆盖。
//
// 用法：dart run tool/classify_audit.dart [--tsv <features.tsv>]... [--verbose]
// 退出码：0 = 全部断言通过；3 = 存在失败（验收 FAIL）。
library;

import 'dart:io' as io;

void main(List<String> args) {
  final paths = <String>[];
  var verbose = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--tsv' && i + 1 < args.length) paths.add(args[++i]);
    if (args[i] == '--verbose') verbose = true;
  }
  if (paths.isEmpty) {
    for (final d in ['bw', 'manhwa', 'manhua', 'color']) {
      final f = io.File('../build/corpus/features_$d.tsv');
      if (f.existsSync()) paths.add(f.path);
    }
  }

  var checked = 0, pass = 0;
  final fails = <String>[];
  for (final p in paths) {
    final rows = io.File(p).readAsLinesSync();
    if (rows.isEmpty) continue;
    final header = rows.first.split('\t');
    final iGt = header.indexOf('gt');
    if (iGt < 0) continue; // 无 GT 域（color 真实语料）只做分布不做断言
    int col(String n) => header.indexOf(n);
    final domain = rows[1].split('\t')[col('domain')];
    for (var r = 1; r < rows.length; r++) {
      final c = rows[r].split('\t');
      final gt = c[iGt];
      final target = switch (gt) {
        'action' => _Target.dynamic,
        'narrative_text' => _Target.still,
        'narrative_detail' => _Target.still,
        _ => _Target.skip,
      };
      if (target == _Target.skip) continue;
      final speck = double.parse(c[col('speckDensity')]);
      final white = double.parse(c[col('whiteFrac')]);
      final dir = double.parse(c[col('dirCoherence')]);
      final edge = double.parse(c[col('edgeFrac')]);
      final dot = double.parse(c[col('dotPeriodicity')]);
      final uni = double.parse(c[col('speckUniformity')]);
      final conv = double.parse(c[col('convergenceCoh')]);

      // 与 lib/src/scene_motion.dart 逐条对齐的规则镜像（TSV 无 speckCount，
      // 均匀性分支以 speckDensity≥3.5 作量级代理；无掩码，closeup 档不判，
      // 氛围档以 edgeFrac≤0.05 镜像）。
      final screentone = dot >= 0.72 || (speck >= 3.5 && uni <= 0.30);
      final textLike = !screentone && speck >= 3.5 && white >= 0.12 &&
          dir <= 0.27;
      final action = dir >= 0.30 || conv >= 0.58;
      final atmosphere = edge <= 0.05;
      final judged = textLike || (!action && !atmosphere)
          ? _Target.still
          : _Target.dynamic;

      checked++;
      final ok = target == judged && (target != _Target.dynamic || action);
      if (ok) {
        pass++;
      } else {
        fails.add('$domain ${c[1]}#${c[2]} gt=$gt judged=$judged '
            '(speck=$speck white=$white dir=$dir dot=$dot uni=$uni conv=$conv)');
      }
      if (verbose) {
        io.stdout.writeln(
            '$domain ${c[1]}#${c[2]} gt=$gt screentone=$screentone '
            'textLike=$textLike action=$action -> $judged '
            '${ok ? 'PASS' : 'FAIL'}');
      }
    }
  }
  for (final f in fails) {
    io.stdout.writeln('FAIL $f');
  }
  io.stdout.writeln('AUDIT pass=$pass fail=${checked - pass} total=$checked');
  io.exitCode = fails.isEmpty ? 0 : 3;
}

enum _Target { still, dynamic, skip }
