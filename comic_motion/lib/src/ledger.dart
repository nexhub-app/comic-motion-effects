import 'dart:io';

import 'json_compat.dart';

/// Every job (single or batch item) is appended to a JSONL ledger with full
/// traceability: input, params hash, outputs, timing, status, error.
///
/// 嵌入场景控制体积：超过 [maxBytes] 时把当前文件轮转为 `ledger.jsonl.1`
/// （只保留一代，更早的归档被覆盖）；[query] 只覆盖当前档。
/// 完全不需要台账的调用方给 [BatchRunner] 传 null ledger 即可。
class Ledger {
  Ledger(String dir, {this.maxBytes = defaultMaxBytes})
      : _file = '$dir/ledger.jsonl' {
    Directory(dir).createSync(recursive: true);
  }

  /// 单档体积上限（默认 16MB）：已在档上的下次写入前轮转。<=0 表示不轮转。
  static const int defaultMaxBytes = 16 * 1024 * 1024;

  final int maxBytes;

  final String _file;
  final List<Map<String, dynamic>> _cache = [];
  bool _loaded = false;

  String get filePath => _file;

  void appendJob({
    required String jobId,
    required String input,
    required String configHash,
    required String status, // success | failed
    String? outputGif,
    String? frameDir,
    String? paramsFile,
    int? width,
    int? height,
    int? layerCount,
    int? frameCount,
    int? elapsedMs,
    int? parallel,
    bool? parallelFallback,
    String? partMotionDigest,
    List<String>? warnings,
    String? error,
  }) {
    final rec = <String, dynamic>{
      'jobId': jobId,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'input': input,
      'configHash': configHash,
      'status': status,
      if (outputGif != null) 'outputGif': outputGif,
      if (frameDir != null) 'frameDir': frameDir,
      if (paramsFile != null) 'paramsFile': paramsFile,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (layerCount != null) 'layerCount': layerCount,
      if (frameCount != null) 'frameCount': frameCount,
      if (elapsedMs != null) 'elapsedMs': elapsedMs,
      if (parallel != null) 'parallel': parallel,
      if (parallelFallback != null) 'parallelFallback': parallelFallback,
      // Plan B Task 6：部件侧车指纹。它是运行期输入（不进 configHash），但
      // 改变像素——没有这一条，事后无法区分「同配置两次跑出不同 GIF」是
      // bug 还是换了侧车。null = 未启用侧车，键不出现在旧记录里。
      if (partMotionDigest != null) 'partMotionDigest': partMotionDigest,
      if (warnings != null && warnings.isNotEmpty) 'warnings': warnings,
      if (error != null) 'error': error,
    };
    final line = _jsonEncode(rec);
    final f = File(_file);
    if (maxBytes > 0 && f.existsSync() && f.lengthSync() > maxBytes) {
      final rotatedPath = '$_file.1';
      final rotated = File(rotatedPath);
      if (rotated.existsSync()) rotated.deleteSync();
      f.renameSync(rotatedPath);
      _cache.clear();
      _loaded = false; // 当前档变空，下次查询重建缓存
    }
    f.writeAsStringSync('$line\n', mode: FileMode.append);
    _cache.add(rec);
    _loaded = true; // cache now includes everything in the file
  }

  /// Query entries, optionally filtered by jobId or status.
  List<Map<String, dynamic>> query({String? jobId, String? status}) {
    _load();
    return _cache.where((r) {
      if (jobId != null && r['jobId'] != jobId) return false;
      if (status != null && r['status'] != status) return false;
      return true;
    }).toList();
  }

  Map<String, dynamic>? byId(String jobId) {
    final hits = query(jobId: jobId);
    return hits.isEmpty ? null : hits.first;
  }

  void _load() {
    if (_loaded) return;
    final f = File(_file);
    if (f.existsSync()) {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          _cache.add(_jsonDecode(line));
        } catch (_) {
          // A torn last line (crash mid-write) must not poison the ledger.
          continue;
        }
      }
    }
    _loaded = true;
  }
}

// Minimal JSON helpers to avoid importing dart:convert in the public API.
String _quote(String v) =>
    '"${v.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"';

String _jsonEncode(Map<String, dynamic> m) {
  final parts = <String>[];
  m.forEach((k, v) {
    final String s;
    if (v is String) {
      s = _quote(v);
    } else if (v is List) {
      s = '[${v.map((e) => _quote('$e')).join(',')}]';
    } else {
      s = v.toString();
    }
    parts.add('"$k":$s');
  });
  return '{${parts.join(',')}}';
}

Map<String, dynamic> _jsonDecode(String s) {
  return (jsonDecodeCompat(s) as Map).cast<String, dynamic>();
}
