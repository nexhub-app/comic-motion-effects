import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:comic_motion_server/comic_motion_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Plan B Task 6（服务侧）：`part_motion.json` 侧车的对外入口。
///
/// 引擎侧已有 `part_motion_pipeline_test.dart` 管住像素与指纹语义，这里只钉
/// 服务层的四件事：入口字段名、坏输入的**同步 400**、digest 在 result / 台账
/// 两处都能查到、以及「侧车改变产物」这条端到端事实确实穿过 HTTP。
void main() {
  late Directory tmp;
  late MotionApiService api;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cms_parts');
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

  String partsJson() => jsonEncode({
        'version': 1,
        'parts': [
          {
            'kind': 'hand',
            'polygon': [
              [0.15, 0.35],
              [0.85, 0.33],
              [0.85, 0.68],
              [0.15, 0.72],
            ],
            'anchor': {'x': 0.15, 'y': 0.48, 'joint': 'wrist'},
          },
        ]
      });

  /// 落盘输入图，返回路径（HTTP 侧用 `inputPath`，避免 base64 干扰断言）。
  String writeInput() {
    final p = '${tmp.path}/input.png';
    File(p)
        .writeAsBytesSync(Uint8List.fromList(ImageIO.encodePngFrame(canvas())));
    return p;
  }

  final jobConfig = {
    'fps': 4,
    'duration': 1.0,
    'seed': 7,
    'effects': ['handMotion'],
  };

  /// 提交 → 等待 → 返回轮询响应体（含 status / result / error）。
  Future<Map<String, dynamic>> submitAndWait(Map<String, dynamic> payload) async {
    final submitted =
        await call('POST', '/api/v1/jobs', body: jsonEncode(payload));
    final text = await submitted.readAsString();
    expect(submitted.statusCode, 202, reason: '提交应被接受: $text');
    final jobId = (jsonDecode(text) as Map)['jobId'] as String;
    await api.waitForJob(jobId, timeout: const Duration(minutes: 2));
    final polled = await call('GET', '/api/v1/jobs/$jobId');
    final j = jsonDecode(await polled.readAsString()) as Map<String, dynamic>;
    expect(j['status'], 'success', reason: '任务失败: ${j['error']}');
    return j;
  }

  group('HTTP partMotionBase64', () {
    test('非法 Base64 → 同步 400，任务根本不入队', () async {
      final before = (jsonDecode(
              await (await call('GET', '/api/v1/jobs')).readAsString())
          as Map)['jobs'].length;
      final res = await call('POST', '/api/v1/jobs',
          body: jsonEncode({
            'inputPath': writeInput(),
            'config': jobConfig,
            'partMotionBase64': '!!! not base64 !!!',
          }));
      expect(res.statusCode, 400);
      expect(jsonDecode(await res.readAsString())['error'], 'E_BAD_INPUT');
      final after = (jsonDecode(
              await (await call('GET', '/api/v1/jobs')).readAsString())
          as Map)['jobs'].length;
      expect(after, before);
    });

    test('带侧车 ⇒ result 与台账都带同一个 digest', () async {
      final input = writeInput();
      final j = await submitAndWait({
        'inputPath': input,
        'config': jobConfig,
        'partMotionBase64': base64Encode(utf8.encode(partsJson())),
      });
      final result = j['result'] as Map<String, dynamic>;
      final expected =
          ImageIO.contentHash8(utf8.encode(partsJson()));
      expect(result['partMotionDigest'], expected);

      final entries = api.ledger.query(jobId: j['jobId'] as String);
      expect(entries, hasLength(1));
      expect(entries.single['partMotionDigest'], expected);
    });

    test('不给侧车 ⇒ result 与台账都没有该键', () async {
      final j = await submitAndWait({
        'inputPath': writeInput(),
        'config': jobConfig,
      });
      final result = j['result'] as Map<String, dynamic>;
      expect(result.containsKey('partMotionDigest'), isFalse);
      final entries = api.ledger.query(jobId: j['jobId'] as String);
      expect(entries.single.containsKey('partMotionDigest'), isFalse);
    });

    test('侧车穿过 HTTP 真的改变产物（同图同配置，只有 parts 不同）', () async {
      final input = writeInput();
      final plain =
          await submitAndWait({'inputPath': input, 'config': jobConfig});
      final withParts = await submitAndWait({
        'inputPath': input,
        'config': jobConfig,
        'partMotionBase64': base64Encode(utf8.encode(partsJson())),
      });
      final a = File((plain['result'] as Map)['gif'] as String).readAsBytesSync();
      final b = File((withParts['result'] as Map)['gif'] as String).readAsBytesSync();
      expect(a, isNot(equals(b)));
      // 两次配置指纹必须相同——侧车是运行期输入，不进 configHash。
      expect((plain['result'] as Map)['configHash'],
          (withParts['result'] as Map)['configHash']);
    });

    test('坏侧车（版本不支持）⇒ 任务仍成功，warning 走 HTTP 回显', () async {
      final j = await submitAndWait({
        'inputPath': writeInput(),
        'config': jobConfig,
        'partMotionBase64': base64Encode(utf8.encode('{"version": 2}')),
      });
      final result = j['result'] as Map<String, dynamic>;
      expect(result['warnings'], isNotNull);
      expect((result['warnings'] as List).cast<String>().join('\n'),
          contains('part_motion'));
    });
  });

  group('CLI --part-motion 读文件', () {
    test('不给路径 = null（不启用，既有路径零变化）', () {
      expect(partMotionFromFile(null), isNull);
    });

    test('文件不存在 = ConfigException，消息带上路径', () {
      expect(() => partMotionFromFile('${tmp.path}/nope.json'),
          throwsA(isA<ConfigException>()));
      try {
        partMotionFromFile('${tmp.path}/nope.json');
      } on ConfigException catch (e) {
        expect(e.toString(), contains('nope.json'));
      }
    });

    test('正常读取原文（解析交给引擎，CLI 不校验 JSON）', () {
      final p = '${tmp.path}/parts.json';
      File(p).writeAsStringSync(partsJson());
      expect(partMotionFromFile(p), partsJson());
    });
  });
}
