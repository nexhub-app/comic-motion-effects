import 'dart:io';

import 'package:args/args.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'api_service.dart';
import 'batch_runner.dart';
import 'effect_config.dart';
import 'image_model.dart';
import 'json_compat.dart';
import 'ledger.dart';
import 'pipeline.dart';

const String kVersion = '1.1.0';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addCommand('serve')
    ..addCommand('process')
    ..addCommand('batch')
    ..addCommand('job')
    ..addCommand('samples')
    ..addOption('port', abbr: 'p', defaultsTo: '8787', help: 'HTTP 端口(serve)')
    ..addOption('data-dir', defaultsTo: 'data', help: '台账/上传/输出根目录')
    ..addOption('out', abbr: 'o', defaultsTo: 'outputs', help: '输出目录(process/batch)')
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
    ..addFlag('dither', negatable: true, defaultsTo: null, help: 'GIF 色带抖动（默认开）')
    ..addFlag('version', negatable: false, help: '打印版本');
  final res = parser.parse(args);

  if (res['version'] == true) {
    stdout.writeln('comic-motion-backend $kVersion');
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
      _process(res);
    case 'batch':
      _batch(res);
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
        .map((s) {
      for (final k in EffectKind.values) {
        if (k.name == s) return k;
      }
      throw ConfigException(
          '未知效果名称: "$s"（可选: ${EffectKind.values.map((e) => e.name).join(',')}）');
    }).toList();
  }
  if (res['reduced-motion'] == true) {
    cfg.reducedMotion = true;
  }
  final ditherArg = res['dither'] as bool?;
  if (ditherArg != null) {
    cfg.quality = QualityParams(dither: ditherArg);
  }
  return cfg;
}

void _process(ArgResults res) {
  final input = res['input'] as String?;
  if (input == null) {
    stderr.writeln('缺少 --input <图片文件>');
    exit(64);
  }
  final cfg = _cfg(res);
  final ledger = Ledger('${res['data-dir'] as String}/ledger');
  final jobId =
      'cli-${DateTime.now().millisecondsSinceEpoch}';
  try {
    final r = MotionPipeline(cfg).processFile(input, res['out'] as String);
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
    );
    stdout.writeln(jsonEncodeCompat(r.toJson()));
  } on ImageDecodeException catch (e) {
    ledger.appendJob(
        jobId: jobId, input: input, configHash: cfg.configHash,
        status: 'failed', error: e.toString());
    stderr.writeln('解码失败: $e');
    exit(2);
  } on ImageTooLargeException catch (e) {
    ledger.appendJob(
        jobId: jobId, input: input, configHash: cfg.configHash,
        status: 'failed', error: e.toString());
    stderr.writeln('图片过大: $e');
    exit(2);
  }
}

void _batch(ArgResults res) {
  final input = res['input'] as String?;
  if (input == null) {
    stderr.writeln('缺少 --input <图片目录>');
    exit(64);
  }
  final cfg = _cfg(res);
  final ledger = Ledger('${res['data-dir'] as String}/ledger');
  final runner = BatchRunner(ledger);
  final results = runner.runFolder(
      inputDir: input,
      outputDir: res['out'] as String,
      config: cfg,
      jobIdPrefix: 'batchcli');
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
  final entries = rest[0] == 'all'
      ? ledger.query()
      : ledger.query(jobId: rest[0]);
  stdout.writeln(jsonEncodeCompat({'count': entries.length, 'entries': entries}));
}

Future<void> _serve(int port, String dataDir) async {
  final ledger = Ledger('$dataDir/ledger');
  final service =
      MotionApiService(dataDir: dataDir, ledger: ledger);
  final handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addHandler(service.router.call);
  final server = await shelf_io.serve(handler, '0.0.0.0', port);
  stdout.writeln(
      'comic-motion-backend $kVersion listening on http://0.0.0.0:${server.port}');
  stdout.writeln('  GET  /health');
  stdout.writeln('  POST /api/v1/jobs   {inputPath|inputBase64, config{...}}');
  stdout.writeln('  GET  /api/v1/jobs/<id>');
  stdout.writeln('  GET  /api/v1/ledger?jobId=&status=');
  stdout.writeln('  GET  /files/<相对输出路径>');
}
