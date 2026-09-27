import 'dart:io';

import 'package:args/args.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:comic_motion/comic_motion.dart';

import 'api_service.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addCommand('serve')
    ..addCommand('process')
    ..addCommand('batch')
    ..addCommand('job')
    ..addCommand('samples')
    ..addOption('port', abbr: 'p', defaultsTo: '8787', help: 'HTTP 端口(serve)')
    ..addOption('data-dir', defaultsTo: 'data', help: '台账/上传/输出根目录')
    ..addOption('out',
        abbr: 'o', defaultsTo: 'outputs', help: '输出目录(process/batch)')
    ..addOption('input', abbr: 'i', help: '输入文件(process)或目录(batch)')
    ..addOption('config', abbr: 'c', help: '效果参数 JSON 文件路径')
    ..addOption('fps', defaultsTo: '24', help: '帧率')
    ..addOption('duration', defaultsTo: '4.0', help: '时长(秒)')
    ..addOption('amplitude', help: '视差幅度(占宽度比例, 如 0.012)')
    ..addOption('direction', help: '视差主方向(度)')
    ..addOption('layers', defaultsTo: '3', help: '层数 2-4')
    ..addOption('format', defaultsTo: 'both', help: 'gif|frames|both')
    ..addOption('seed', defaultsTo: '20260914', help: '确定性随机种子')
    ..addOption('max-dimension', defaultsTo: '1600', help: '工作分辨率上限')
    ..addOption('effects', help: '逗号分隔效果列表，如 parallax,breathing,rain,snow')
    ..addFlag('reduced-motion', negatable: false, help: '减弱动态：输出单帧静态图')
    ..addFlag('dither',
        negatable: true,
        defaultsTo: null,
        help: 'GIF 色带抖动（默认关；抖动核走配置 quality.ditherMode）')
    ..addOption('quality', help: '渲染档 legacy|standard|rich（legacy 逐字节复现 v1.2）')
    ..addOption('parallel',
        defaultsTo: 'auto',
        help: '帧渲染并行 isolate 数：auto 或正整数（1=串行）。只影响耗时，不影响输出字节')
    ..addFlag('version', negatable: false, help: '打印版本');
  final res = parser.parse(args);

  if (res['version'] == true) {
    stdout.writeln('comic-motion-backend $comicMotionVersion');
    return;
  }

  final cmd = res.command?.name;
  if (cmd == null) {
    stdout.writeln(parser.usage);
    exit(64);
  }

  switch (cmd) {
    case 'serve':
      await _serve(int.parse(res['port'] as String), res['data-dir'] as String);
    case 'process':
      await _process(res);
    case 'batch':
      await _batch(res);
    case 'job':
      _job(res);
    case 'samples':
      stdout.writeln('运行: dart run tool/generate_samples.dart <输出目录>');
    default:
      stdout.writeln(parser.usage);
      exit(64);
  }
}

EffectConfig _cfg(ArgResults res) {
  final cfgPath = res['config'] as String?;
  var cfg = cfgPath != null
      ? EffectConfig.fromFile(cfgPath)
      : EffectConfig(
          fps: int.parse(res['fps'] as String),
          durationSec: double.parse(res['duration'] as String),
          layerCount: int.parse(res['layers'] as String),
          outputFormat: OutputFormat.values
              .firstWhere((f) => f.name == (res['format'] as String)),
          seed: int.parse(res['seed'] as String),
          maxDimension: int.parse(res['max-dimension'] as String),
        );
  if (cfgPath == null) {
    cfg.applyOverrides(
      amplitude: res['amplitude'] != null
          ? double.parse(res['amplitude'] as String)
          : null,
      directionDeg: res['direction'] != null
          ? double.parse(res['direction'] as String)
          : null,
    );
  }
  final effectsArg = res['effects'] as String?;
  if (effectsArg != null && effectsArg.trim().isNotEmpty) {
    cfg.effects = effectsArg
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(effectKindFromName)
        .toList();
  }
  if (res['reduced-motion'] == true) {
    cfg.reducedMotion = true;
  }
  final ditherArg = res['dither'] as bool?;
  if (ditherArg != null) {
    cfg.quality = cfg.quality.copyWith(dither: ditherArg);
  }
  final qualityArg = res['quality'] as String?;
  if (qualityArg != null) {
    final hit = RenderTier.values.where((t) => t.name == qualityArg).toList();
    if (hit.isEmpty) {
      throw ConfigException(
          '未知质量档: "$qualityArg"（可选: ${RenderTier.values.map((t) => t.name).join(',')}）');
    }
    cfg.quality = cfg.quality.copyWith(tier: hit.first);
  }
  return cfg;
}

