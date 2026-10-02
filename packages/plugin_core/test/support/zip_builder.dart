/// 测试用的 zip 构造工具。
///
/// 共享给 `zip_reader_test.dart` 与 `demo_e2e_test.dart`：
/// 前者验证包检查，后者要真的"装"一个插件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 仓库根目录（packages/plugin_core/test/support → ../../../..）
final String repoRoot =
    p.normalize(p.join(Directory.current.path, '..', '..'));

/// 在内存里造一个 zip。
///
/// [modes] 用于伪造符号链接条目（`0xA1FF`）等特殊属性。
Uint8List buildZip(
  Map<String, String> files, {
  Map<String, int> modes = const <String, int>{},
}) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    final f = ArchiveFile(name, bytes.length, bytes);
    final mode = modes[name];
    if (mode != null) f.mode = mode;
    archive.addFile(f);
  });
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw StateError('ZipEncoder 返回 null');
  return Uint8List.fromList(encoded);
}

/// 把磁盘上的插件目录打成 zip（用于真实插件的端到端测试）。
Uint8List zipDirectory(String pluginName) {
  final dir = Directory(p.join(repoRoot, 'plugins', pluginName));
  if (!dir.existsSync()) {
    throw StateError('找不到插件目录: ${dir.path}');
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

/// 读一个真实插件文件的内容（用于在测试里复现它的行为）。
String readPluginFile(String pluginName, String relPath) {
  final f = File(p.join(repoRoot, 'plugins', pluginName, relPath));
  if (!f.existsSync()) throw StateError('找不到文件: ${f.path}');
  return f.readAsStringSync();
}
