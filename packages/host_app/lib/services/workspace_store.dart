/// AI 的工作区。
///
/// ## 它和插件沙箱是两回事
///
/// ```
/// <app>/plugins/<id>/data/        插件沙箱，第三方代码，用户看不到
/// <app>/workspaces/<agentId>/     AI 工作区，用户可见
/// ```
///
/// **一个智能体只有一个根工作区**，里面是普通子文件夹。
/// 这是刻意的：一个智能体是一个个体，它只有一套"我的手边"。
///
/// ## 为什么没有元数据表
///
/// 工作区里全是普通目录和文件 —— AI 执行 `mkdir` 就多一个文件夹，
/// 删掉就少一个。宿主不需要记"有哪些工作区"，因为唯一的那个是
/// 由 agentId 推导出来的。
///
/// 将来要挂载外部文件夹时，**挂载本身**需要一张表（否则重启后
/// 不知道那个子目录指向哪里），但工作区本身仍然不需要。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:plugin_core/plugin_core.dart';

import '../plugin/host_files_impl.dart';
import 'package:crypto/crypto.dart';

import 'workspace_versions.dart';

class WorkspaceStore {
  WorkspaceStore._(this.root) : _files = const AppHostFiles();

  /// 测试用：指定根目录，不走 path_provider。
  ///
  /// 生产路径依赖 `getApplicationDocumentsDirectory()`，
  /// 而那是平台通道，单测里没有。
  @visibleForTesting
  WorkspaceStore.testAt(String root) : root = root, _files = const AppHostFiles();

  /// 写入计数器。每 200 次裁剪一次索引 ——
  /// 每次写都读一遍索引是 O(n)，5000 行会明显拖慢保存。
  static int _writeCounter = 0;

  /// `<app>/workspaces`
  final String root;
  final AppHostFiles _files;

  static WorkspaceStore? _instance;

  /// 打开（并创建根目录）。
  ///
  /// 做成单例是因为它只依赖应用文档目录，没有别的状态 ——
  /// 每次进页面重建一遍反而要重新算路径。
  static Future<WorkspaceStore> open() async {
    final existing = _instance;
    if (existing != null) return existing;

    final docs = await getApplicationDocumentsDirectory();
    final root = p.join(docs.path, 'workspaces');
    await Directory(root).create(recursive: true);
    return _instance = WorkspaceStore._(root);
  }

