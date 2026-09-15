import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'effect_config.dart';
import 'json_compat.dart';
import 'ledger.dart';
import 'pipeline.dart';

/// In-memory job record for the async HTTP API.
class _HttpJob {
  _HttpJob(this.id, this.inputPath, this.config);
  final String id;
  final String inputPath;
  final EffectConfig config;
  String status = 'queued'; // queued | running | success | failed
  Map<String, dynamic>? result;
  String? error;
  final DateTime createdAt = DateTime.now();
}

/// HTTP API service (async job model).
///
/// Endpoints:
///   GET  /health                     liveness + version + queue depth
///   POST /api/v1/jobs                submit {inputPath|inputBase64, config}
///   GET  /api/v1/jobs/<id>           job status + result paths
///   GET  /api/v1/jobs                all tracked jobs
///   GET  /api/v1/ledger?jobId&status persisted ledger query
///   GET  /files/<...>                output artifacts (gif/png/json)
class MotionApiService {
  MotionApiService({
    required this.dataDir,
    required this.ledger,
    this.concurrency = 2,
  }) : _outputsDir = '$dataDir/outputs' {
    Directory(_outputsDir).createSync(recursive: true);
  }

  final String dataDir;
  final Ledger ledger;
  final int concurrency;

  final String _outputsDir;
  final Map<String, _HttpJob> _jobs = {};
  final List<String> _queue = [];
  var _active = 0;
  var _seq = 0;
  final _completers = <String, Completer<void>>{};

  String get version => '1.0.0';

  Router get router {
    final r = Router();

    r.get('/health', (Request req) async {
      return _json({
        'status': 'ok',
        'service': 'comic-motion-backend',
        'version': version,
        'queueDepth': _queue.length,
        'active': _active,
        'jobsTracked': _jobs.length,
      });
    });

    r.post('/api/v1/jobs', (Request req) async {
      final body = await req.readAsString();
      Map<String, dynamic> j;
      try {
        j = (convert.jsonDecode(body) as Map).cast<String, dynamic>();
      } catch (_) {
        return _json(
            {'error': 'E_INVALID_JSON', 'message': '请求体不是合法 JSON'}, 400);
      }
      final cfgJson = (j['config'] as Map?)?.cast<String, dynamic>() ?? {};
      EffectConfig config;
      try {
        config = EffectConfig.fromJson(cfgJson);
      } catch (e) {
        return _json({
          'error': 'E_BAD_CONFIG',
          'message': '配置字段不正确: ${e.toString().substring(0, e.toString().length.clamp(0, 200))}'
        }, 400);
      }
      String? inputPath = j['inputPath'] as String?;
      if (j['inputBase64'] is String) {
        try {
          final bytes = convert.base64Decode(j['inputBase64'] as String);
          Directory('$dataDir/uploads').createSync(recursive: true);
          final tmp = '$dataDir/uploads/'
              'up_${DateTime.now().millisecondsSinceEpoch}_${++_seq}.bin';
          File(tmp).writeAsBytesSync(bytes);
          inputPath = tmp;
        } on FormatException {
          return _json(
              {'error': 'E_BAD_INPUT', 'message': 'inputBase64 不是合法 Base64'}, 400);
        }
      }
      if (inputPath == null || inputPath.isEmpty) {
        return _json(
            {'error': 'E_NO_INPUT', 'message': '缺少 inputPath 或 inputBase64'}, 400);
      }
      if (!File(inputPath).existsSync()) {
        return _json({'error': 'E_NO_INPUT', 'message': '文件不存在: $inputPath'}, 400);
      }

      final jobId = 'job-${DateTime.now().millisecondsSinceEpoch}-${++_seq}';
      _jobs[jobId] = _HttpJob(jobId, inputPath, config);
      _queue.add(jobId);
      _pump();
      return _json({'jobId': jobId, 'status': 'queued'}, 202);
    });

    r.get('/api/v1/jobs/<jobId>', (Request req, String jobId) async {
      final job = _jobs[jobId];
      if (job == null) {
        return _json({'error': 'E_NO_JOB', 'message': '任务不存在: $jobId'}, 404);
      }
      return _json({
        'jobId': job.id,
        'status': job.status,
        'createdAt': job.createdAt.toIso8601String(),
        if (job.result != null) 'result': job.result,
        if (job.error != null) 'error': job.error,
      });
    });

    r.get('/api/v1/jobs', (Request req) async {
      return _json({
        'jobs': _jobs.values
            .map((j) => {
                  'jobId': j.id,
                  'status': j.status,
                  if (j.result != null) 'result': j.result,
                  if (j.error != null) 'error': j.error,
                })
            .toList()
      });
    });

    r.get('/api/v1/ledger', (Request req) async {
      final jobId = req.url.queryParameters['jobId'];
      final status = req.url.queryParameters['status'];
      final entries = ledger.query(jobId: jobId, status: status);
      return _json({'count': entries.length, 'entries': entries});
    });

    r.get('/files/<path|[^?]*>', (Request req, String path) async {
      final normalized = path.replaceAll('\\', '/');
      if (normalized.contains('..')) {
        return _json({'error': 'E_BAD_PATH', 'message': '非法路径'}, 400);
      }
      final f = File('$_outputsDir/$normalized');
      if (!f.existsSync()) {
        return Response.notFound('not found');
      }
      final mime = normalized.endsWith('.gif')
          ? 'image/gif'
          : normalized.endsWith('.png')
              ? 'image/png'
              : normalized.endsWith('.json')
                  ? 'application/json'
                  : 'application/octet-stream';
      return Response.ok(f.readAsBytesSync(),
          headers: {'Content-Type': mime});
    });

    return r;
  }

  /// Wait for a specific job to leave the queue (used by tests/CLI).
  Future<void> waitForJob(String jobId,
      {Duration timeout = const Duration(minutes: 10)}) async {
    final c = Completer<void>();
    _completers[jobId] = c;
    _pump();
    return c.future.timeout(timeout);
  }

  void _pump() {
    while (_active < concurrency && _queue.isNotEmpty) {
      final jobId = _queue.removeAt(0);
      final job = _jobs[jobId];
      if (job == null) continue;
      _active++;
      job.status = 'running';
      Future(() {
        final r = MotionPipeline(job.config).processFile(
            job.inputPath, _outputsDir);
        job.result = {
          'input': r.inputPath,
          'gif': r.outputGif,
          'framesDir': r.frameDir,
          'width': r.width,
          'height': r.height,
          'layerCount': r.layerCount,
          'frameCount': r.frameCount,
          'elapsedMs': r.elapsedMs,
          'configHash': r.configHash,
        };
        job.status = 'success';
        ledger.appendJob(
          jobId: job.id,
          input: r.inputPath,
          configHash: job.config.configHash,
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
      }).catchError((Object e) {
        job.status = 'failed';
        job.error = e.toString();
        ledger.appendJob(
          jobId: job.id,
          input: job.inputPath,
          configHash: job.config.configHash,
          status: 'failed',
          error: job.error,
        );
      }).whenComplete(() {
        _active--;
        _completers.remove(jobId)?.complete();
        scheduleMicrotask(_pump);
      });
    }
  }
}

Response _json(Object? obj, [int status = 200]) {
  final body = jsonEncodeCompat(obj);
  final headers = {'Content-Type': 'application/json; charset=utf-8'};
  if (status == 200) return Response.ok(body, headers: headers);
  return Response(status, body: body, headers: headers);
}