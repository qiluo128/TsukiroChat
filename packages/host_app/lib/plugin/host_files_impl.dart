/// `HostFiles` 与 `SandboxProvider` 的宿主实现。
///
/// ## 分工（重要）
///
/// 这里**不做任何路径合法性检查**。
///
/// 路径由原语的守门人（`SandboxPathGuard`）负责，这里只负责"照着绝对路径
/// 执行 IO"。如果这里也检查一次，两处规则一旦不一致就是一个洞 ——
/// 而且那种洞极难发现，因为两边单独看都是"对的"。
///
/// 所以这个类只能被**已经过守卫的绝对路径**调用。
library;

import 'dart:io';

import 'package:plugin_core/plugin_core.dart';

class AppHostFiles implements HostFiles {
  const AppHostFiles();

  @override
  Future<String> readText(String absolutePath) => File(absolutePath).readAsString();

  @override
  Future<List<int>> readBytes(String absolutePath) => File(absolutePath).readAsBytes();

  @override
  Future<void> writeText(String absolutePath, String text, {bool append = false}) async {
    await _ensureParent(absolutePath);
    final f = File(absolutePath);
    if (append && await f.exists()) {
      await f.writeAsString(text, mode: FileMode.append, flush: true);
    } else {
      await f.writeAsString(text, flush: true);
    }
  }

  @override
  Future<void> writeBytes(String absolutePath, List<int> bytes, {bool append = false}) async {
    await _ensureParent(absolutePath);
    final f = File(absolutePath);
    if (append && await f.exists()) {
      await f.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    } else {
      await f.writeAsBytes(bytes, flush: true);
    }
  }

  @override
  Future<bool> exists(String absolutePath) async =>
      FileSystemEntity.isFileSync(absolutePath) ||
      FileSystemEntity.isDirectorySync(absolutePath);

  @override
  Future<int> size(String absolutePath) => File(absolutePath).length();

  @override
  Future<void> delete(String absolutePath, {bool recursive = false}) async {
    final type = FileSystemEntity.typeSync(absolutePath);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      await Directory(absolutePath).delete(recursive: recursive);
    } else {
      await File(absolutePath).delete();
    }
  }

  @override
  Future<List<Map<String, dynamic>>> list(String absoluteDirectory,
      {bool recursive = false}) async {
    final dir = Directory(absoluteDirectory);
    if (!dir.existsSync()) return <Map<String, dynamic>>[];

    final out = <Map<String, dynamic>>[];
    await for (final e in dir.list(recursive: recursive, followLinks: false)) {
      // 相对路径用 / 分隔，交给界面/插件时不必关心平台
      final rel = e.path.substring(absoluteDirectory.length).replaceAll(r'\', '/');
      final stripped = rel.startsWith('/') ? rel.substring(1) : rel;
      out.add(<String, dynamic>{
        'name': e.path.split(Platform.pathSeparator).last,
        'path': stripped,
        'isDirectory': e is Directory,
        'size': e is File ? await e.length() : 0,
        'modified': (await e.stat()).modified.toIso8601String(),
      });
    }
    // 目录在前、同类按名字排 —— 文件管理器里这是最省心的顺序
    out.sort((a, b) {
      final ad = a['isDirectory'] == true ? 0 : 1;
      final bd = b['isDirectory'] == true ? 0 : 1;
      if (ad != bd) return ad - bd;
      return (a['name'] as String).toLowerCase().compareTo(
            (b['name'] as String).toLowerCase(),
          );
    });
    return out;
  }

  Future<void> _ensureParent(String absolutePath) async {
    final parent = File(absolutePath).parent;
    if (!parent.existsSync()) await parent.create(recursive: true);
  }
}

/// 插件沙箱根目录。
///
/// **它和 AI 的工作区是两回事**：
///
/// ```
/// 插件沙箱   <app>/plugins/<id>/data/      第三方代码，用户看不到
/// AI 工作区  <app>/workspaces/<agentId>/   用户可见，AI 干活的地方
/// ```
///
/// 插件读不到 AI 工作区，这是刻意的：插件是第三方，
/// 而工作区里可能有 AI 帮用户整理的个人文件。
///
/// 让插件能读这些，等于把"装一个插件"重新变成"交出文件"。
class AppSandboxProvider implements SandboxProvider {
  AppSandboxProvider([this.pluginRoot]);

  /// **晚绑定**：宿主在 initialize() 里才知道根目录，
  /// 而服务是在宿主构造之前就注册好的，两者的时机对不上。
  /// 所以这里留一个可写字段，宿主初始化后填进来。
  String? pluginRoot;

  @override
  String? dataRootFor(String pluginId) {
    final root = pluginRoot;
    if (root == null) return null;
    final dir = Directory('$root/$pluginId/data');
    if (!dir.existsSync()) return null;
    return dir.path;
  }
}
