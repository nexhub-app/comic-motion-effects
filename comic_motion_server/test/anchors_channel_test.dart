import 'dart:convert';
import 'dart:io';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_server/comic_motion_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// X3（v1.5）服务侧：`anchors.json` 显著性侧车的对外入口。
///
/// 与 part_motion_channel_test 同一口径只钉服务层四件事：入口字段名
/// （anchorsBase64）、坏输入的同步 400、digest 在 result / 台账两处可查、
/// 以及解析告警随 warnings 冒泡到 HTTP。
void main() {
  late Directory tmp;
  late MotionApiService api;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cms_anchors');
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
        body: body,
        headers: body == null
            ? null
            : {'content-type': 'application/json; charset=utf-8'}));
  }

  const w = 120, h = 120;

  RgbaImage canvas() {
    final img = RgbaImage(width: w, height: h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      img.data[o] = 250;
      img.data[o + 1] = 250;
      img.data[o + 2] = 250;
      img.data[o + 3] = 255;
    }
    for (var y = 40; y <= 80; y++) {
      for (var x = 20; x <= 100; x++) {
        if (((x - 20) ~/ 5).isEven) {
          final o = (y * w + x) * 4;
          img.data[o] = 10;
          img.data[o + 1] = 10;
          img.data[o + 2] = 10;
        }
      }
    }
    return img;
  }

  /// 落盘输入图，返回路径。
  String writeInput() {
    Directory('${tmp.path}/in').createSync(recursive: true);
    final path = '${tmp.path}/in/page.png';
    File(path).writeAsBytesSync(ImageIO.encodePngFrame(canvas()));
    return path;
  }

  String anchorsJson() => jsonEncode({
        'version': 1,
        'anchors': [
          {'x': 0.25, 'y': 0.75, 'weight': 0.95},
          {'x': 0.75, 'y': 0.25, 'weight': 0.5},
        ],
      });

  test('anchorsBase64 合法通道：202 → 成功，result/台账带 anchorsDigest', () async {
    final inputPath = writeInput();
    final res = await call('POST', '/api/v1/jobs',
        body: jsonEncode({
          'inputPath': inputPath,
          'config': {'effects': ['focusLines'], 'fps': 12, 'durationSec': 1.0},
          'anchorsBase64': base64Encode(utf8.encode(anchorsJson())),
        }));
    expect(res.statusCode, 202);
    final jobId =
        (jsonDecode(await res.readAsString()) as Map)['jobId'] as String;
    await api.waitForJob(jobId);

    final status = await call('GET', '/api/v1/jobs/$jobId');
    final job = jsonDecode(await status.readAsString()) as Map;
    expect(job['status'], 'success');
    final result = job['result'] as Map;
    expect(result['anchorsDigest'], isA<String>());
    expect((result['anchorsDigest'] as String).length, 8);

    final ledgerRes = await call('GET', '/api/v1/ledger?jobId=$jobId');
    final entries = (jsonDecode(await ledgerRes.readAsString()) as Map)['entries']
        as List;
    expect(entries, hasLength(1));
    expect((entries.first as Map)['anchorsDigest'], result['anchorsDigest']);
  });

  test('anchorsBase64 非法 Base64：同步 400', () async {
    final inputPath = writeInput();
    final res = await call('POST', '/api/v1/jobs',
        body: jsonEncode({
          'inputPath': inputPath,
          'config': {'effects': ['focusLines']},
          'anchorsBase64': '!!!not-base64!!!',
        }));
    expect(res.statusCode, 400);
    final body = jsonDecode(await res.readAsString()) as Map;
    expect(body['error'], 'E_BAD_INPUT');
    expect(body['message'], contains('anchorsBase64'));
  });

  test('坏侧车内容：任务不失败，解析告警随 warnings 冒泡', () async {
    final inputPath = writeInput();
    final res = await call('POST', '/api/v1/jobs',
        body: jsonEncode({
          'inputPath': inputPath,
          'config': {'effects': ['focusLines'], 'fps': 12, 'durationSec': 1.0},
          'anchorsBase64': base64Encode(utf8.encode('garbage{{{')),
        }));
    expect(res.statusCode, 202);
    final jobId =
        (jsonDecode(await res.readAsString()) as Map)['jobId'] as String;
    await api.waitForJob(jobId);

    final status = await call('GET', '/api/v1/jobs/$jobId');
    final job = jsonDecode(await status.readAsString()) as Map;
    expect(job['status'], 'success');
    final result = job['result'] as Map;
    expect(result['warnings'], isNotEmpty);
    expect((result['warnings'] as List).first, contains('anchors'));
  });

  test('不带 anchorsBase64：result 无 anchorsDigest 键（既有响应零变化）', () async {
    final inputPath = writeInput();
    final res = await call('POST', '/api/v1/jobs',
        body: jsonEncode({
          'inputPath': inputPath,
          'config': {'effects': ['focusLines'], 'fps': 12, 'durationSec': 1.0},
        }));
    final jobId =
        (jsonDecode(await res.readAsString()) as Map)['jobId'] as String;
    await api.waitForJob(jobId);
    final status = await call('GET', '/api/v1/jobs/$jobId');
    final result =
        ((jsonDecode(await status.readAsString()) as Map)['result'] as Map);
    expect(result.containsKey('anchorsDigest'), isFalse);
  });
}