/// `--parallel`：auto = 引擎默认（min(8, 核数)），数字 = 显式并行度。
/// 执行期参数，绝不写进 EffectConfig —— 它不改变输出字节，写进配置会污染指纹。
int? _parallelArg(ArgResults res) {
  final v = (res['parallel'] as String? ?? 'auto').trim();
  if (v == 'auto' || v.isEmpty) return null;
  final n = int.tryParse(v);
  if (n == null || n < 1) {
    stderr.writeln('--parallel 需要正整数或 auto，收到: "$v"');
    exit(64);
  }
  return n;
}

Future<void> _process(ArgResults res) async {
  final input = res['input'] as String?;
  if (input == null) {
    stderr.writeln('缺少 --input <图片文件>');
    exit(64);
  }
  final cfg = _cfg(res);
  final ledger = Ledger('${res['data-dir'] as String}/ledger');
  final jobId = 'cli-${DateTime.now().millisecondsSinceEpoch}';
  try {
    final r = await MotionPipeline(cfg, parallel: _parallelArg(res))
        .processFile(input, res['out'] as String);
    ledger.appendJob(
      jobId: jobId,
      input: input,
      configHash: cfg.configHash,
      status: 'success',
      outputGif: r.outputGif,
      frameDir: r.frameDir,
      paramsFile: r.paramsFile,
      width: r.width,
      height: r.height,
      layerCount: r.layerCount,
      frameCount: r.frameCount,
      elapsedMs: r.elapsedMs,
      parallel: r.parallel,
      parallelFallback: r.parallelFallback ? true : null,
      warnings: r.warnings,
    );
    for (final w in r.warnings) {
      stderr.writeln('警告: $w');
    }
    stdout.writeln(jsonEncodeCompat(r.toJson()));
  } on ImageDecodeException catch (e) {
    ledger.appendJob(
        jobId: jobId,
        input: input,
        configHash: cfg.configHash,
        status: 'failed',
        error: e.toString());
    stderr.writeln('解码失败: $e');
    exit(2);
  } on ImageTooLargeException catch (e) {
    ledger.appendJob(
        jobId: jobId,
        input: input,
        configHash: cfg.configHash,
        status: 'failed',
        error: e.toString());
    stderr.writeln('图片过大: $e');
    exit(2);
  } on EngineWorkerException catch (e) {
    ledger.appendJob(
        jobId: jobId,
        input: input,
        configHash: cfg.configHash,
        status: 'failed',
        error: '${EngineWorkerException.code}: $e');
    stderr.writeln('${EngineWorkerException.code}: $e');
    exit(4);
  }
}

Future<void> _batch(ArgResults res) async {
  final input = res['input'] as String?;
  if (input == null) {
    stderr.writeln('缺少 --input <图片目录>');
    exit(64);
  }
  final cfg = _cfg(res);
  final ledger = Ledger('${res['data-dir'] as String}/ledger');
  final runner = BatchRunner(ledger);
  final results = await runner.runFolder(
      inputDir: input,
      outputDir: res['out'] as String,
      config: cfg,
      jobIdPrefix: 'batchcli',
      parallel: _parallelArg(res));
  final ok = results.where((r) => r.ok).length;
  final fail = results.where((r) => !r.ok).length;
  stdout.writeln(jsonEncodeCompat({
    'total': results.length,
    'ok': ok,
    'failed': fail,
    'items': results.map((r) => r.toJson()).toList(),
  }));
  if (fail > 0) exit(3);
}

void _job(ArgResults res) {
  final ledger = Ledger('${res['data-dir'] as String}/ledger');
  final rest = res.rest;
  if (rest.isEmpty) {
    stderr.writeln('用法: job <jobId|all> [--data-dir ...]');
    exit(64);
  }
  final entries =
      rest[0] == 'all' ? ledger.query() : ledger.query(jobId: rest[0]);
  stdout
      .writeln(jsonEncodeCompat({'count': entries.length, 'entries': entries}));
}

Future<void> _serve(int port, String dataDir) async {
  final ledger = Ledger('$dataDir/ledger');
  final service = MotionApiService(dataDir: dataDir, ledger: ledger);
  final handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addHandler(service.router.call);
  final server = await shelf_io.serve(handler, '0.0.0.0', port);
  stdout.writeln(
      'comic-motion-backend $comicMotionVersion listening on http://0.0.0.0:${server.port}');
  stdout.writeln('  GET  /health');
  stdout.writeln('  POST /api/v1/jobs   {inputPath|inputBase64, config{...}}');
  stdout.writeln('  GET  /api/v1/jobs/<id>');
  stdout.writeln('  GET  /api/v1/ledger?jobId=&status=');
  stdout.writeln('  GET  /files/<相对输出路径>');
}