  /// 某个智能体的根工作区绝对路径。**不存在就创建。**
  ///
  /// 自动创建是有意的：用户第一次打开工作区不该看到一个错误，
  /// 而 AI 第一次要写文件时也不该因为"目录不存在"失败。
  String agentRoot(String agentId) {
    final dir = Directory(p.join(root, agentId));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// 把相对路径解析成绝对路径，**过守门人**。
  ///
  /// 界面里传进来的 `rel` 也可能被拼出来（比如上一级目录返回 `..`），
  /// 所以这里同样不能信它。
  String resolve(String agentId, String rel) {
    final base = agentRoot(agentId);
    if (rel.isEmpty || rel == '.') return base;
    return SandboxPathGuard(base).resolveAndVerify(rel);
  }

  Future<List<Map<String, dynamic>>> list(String agentId, String rel) =>
      _files.list(resolve(agentId, rel));

  Future<String> readText(String agentId, String rel) =>
      _files.readText(resolve(agentId, rel));

  /// 工作区里有没有这个路径。
  ///
  /// `write_file` 靠它实现"第一版不覆盖" —— 覆盖是静默且不可逆的，
  /// 而 AI 会以为"我改好了"。
  Future<bool> exists(String agentId, String rel) async {
    try {
      return await _files.exists(resolve(agentId, rel));
    } on TsukiroException {
      // 路径非法按"不存在"处理，让调用方走自己的报错
      return false;
    }
  }

  /// 某个智能体的版本库。
  ///
  /// 放在**工作区内部**（`<workspace>/<agentId>/.tsukiro`），
  /// 而不是全局一处：工作区是可独立删除的，版本历史也该跟着走。
  WorkspaceVersions versionsFor(String agentId) =>
      WorkspaceVersions(p.join(agentRoot(agentId), '.tsukiro'));

  /// 写文件，**并留一份版本**。
  ///
  /// 写成功之后把新内容存进版本库。这样：
  ///   · 历史是完整的（每个存在过的版本都有）
  ///   · 改错了能退回去
  ///   · 内容寻址保证同样的内容只存一份
  ///
  /// 快照失败**不阻止写入** —— 但也不假装成功（不记日志就当没发生），
  /// 因为"有历史"是用户会依赖的判断。
  Future<void> writeText(String agentId, String rel, String text,
      {String source = 'write'}) async {
    final abs = resolve(agentId, rel);
    await _files.writeText(abs, text);
    try {
      final bytes = utf8.encode(text);
      final versions = versionsFor(agentId);
      final sha = await versions.putBlob(bytes);
      await versions.record(rel, sha, bytes: bytes.length, source: source);
      // 每 200 次写裁剪一次索引，避免无界增长
      if (++_writeCounter % 200 == 0) await versions.pruneIndex();
    } catch (_) {
      // 快照失败不影响文件本身已经写成功这个事实
    }
  }

  /// 回到某个历史版本。
  ///
  /// 恢复本身也会产生一条新版本（source: restore）——
  /// 否则"恢复"就变成了隐形的历史删除。
  /// 回到某个历史版本。
  ///
  /// 恢复本身也会产生一条新版本（source: restore）——
  /// 否则"恢复"就变成了隐形的历史删除。
  ///
  /// ## 两道保护
  ///
  /// **① 脏检查。** 恢复是**不可逆的覆盖**。如果当前内容和版本库里
  /// 记的最新一版不一致，说明有人在我们的写入路径之外改了文件 ——
  /// 这时恢复会**静默丢弃**那些改动。所以先比对，不一致就要求 force。
  ///
  /// **② 二进制保护。** 原来用 `utf8.decode(allowMalformed: true)`，
  /// 那会把二进制内容**替换成替代字符**再写回去 —— 文件被静默损坏，
  /// 而且看起来"恢复成功了"。现在明确拒绝。
  Future<void> restore(
    String agentId,
    String rel,
    String sha, {
    bool force = false,
  }) async {
    final versions = versionsFor(agentId);
    final bytes = await versions.getBlob(sha);
    if (bytes == null) {
      throw TsukiroException(
        TsukiroErrorCode.notFound,
        '找不到这个版本的内容（可能已被清理）',
        details: <String, dynamic>{'sha': sha},
      );
    }

    // ② 二进制保护：不做 allowMalformed 的"尽力解码"
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw TsukiroException(
        TsukiroErrorCode.unsupported,
        '这个版本不是文本内容，不能按文本恢复（强转会损坏文件）',
        details: <String, dynamic>{'sha': sha},
      );
    }

    final abs = resolve(agentId, rel);

    // ① 脏检查
    if (!force && await _files.exists(abs)) {
      final history = await versions.history(rel);
      final latestKnown = history.isEmpty ? null : history.first.sha;
      if (latestKnown != null) {
        final current = await _files.readBytes(abs);
        final currentSha = sha256.convert(current).toString();
        if (currentSha != latestKnown) {
          throw TsukiroException(
            TsukiroErrorCode.dirtyWorkspace,
            '当前内容和历史记录的最新版本不一致 —— 有改动没被版本库记录。'
            '恢复会丢掉那些改动。确定要覆盖请用 force: true。',
            details: <String, dynamic>{
              'path': rel,
              'currentSha': currentSha,
              'latestKnown': latestKnown,
            },
          );
        }
      }
    }

    await _files.writeText(abs, text);
    await versions.record(rel, sha, bytes: bytes.length, source: 'restore');
  }

  Future<void> delete(String agentId, String rel, {bool recursive = false}) =>
      _files.delete(resolve(agentId, rel), recursive: recursive);

  Future<void> createDir(String agentId, String rel) async {
    final base = agentRoot(agentId);
    final abs = SandboxPathGuard(base).resolveAndVerify(rel);
    await Directory(abs).create(recursive: true);
  }

  /// 工作区占了多少字节。
  ///
  /// 界面上要显示 —— 用户有权知道 AI 在手机上占了多少空间。
  Future<int> totalBytes(String agentId) async {
    final entries = await _files.list(agentRoot(agentId), recursive: true);
    var sum = 0;
    for (final e in entries) {
      if (e['isDirectory'] != true) sum += (e['size'] as int?) ?? 0;
    }
    return sum;
  }
}

/// 工作区存储。
///
/// 用 `AsyncProvider` 是因为要等 `getApplicationDocumentsDirectory()`。
final FutureProvider<WorkspaceStore> workspaceStoreProvider =
    FutureProvider<WorkspaceStore>((ref) => WorkspaceStore.open());

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
