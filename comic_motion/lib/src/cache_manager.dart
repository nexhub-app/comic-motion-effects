import 'dart:io' as io;

/// 缓存管理组件（T3）：解析并清理本库定义的产物目录契约。
///
/// 产物目录形态（1.3.1 起，见 README「Output naming & content fingerprint」）：
/// - 单图：`<stem>_<contentHash8>_<configHash8>`
/// - strip 片级：`<stem>_slice<NNN>_<contentHash8>_<configHash8>`
///
/// 本组件只把**直接位于 [MotionCacheManager.rootDir] 下、且完整匹配上述
/// 契约的目录**当作缓存条目；其余文件与目录（嵌入方自己的东西）一律跳过、
/// 绝不删除。条目扫描不递归——契约就是「产物目录直接落在输出根下」，
/// 更深层的东西不是本库写出来的。
///
/// 解析从右往左：先剥 configHash8（8 位十六进制），再剥 contentHash8，
/// 余部可选匹配 `_slice<NNN>` 尾缀得片序号，其余为 stem。stem 本身含
/// 下划线与 8 位十六进制片段都能正确回溯；仅当 stem 以 `_slice<NNN>` 结尾
/// 时可能被误标为片级条目（只影响 [MotionCacheEntry.sliceIndex] 的标注，
/// 清理语义不变）。
class MotionCacheManager {
  MotionCacheManager(this.rootDir);

  /// 缓存根目录（即嵌入方传给管线的 outputDir）。
  final String rootDir;

  // 注意：matchAsPrefix 在指定位置尝试匹配，`^` 锚仍指向串首——这里必须用
  // 无锚模式（{8} 恰好吃掉尾部 8 个字符，等价于尾部锚定）。
  // contentHash8 恒为 8 位 hex；configHash8 是 configHash 字符串（有符号
  // int 的十六进制）的前 8 位，最高位置位时形如 '-060ca22'——库产目录按
  // 字面携带，解析原样接受，绝不改写 configHash 本身（稳定性红线）。
  final RegExp _hash8 = RegExp(r'[0-9a-f]{8}');
  final RegExp _cf8 = RegExp(r'-[0-9a-f]{7}|[0-9a-f]{8}');
  final RegExp _sliceTail = RegExp(r'_slice(\d{3})$');

  /// 解析目录名；非契约形态返回 null（调用方跳过，绝不删除）。
  _ParsedName? _parse(String name) {
    if (name.length < 19) return null; // 最短：1 字符 stem + '_' + ch8 + '_' + cf8
    if (!name.contains('_')) return null;
    final cf = _cf8.matchAsPrefix(name, name.length - 8);
    if (cf == null || name[name.length - 9] != '_') return null;
    final withoutCf = name.substring(0, name.length - 9);
    if (withoutCf.length < 9) return null;
    final ch = _hash8.matchAsPrefix(withoutCf, withoutCf.length - 8);
    if (ch == null || withoutCf[withoutCf.length - 9] != '_') return null;
    var stem = withoutCf.substring(0, withoutCf.length - 9);
    final contentHash = withoutCf.substring(withoutCf.length - 8);
    final configHash = name.substring(name.length - 8);
    int? sliceIndex;
    final slice = _sliceTail.firstMatch(stem);
    if (slice != null) {
      sliceIndex = int.parse(slice.group(1)!);
      stem = stem.substring(0, slice.start);
    }
    if (stem.isEmpty) return null; // 库不会写出空 stem 目录，防御性跳过
    return _ParsedName(stem, contentHash, configHash, sliceIndex);
  }

  /// 扫描 [rootDir] 下的全部契约条目。无法识别的文件 / 目录一律忽略。
  List<MotionCacheEntry> listEntries() {
    final root = io.Directory(rootDir);
    if (!root.existsSync()) return const [];
    final entries = <MotionCacheEntry>[];
    for (final e in root.listSync(followLinks: false)) {
      if (e is! io.Directory) continue; // 文件不是条目
      final parsed = _parse(_baseName(e.path));
      if (parsed == null) continue; // 非契约目录，跳过
      final stat = _dirStat(e);
      entries.add(MotionCacheEntry(
        stem: parsed.stem,
        contentHash: parsed.contentHash,
        configHash: parsed.configHash,
        sliceIndex: parsed.sliceIndex,
        byteSize: stat.$1,
        modifiedAt: stat.$2,
        directory: e.path,
      ));
    }
    return entries;
  }

  /// 缓存总字节数。
  int totalSize() =>
      listEntries().fold(0, (sum, e) => sum + e.byteSize);

