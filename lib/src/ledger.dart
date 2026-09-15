import 'dart:io';

import 'json_compat.dart';

/// Every job (single or batch item) is appended to a JSONL ledger with full
/// traceability: input, params hash, outputs, timing, status, error.
class Ledger {
  Ledger(String dir) : _file = '$dir\\ledger.jsonl' {
    Directory(dir).createSync(recursive: true);
  }

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
      if (error != null) 'error': error,
    };
    final line = _jsonEncode(rec);
    File(_file).writeAsStringSync('$line\n', mode: FileMode.append);
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
String _jsonEncode(Map<String, dynamic> m) {
  final parts = <String>[];
  m.forEach((k, v) {
    final s = v is String
        ? '"${v.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"'
        : v.toString();
    parts.add('"$k":$s');
  });
  return '{${parts.join(',')}}';
}

Map<String, dynamic> _jsonDecode(String s) {
  return (jsonDecodeCompat(s) as Map).cast<String, dynamic>();
}
