/// 测试用的 zip 构造工具。
///
/// 这是 `plugin_core/test/support/zip_builder.dart` 的精简副本。
/// 之所以复制而不是共享：跨包的 `test/` 目录无法互相 import，
/// 而把测试辅助提到 `lib/` 会污染生产库的 API 面。
/// 40 行的重复比"为了复用而扩大公开 API"更划算。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 仓库根目录（测试工作目录是包根：packages/model_gateway）。
final String repoRoot = p.normalize(p.join(Directory.current.path, '..', '..'));

/// 把磁盘上的插件目录打成 zip。
Uint8List zipDirectory(String pluginName) {
  final dir = Directory(p.join(repoRoot, 'plugins', pluginName));
  if (!dir.existsSync()) {
    throw StateError('找不到插件目录: ${dir.path}（cwd=${Directory.current.path}）');
  }
  final archive = Archive();
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final rel = p.relative(entity.path, from: dir.path).replaceAll(p.separator, '/');
    final bytes = entity.readAsBytesSync();
    archive.addFile(ArchiveFile(rel, bytes.length, bytes));
  }
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw StateError('ZipEncoder 返回 null');
  return Uint8List.fromList(encoded);
}

/// 在内存里造一个 zip。
Uint8List buildZip(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw StateError('ZipEncoder 返回 null');
  return Uint8List.fromList(encoded);
}
