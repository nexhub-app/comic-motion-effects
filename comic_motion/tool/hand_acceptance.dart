import 'dart:io';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';

/// v1.4 Plan B Task 7：部位动作**语料验收矩阵**。
///
/// 用法：`dart run tool/hand_acceptance.dart <corpusDir> [outDir] [--amp=8]`
///
/// corpusDir 里每张图配一份**同名侧车**（就是三期 AI 的产物形状）：
/// `page.jpeg` + `page.part_motion.json`。没有侧车的图直接跳过 —— 侧车是部件
/// 的唯一入口，缺文件 ⇒ 一个像素都不该动，这条通道不存在「猜一个手出来」。
///
/// 每图打印 5 列，全部来自 spec §7.4 / P4 验收条款：
/// - `rest`     t=0 有侧车 == 无侧车（首帧就是作者画的那只手，不是预旋姿态）
/// - `move`     峰值角度的改动像素数 / 平均差 / 最大差（非空洞性）
/// - `contain`  contained 不露洞：改动像素全落在覆盖率 >0 的足迹内、alpha 通道
///              未被写过、每个改动像素的 RGB 都在源图该区域的取值范围内
///              （凸组合 ⇒ 不会凭空造出源图没有的颜色 = 不露白）/// - `determ`   GIF 跑两次逐字节相同 + parallel=4 与 =1 逐字节相同
/// - `seamless` t=0 与 t=durationSec 逐字节相同（整分频周期回到原位）
///
/// 末尾附一段形变开销实测（`buildPlan` 一次性 + 每帧 `apply` 按部件数），
/// 用来判断「加几只手会把帧时抬高多少」，红线本身归 tool/bench.dart。
Future<void> main(List<String> args) async {
  final positional = [for (final a in args) if (!a.startsWith('--')) a];
  if (positional.isEmpty) {
    stderr.writeln('用法: dart run tool/hand_acceptance.dart <corpusDir> '
        '[outDir] [--amp=8]');
    stderr.writeln('corpusDir 里每张图配一份同名侧车：page.jpeg + '
        'page.part_motion.json（侧车是部件的唯一入口）。');
    exit(64);
  }
  final corpusDir = positional[0];
  final outDir = positional.length > 1 ? positional[1] : 'build/hand_acceptance';
  final ampDeg = double.tryParse(_flag(args, '--amp') ?? '') ?? 8.0;

  final sidecars = Directory(corpusDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.part_motion.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (sidecars.isEmpty) {
    stderr.writeln('语料目录里没有 *.part_motion.json：$corpusDir');
    stderr.writeln('侧车是部位动作的唯一入口，无侧车 = 无可验收的部件。');
    exit(4);
  }
  Directory(outDir).createSync(recursive: true);

  final rows = <_Row>[];
  RgbaImage? perfSample;
  PartMotion? perfPart;
  for (final sc in sidecars) {
    final stem = sc.path.substring(0, sc.path.length - '.part_motion.json'.length);
    final image = _siblingImage(stem);
    if (image == null) {
      stderr.writeln('跳过 ${_base(sc.path)}：找不到同名图片 $stem.(png|jpg|jpeg)');
      continue;
    }
    final text = sc.readAsStringSync();
    rows.add(await _runMatrix(image, text, '$outDir/${_base(stem)}', ampDeg: ampDeg));
    if (perfSample == null) {
      final parts = _implementedParts(text);
      if (parts.isNotEmpty) {
        perfSample = ImageIO.decodeFile(image);
        perfPart = parts.first;
      }
    }
  }

  _printTable(rows);
  if (perfSample != null && perfPart != null) {
    _measureWarpCost(perfSample, perfPart, ampDeg);
  }

  final failed = rows.where((r) => !r.ok).length;
  stdout.writeln('\n验收：${rows.length - failed}/${rows.length} 通过'
      '（ampDeg=$ampDeg，语料 ${sidecars.length} 份侧车，产物 $outDir）');
  if (failed > 0) exit(2);
}

List<PartMotion> _implementedParts(String sidecarText) => [
      for (final p in PartMotionParser.parse(sidecarText).spec?.parts ??
          const <PartMotion>[])
        if (p.kind.isImplemented) p
    ];

WarpPlan _planFor(MeshWarper warper, RgbaImage target, PartMotion p) =>
    warper.buildPlan(target,
        PartShape(
            polygon: p.polygon,
            rootX: p.anchorX,
            rootY: p.anchorY,
            tipX: p.tipPoint.x,
            tipY: p.tipPoint.y));


/// 单图矩阵。任何一项不达标只记进本行 problems，不抛 —— 一次跑完看全貌。
Future<_Row> _runMatrix(String image, String sidecarText, String outForImage,
    {required double ampDeg}) async {
  final row = _Row(_base(image));
  Directory(outForImage).createSync(recursive: true);

  final parsed = PartMotionParser.parse(sidecarText);
  row.warnings = parsed.warnings.length;
  for (final w in parsed.warnings) {
    row.problems.add('侧车告警（手写侧车应为 0）：$w');
  }
  final kept = _implementedParts(sidecarText);
  if (kept.isEmpty) {
    row.problems.add('侧车里没有已实现的 kind（当前只有 hand），无可验收部件');
    return row;
  }

  const durationSec = 2.0;
  final cfg = EffectConfig(
    fps: 12,
    durationSec: durationSec,
    maxDimension: 1280,
    outputFormat: OutputFormat.gif,
    quality: const QualityParams(tier: RenderTier.standard),
    handMotion: HandMotionParams(ampDeg: ampDeg, periodSec: durationSec),
    effects: const [EffectKind.handMotion],
  );
  final withParts = MotionPipeline(cfg, partMotion: sidecarText);
  final withoutParts = MotionPipeline(cfg);
  // 0 号部件 phase=0 ⇒ wave 在 period/4 处取到 +1，即摆角峰值。
  final peakSec = durationSec / 4;

  final restWith = await withParts.renderStillFrameFile(image, t: 0);
  final restWithout = await withoutParts.renderStillFrameFile(image, t: 0);
  row.rest = _sameBytes(restWith, restWithout);
  if (row.rest != 'ok') {
    row.problems.add('t=0 有侧车 != 无侧车：首帧被预旋，不是原画姿态');
  }

  final peakWith = await withParts.renderStillFrameFile(image, t: peakSec);
  final peakWithout = await withoutParts.renderStillFrameFile(image, t: peakSec);
  final warped = ImageIO.decode(peakWith);
  final base = ImageIO.decode(peakWithout);
  final d = _diffStats(base, warped);
  row.move = '${d.changed} px / Δ̄ ${d.meanAsString} / max ${d.max}';
  if (d.changed == 0) row.problems.add('峰值角度零改动像素：形变通道没接上');

  // 覆盖率足迹用公开 API 复算一遍（与合成器建表同一条路径）。
  const warper = MeshWarper();
  final plans = [
    for (final p in kept) _planFor(warper, warped, p)
  ].where((pl) => !pl.isEmpty).toList();
  if (plans.length != kept.length) {
    row.problems.add('退化多边形：${kept.length - plans.length} 个部件建不出形变表');
  }
  _checkContainment(row, base, warped, plans);

  final seamless = await withParts.renderStillFrameFile(image, t: durationSec);
  row.seamless = _sameBytes(restWith, seamless);
  if (row.seamless != 'ok') {
    row.problems.add('t=duration != t=0：循环接缝处画面跳回原位失败');
  }

  final gifs = <String, Uint8List>{};
  for (final e in <String, int?>{
    'run-a': null,
    'run-b': null,
    'serial': 1,
    'parallel4': 4,
  }.entries) {
    final r = await MotionPipeline(cfg, partMotion: sidecarText, parallel: e.value)
        .processFile(image, '$outForImage/gif_${e.key}');
    gifs[e.key] = File(r.outputGif).readAsBytesSync();
  }
  final serial = gifs['serial']!;
  final allSame = _bytesEqual(serial, gifs['run-a']!) &&
      _bytesEqual(serial, gifs['run-b']!) &&
      _bytesEqual(serial, gifs['parallel4']!);
  row.determ = allSame ? 'ok' : 'FAIL';
  if (!allSame) row.problems.add('GIF 不逐字节相同（两次 / 并行 vs 串行）');

  File('$outForImage/rest.png').writeAsBytes(restWith);
  File('$outForImage/peak_no_parts.png').writeAsBytes(peakWithout);
  File('$outForImage/peak_parts.png').writeAsBytes(peakWith);
  File('$outForImage/diff_x8.png')
      .writeAsBytes(ImageIO.encodePngFrame(_amplifiedDiff(base, warped)));
  return row;
}

/// contained 不露洞的三条可判定形式。
void _checkContainment(_Row row, RgbaImage base, RgbaImage warped, List<WarpPlan> plans) {
  if (plans.isEmpty) {
    row.contain = 'n/a（无有效形变表）';
    return;
  }
  var outside = 0, alphaTouched = 0, synthetic = 0;
  // 源图在各 plan bbox（含羽化余量）里的逐通道取值范围：凸组合的结果不可能越出它。
  var loR = 255, loG = 255, loB = 255, hiR = 0, hiG = 0, hiB = 0;
  for (final pl in plans) {
    final x1 = pl.originX + pl.width, y1 = pl.originY + pl.height;
    for (var y = pl.originY; y < y1; y++) {
      for (var x = pl.originX; x < x1; x++) {
        final i = y * base.width + x, o = i * 4;
        if (base.data[o] < loR) loR = base.data[o];
        if (base.data[o] > hiR) hiR = base.data[o];
        if (base.data[o + 1] < loG) loG = base.data[o + 1];
        if (base.data[o + 1] > hiG) hiG = base.data[o + 1];
        if (base.data[o + 2] < loB) loB = base.data[o + 2];
        if (base.data[o + 2] > hiB) hiB = base.data[o + 2];
      }
    }
  }
  for (var i = 0; i < base.pixelCount; i++) {
    final o = i * 4;
    if (base.data[o + 3] != warped.data[o + 3]) alphaTouched++;
    if (base.data[o] == warped.data[o] &&
        base.data[o + 1] == warped.data[o + 1] &&
        base.data[o + 2] == warped.data[o + 2]) continue;
    final x = i % base.width, y = i ~/ base.width;
    if (!plans.any((pl) => pl.alphaAt(x, y) > 0)) outside++;
    for (var ch = 0; ch < 3; ch++) {
      final (lo, hi) = switch (ch) {
        0 => (loR, hiR),
        1 => (loG, hiG),
        _ => (loB, hiB),
      };
      if (warped.data[o + ch] < lo - 1 || warped.data[o + ch] > hi + 1) {
        synthetic++;
        break;
      }
    }
  }
  row.contain = '足迹外 $outside / alpha $alphaTouched / 造色 $synthetic';
  if (outside > 0) row.problems.add('$outside 个改动像素落在覆盖率足迹之外（形变外溢）');
  if (alphaTouched > 0) row.problems.add('$alphaTouched 个像素的 alpha 被改写（露洞的前置条件）');
  if (synthetic > 0) row.problems.add('$synthetic 个像素出现源图区域外的取值（露白/补色）');
}

/// 形变开销实测：建表（每次渲染一次）+ 逐帧 apply（按部件数线性）。
///
/// 部件数扩到 1/2/4/8 靠**复制同一个 plan**，这是成本模型而不是真实语料：一页
/// 里不会有 8 只手，但每个部件的开销就是一个独立 bbox 扫描，线性可外推。整帧快照
/// 每帧只一次、所有部件共用（见 frame_compositor 的注释），所以单独列出来加。
void _measureWarpCost(RgbaImage src, PartMotion part, double ampDeg) {
  const warper = MeshWarper();
  final plan = _planFor(warper, src, part);
  var buildUs = 0;
  for (var i = 0; i < 5; i++) {
    final sw = Stopwatch()..start();
    final again = _planFor(warper, src, part);
    sw.stop();
    if (i > 0) buildUs = sw.elapsedMicroseconds; // 丢首次 JIT 冷启动
    if (again.width != plan.width || again.height != plan.height) {
      throw StateError('buildPlan 两次尺寸不同：建表不确定');
    }
  }
  final cloneUs = _cloneUs(src);
  stdout.writeln('\n形变开销（${src.width}x${src.height}，plan '
      '${plan.width}x${plan.height} = ${plan.alpha.length} px，amp=${ampDeg}°）');
  stdout.writeln('  buildPlan 一次: $buildUs µs/部件（每帧不重复）');
  stdout.writeln('  整帧快照 clone: $cloneUs µs/帧（所有部件共用）');

  final dst = src.clone();
  final snap = src.clone();
  const reps = 20;
  for (final n in [1, 2, 4, 8]) {
    var us = 0;
    for (var r = 0; r < reps + 4; r++) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        warper.apply(dst, snap, plan, ampDeg);
      }
      sw.stop();
      if (r >= 4) us += sw.elapsedMicroseconds;
    }
    final perFrame = us / reps;
    stdout.writeln('  $n 部件/帧: apply ${perFrame.toStringAsFixed(0)} µs'
        ' ⇒ 24 帧动画多 ${((perFrame + cloneUs) * 24 / 1000).toStringAsFixed(1)} ms'
        '（含快照）');
  }
}