  /// 缓存条目数。
  int entryCount() => listEntries().length;

  /// 按最近使用时间淘汰（LRU）：[olderThan] 满足者无条件删除；
  /// 余下条目按 modifiedAt 从新到旧保留，超过 [maxEntries] 或
  /// [maxBytes] 的从旧到新淘汰。三个条件可任意组合。
  ///
  /// 返回清理明细（被删条目与释放字节数）。
  CachePurgeReport purgeLRU(
      {int? maxEntries, int? maxBytes, Duration? olderThan}) {
    final entries = listEntries();
    final cutoff =
        olderThan == null ? null : DateTime.now().subtract(olderThan);
    final byNewest = [...entries]..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final keep = <MotionCacheEntry>{};
    var keepBytes = 0;
    for (final e in byNewest) {
      if (cutoff != null && e.modifiedAt.isBefore(cutoff)) continue;
      if (maxEntries != null && keep.length >= maxEntries) continue;
      if (maxBytes != null && keepBytes + e.byteSize > maxBytes) continue;
      keep.add(e);
      keepBytes += e.byteSize;
    }
    return _deleteWhere(entries, (e) => !keep.contains(e));
  }

  /// 删除指定 [stem] 的全部条目（含其 strip 片级条目）。
  CachePurgeReport purgePrefix(String stem) =>
      _deleteWhere(listEntries(), (e) => e.stem == stem);

  /// 删除全部契约条目。非契约文件 / 目录不受影响。
  CachePurgeReport purgeAll() => _deleteWhere(listEntries(), (_) => true);

  CachePurgeReport _deleteWhere(
      List<MotionCacheEntry> entries, bool Function(MotionCacheEntry) match) {
    var freed = 0;
    final purged = <MotionCacheEntry>[];
    for (final e in entries) {
      if (!match(e)) continue;
      try {
        io.Directory(e.directory).deleteSync(recursive: true);
      } catch (_) {
        continue; // 删除失败不抛：条目可能已被外部移走，报告以实际为准
      }
      freed += e.byteSize;
      purged.add(e);
    }
    return CachePurgeReport(purged: purged, freedBytes: freed);
  }

  String _baseName(String path) {
    final norm = path.replaceAll('\\', '/');
    return norm.substring(norm.lastIndexOf('/') + 1);
  }

  /// 目录内全部文件的字节数与最新修改时间（一次遍历同时取）。
  (int, DateTime) _dirStat(io.Directory dir) {
    var bytes = 0;
    var newest = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is io.File) {
          final stat = e.statSync();
          bytes += stat.size;
          if (stat.modified.isAfter(newest)) newest = stat.modified;
        }
      }
    } catch (_) {}
    return (bytes, newest);
  }
}

/// 解析中间结果。
class _ParsedName {
  _ParsedName(this.stem, this.contentHash, this.configHash, this.sliceIndex);
  final String stem;
  final String contentHash;
  final String configHash;
  final int? sliceIndex;
}

/// 一个可识别的缓存条目（= 一个契约产物目录）。
class MotionCacheEntry {
  MotionCacheEntry({
    required this.stem,
    required this.contentHash,
    required this.configHash,
    required this.sliceIndex,
    required this.byteSize,
    required this.modifiedAt,
    required this.directory,
  });

  /// 输入 stem（strip 片级条目不含 `_slice<NNN>` 尾缀）。
  final String stem;

  /// 输入内容指纹（8 位十六进制）。
  final String contentHash;

  /// 参数指纹（`configHash` 字符串前 8 位：通常为 8 位 hex，负值哈希带
  /// 前导 `-`；与 `EffectConfig.configHash.substring(0, 8)` 字面一致）。
  final String configHash;

  /// strip 片序号；单图条目为 null。
  final int? sliceIndex;

  /// 目录内全部文件字节总数。
  final int byteSize;

  /// 目录内最新文件修改时间（LRU 依据）。
  final DateTime modifiedAt;

  /// 条目目录绝对路径。
  final String directory;

  bool get isSlice => sliceIndex != null;

  @override
  String toString() =>
      'MotionCacheEntry($directory, ${byteSize}B, modified $modifiedAt)';
}

/// 清理明细。
class CachePurgeReport {
  CachePurgeReport({required this.purged, required this.freedBytes});

  /// 本次删除的条目（删除失败的不在其中）。
  final List<MotionCacheEntry> purged;

  /// 释放的字节数。
  final int freedBytes;

  int get count => purged.length;

  @override
  String toString() => 'CachePurgeReport($count entries, ${freedBytes}B freed)';
}
