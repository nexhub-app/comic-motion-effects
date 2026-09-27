import 'dart:convert';
import 'dart:io';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_server/comic_motion_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// HTTP 契约测试：拆包前 api_service 没有任何自动化测试覆盖，
/// 这里把路由层的错误码与成功路径钉住，防止后续改动破坏 docs/api.md 承诺。
void main() {
  late Directory tmp;
  late MotionApiService api;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cms_test');
    api = MotionApiService(
      dataDir: tmp.path,
      ledger: Ledger('${tmp.path}/ledger'),
      concurrency: 1,
    );
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<Response> call(String method, String path, {String? body}) {
    return api.router.call(Request(method, Uri.parse('http://localhost$path'),
        body: body, headers: body == null ? null : {
          'content-type': 'application/json; charset=utf-8',
        }));
  }

  test('GET /health 返回版本与队列状态', () async {
    final res = await call('GET', '/health');
    expect(res.statusCode, 200);
    final j = jsonDecode(await res.readAsString()) as Map;
    expect(j['status'], 'ok');
    expect(j['version'], comicMotionVersion);
  });

  test('请求体不是 JSON → E_INVALID_JSON', () async {
    final res = await call('POST', '/api/v1/jobs', body: 'not json');
    expect(res.statusCode, 400);
    expect(jsonDecode(await res.readAsString())['error'], 'E_INVALID_JSON');
  });

  test('配置字段类型错误 → E_BAD_CONFIG', () async {
    final res = await call('POST', '/api/v1/jobs',
        body: jsonEncode({'inputPath': 'x.png', 'config': {'fps': 'fast'}}));
    expect(res.statusCode, 400);
    expect(jsonDecode(await res.readAsString())['error'], 'E_BAD_CONFIG');
  });

  test('缺少输入 → E_NO_INPUT', () async {
    final res =
        await call('POST', '/api/v1/jobs', body: jsonEncode({'config': {}}));
    expect(res.statusCode, 400);
    expect(jsonDecode(await res.readAsString())['error'], 'E_NO_INPUT');
  });

  test('输入文件不存在 → E_NO_INPUT', () async {
    final res = await call('POST', '/api/v1/jobs',
        body: jsonEncode({'inputPath': '${tmp.path}/nope.png'}));
    expect(res.statusCode, 400);
    expect(jsonDecode(await res.readAsString())['error'], 'E_NO_INPUT');
  });

  test('提交 → 轮询 → success，产物落盘且台账可查', () async {
    final png =
        File('test/fixtures/sample_8x8.png').readAsBytesSync();
    final submitted = await call('POST', '/api/v1/jobs',
        body: jsonEncode({
          'inputBase64': base64Encode(png),
          'config': {'fps': 2, 'duration': 1.0, 'maxDimension': 8},
        }));
    expect(submitted.statusCode, 202);
    final jobId =
        (jsonDecode(await submitted.readAsString()) as Map)['jobId'] as String;
    expect(jobId, isNotEmpty);

    await api.waitForJob(jobId, timeout: const Duration(minutes: 2));

    final polled = await call('GET', '/api/v1/jobs/$jobId');
    final j = jsonDecode(await polled.readAsString()) as Map;
    expect(j['status'], 'success', reason: 'job error: ${j['error']}');
    final result = j['result'] as Map;
    expect(File(result['gif'] as String).existsSync(), isTrue);
    expect(Directory(result['framesDir'] as String).existsSync(), isTrue);

    final ledgerRes = await call('GET', '/api/v1/ledger?status=success');
    final l = jsonDecode(await ledgerRes.readAsString()) as Map;
    expect(l['count'], greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