int _cloneUs(RgbaImage src) {
  var total = 0;
  RgbaImage? last;
  for (var i = 0; i < 20; i++) {
    final sw = Stopwatch()..start();
    last = src.clone();
    sw.stop();
    total += sw.elapsedMicroseconds;
  }
  if (last == null) throw StateError('clone 未执行');
  return total ~/ 20;
}

void _printTable(List<_Row> rows) {
  stdout.writeln('部位动作验收矩阵（effects=[handMotion]，tier=standard，'
      'fps=12，duration=2s，maxDimension=1280）');
  stdout.writeln('${_pad('图', 30)} ${_pad('rest', 6)} ${_pad('seamless', 9)} '
      '${_pad('determ', 7)} 移动量                 contained(外溢/alpha/造色)  告警');
  for (final r in rows) {
    stdout.writeln('${_pad(r.name, 30)} ${_pad(r.rest, 6)} ${_pad(r.seamless, 9)} '
        '${_pad(r.determ, 7)} ${_pad(r.move, 22)} ${_pad(r.contain, 26)} ${r.warnings}'
        '${r.ok ? '' : '  <<FAIL'}');
    for (final p in r.problems) {
      stdout.writeln('    · $p');
    }
  }
}

String? _flag(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('$name=')) return a.substring(name.length + 1);
  }
  return null;
}

