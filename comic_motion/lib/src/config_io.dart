/// IO 边界：配置文件的磁盘读取。[EffectConfig] 本体保持纯 Dart
/// （序列化 + configHash 与平台无关），文件加载集中在这里。
library;

import 'dart:convert';
import 'dart:io';

import 'effect_config.dart';

/// Load an [EffectConfig] from a JSON file.
/// Throws [ConfigException] (code `E_BAD_CONFIG`) on unreadable files,
/// invalid JSON or wrong field types.
EffectConfig effectConfigFromFile(String path) {
  try {
    final raw = File(path).readAsStringSync();
    return EffectConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } on FileSystemException catch (e) {
    throw ConfigException('Unable to read config file: ${e.message}');
  } on FormatException catch (e) {
    throw ConfigException('Config file is not valid JSON: ${e.message}');
  } on TypeError {
    throw ConfigException(
        'Invalid config field type; see docs/api.md for the parameter table');
  }
}
