/// zip 解析适配层 —— 把真实 zip 交给 [PackageInspector] 的纯逻辑检查。
///
/// 分工：
///   - `package_inspector.dart` 只认 [PackageEntry] 列表，包含全部安全规则
///   - 本文件负责把 zip 字节流拆成条目，并只把**通过检查**的文件读进内存
///
/// 这样安全规则的测试不依赖 zip 库，而 zip 库升级也不会悄悄改变安全策略。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../common/errors.dart';
import 'package_inspector.dart';

/// 已解析并检查过的插件包。
class PluginArchive {
  PluginArchive(this.inspection, Map<String, Uint8List> contents)
      : _contents = contents;

  final PackageInspection inspection;
  final Map<String, Uint8List> _contents;

  /// 插件根下所有可读文件的相对路径。
  Iterable<String> get paths => _contents.keys;

  /// 读取文件原始字节；不存在返回 null。
  Uint8List? readBytes(String relativePath) =>
      _contents[_normalize(relativePath)];

  /// 读取文本文件（UTF-8）。
  String? readText(String relativePath) {
    final bytes = readBytes(relativePath);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 读取并解析 JSON 文件。不是合法 JSON 时抛 [TsukiroException]。
  Map<String, dynamic>? readJson(String relativePath) {
    final text = readText(relativePath);
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      throw TsukiroException(
        TsukiroErrorCode.invalidManifest,
        '$relativePath 的顶层必须是 JSON 对象',
      );
    } on FormatException catch (e) {
      throw TsukiroException(
        TsukiroErrorCode.invalidManifest,
        '$relativePath 不是合法 JSON: ${e.message}',
      );
    }
  }

  static String _normalize(String p) => p.replaceAll('\\', '/');
}

/// zip 读取器。
class ZipReader {
  const ZipReader({this.inspector = const PackageInspector()});

  final PackageInspector inspector;

  /// 解析 zip 字节流。
  ///
  /// 不是合法 zip 时抛 `INVALID_PACKAGE`。
  /// **注意：即使返回了对象，也必须先看 [PluginArchive.inspection] 的 `isSafe`。**
  PluginArchive read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    } catch (e) {
      throw TsukiroException(
        TsukiroErrorCode.invalidPackage,
        '不是合法的 zip 文件: $e',
      );
    }

    // ── 1. 转成与 zip 库无关的条目列表 ──
    final entries = <PackageEntry>[];
    for (final file in archive.files) {
      entries.add(PackageEntry(
        path: file.name,
        size: file.size,
        isDirectory: !file.isFile,
        isSymlink: _isSymlink(file),
        mode: file.mode,
      ));
    }

    // ── 2. 跑安全与结构检查 ──
    final inspection = inspector.inspect(entries, archiveByteSize: bytes.length);

    // ── 3. 只读入通过检查的文件 ──
    //    关键：有致命问题时也**不把可疑内容读进内存**，避免在报错路径上
    //    反而把恶意内容加载起来。
    final contents = <String, Uint8List>{};
    if (inspection.manifestPath != null) {
      final prefix = inspection.pluginRootPrefix;
      final blocked = inspection.fatalIssues
          .map((i) => i.path)
          .where((p) => p != '<package>')
          .toSet();

      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (PackageInspector.pathProblem(file.name) != null) continue;
        if (blocked.contains(file.name)) continue;

        final rel = PackageInspector.relativize(file.name, prefix);
        if (rel == null || rel.isEmpty) continue;

        final data = _contentOf(file);
        if (data != null) contents[rel] = data;
      }
    }

    return PluginArchive(inspection, contents);
  }
}

/// Unix mode 的高 4 位为 0xA 表示符号链接。
bool _isSymlink(ArchiveFile file) => (file.mode & 0xF000) == 0xA000;

/// 取文件内容。archive 3.x 的 `content` 可能是 `Uint8List` 或 `InputStream`。
Uint8List? _contentOf(ArchiveFile file) {
  final content = file.content;
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  return null;
}