String? _siblingImage(String stem) {
  for (final ext in ['.png', '.jpg', '.jpeg']) {
    if (File('$stem$ext').existsSync()) return '$stem$ext';
  }
  return null;
}

String _base(String path) => path.split(RegExp(r'[\\/]')).last;

String _pad(String s, int n) =>
    s.length >= n ? s : s + ' ' * (n - s.length);

/// 逐字节相同 ⇒ 'ok'，否则 'FAIL'（调用方据此记 problems）。
String _sameBytes(List<int> a, List<int> b) => _bytesEqual(a, b) ? 'ok' : 'FAIL';

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Diff {
  _Diff(this.changed, this.mean, this.max);
  final int changed;
  final double mean;
  final int max;
  String get meanAsString => mean.toStringAsFixed(2);
}

_Diff _diffStats(RgbaImage a, RgbaImage b) {
  if (a.width != b.width || a.height != b.height) {
    throw StateError('两帧尺寸不一致：${a.width}x${a.height} vs ${b.width}x${b.height}');
  }
  var changed = 0, sum = 0, max = 0;
  for (var i = 0; i < a.pixelCount; i++) {
    final o = i * 4;
    final d = (a.data[o] - b.data[o]).abs() +
        (a.data[o + 1] - b.data[o + 1]).abs() +
        (a.data[o + 2] - b.data[o + 2]).abs();
    if (d == 0) continue;
    changed++;
    sum += d;
    if (d > max) max = d;
  }
  return _Diff(changed, changed == 0 ? 0 : sum / changed / 3, max);
}

/// 三通道绝对差的 8 倍放大图：给人眼看的「哪里动了」。
RgbaImage _amplifiedDiff(RgbaImage a, RgbaImage b) {
  final out = RgbaImage(width: a.width, height: a.height);
  for (var i = 0; i < a.pixelCount; i++) {
    final o = i * 4;
    for (var ch = 0; ch < 3; ch++) {
      final d = ((a.data[o + ch] - b.data[o + ch]).abs() * 8).clamp(0, 255);
      out.data[o + ch] = d;
    }
    out.data[o + 3] = 255;
  }
  return out;
}

class _Row {
  _Row(this.name);
  final String name;
  final problems = <String>[];
  String rest = '-';
  String move = '-';
  String contain = '-';
  String determ = '-';
  String seamless = '-';
  int warnings = 0;
  bool get ok => problems.isEmpty;
}
