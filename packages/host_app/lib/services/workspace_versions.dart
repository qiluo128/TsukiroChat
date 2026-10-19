/// 工作区的版本快照。
///
/// ## 为什么不是 git
///
/// 没有命令执行，用不了 git。但真正需要的其实只有一件事：
/// **改错了能退回去。**
///
/// git 的分支/合并/远程在这个场景里都没有意义 ——
/// AI 的写入是单线程逐次的，工作区是单用户的。所以这里实现
/// git 的**最小可用子集**：
///
/// ```
/// .tsukiro/objects/<aa>/<sha256>   内容寻址（同样的内容只存一份）
/// .tsukiro/index.jsonl             每次写入记一行
/// ```
///
/// ## 为什么内容寻址
///
/// 不去重的话，每改一次就存一份完整副本 —— 一个 10MB 的日志文件
/// 改 20 次就是 200MB。而内容寻址后，**只改一行的两次快照共享
/// 绝大部分存储**（实际上是完全共享前一份，只有新内容占空间）。
///
/// 这也顺带解决了「同一个内容存多次」的问题：sha 相同就不写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class VersionEntry {
  const VersionEntry({
    required this.path,
    required this.at,
    required this.sha,
    required this.bytes,
    required this.source,
  });

  /// 相对工作区根的路径。
  final String path;
  final DateTime at;
  final String sha;
  final int bytes;

  /// 这条版本是谁造成的（`write` / `edit` / `restore` / `user`）。
  ///
  /// 记下来是为了回答「这一版是 AI 改的还是我改的」——
  /// 排查"我没动它怎么变了"的时候这是第一手信息。
  final String source;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'at': at.toIso8601String(),
        'sha': sha,
        'bytes': bytes,
        'source': source,
      };

  static VersionEntry? fromJson(Map<String, dynamic> j) {
    final path = j['path'];
    final sha = j['sha'];
    final at = DateTime.tryParse(j['at']?.toString() ?? '');
    if (path is! String || sha is! String || at == null) return null;
    return VersionEntry(
      path: path,
      at: at,
      sha: sha,
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      source: j['source'] as String? ?? 'unknown',
    );
  }
}

class WorkspaceVersions {
  WorkspaceVersions(this.metaRoot);

  /// `<workspace>/.tsukiro`
  final String metaRoot;

  /// 索引最多保留多少行。超过就整体重写、只留最近的。
  ///
  /// 不做精确的按文件淘汰：那需要按文件统计，而这里的目的是
  /// **别让索引无限长**，粗一点没关系。
  static const int maxIndexEntries = 5000;

  String get _objectsRoot => p.join(metaRoot, 'objects');
  String get _indexPath => p.join(metaRoot, 'index.jsonl');

  /// 存一份内容，返回 sha256。
  ///
  /// 已存在就不写（内容寻址天然去重）。
  Future<String> putBlob(List<int> bytes) async {
    final sha = sha256.convert(bytes).toString();
    final file = File(_blobPath(sha));
    if (file.existsSync()) return sha;
    await file.parent.create(recursive: true);
    // 先写临时文件再改名 —— 半途被杀掉不会留下一个坏 blob
    // 而它的 sha 已经被人引用，那会让"能恢复"变成"恢复出损坏内容"
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return sha;
  }

  Future<List<int>?> getBlob(String sha) async {
    final file = File(_blobPath(sha));
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  /// 记录一条版本。**调用方负责先把内容 putBlob**。
  Future<void> record(
    String relPath,
    String sha, {
    required int bytes,
    String source = 'write',
  }) async {
    final entry = VersionEntry(
      path: relPath,
      at: DateTime.now(),
      sha: sha,
      bytes: bytes,
      source: source,
    );
    final dir = Directory(metaRoot);
    if (!dir.existsSync()) await dir.create(recursive: true);
    await File(_indexPath)
        .writeAsString('${jsonEncode(entry.toJson())}\n', mode: FileMode.append, flush: true);
  }

  /// 某个文件的历史，**新的在前**。
  Future<List<VersionEntry>> history(String relPath) async {
    final all = await _readIndex();
    final mine = all.where((e) => e.path == relPath).toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return mine;
  }

  /// 全部历史（新的在前）。
  Future<List<VersionEntry>> allHistory() async {
    final all = await _readIndex();
    return all..sort((a, b) => b.at.compareTo(a.at));
  }

  /// 索引行数超限时裁掉旧的。
  ///
  /// 返回被裁掉的行数，方便调用方记日志。
  Future<int> pruneIndex() async {
    final all = await _readIndex();
    if (all.length <= maxIndexEntries) return 0;

    all.sort((a, b) => a.at.compareTo(b.at));
    final keep = all.sublist(all.length - maxIndexEntries);
    final removed = all.length - keep.length;

    final buffer = StringBuffer();
    for (final e in keep) {
      buffer.writeln(jsonEncode(e.toJson()));
    }
    // 整体重写：先写临时文件再改名，避免裁剪过程中被杀掉留下半个索引
    final tmp = File('$_indexPath.tmp');
    await tmp.writeAsString(buffer.toString(), flush: true);
    await tmp.rename(_indexPath);
    return removed;
  }

  /// 这个 sha 当前还被几个文件引用。
  ///
  /// 用来判断 blob 能不能删（引用计数为 0 才算孤儿）。
  Future<int> refCount(String sha) async {
    final all = await _readIndex();
    return all.where((e) => e.sha == sha).length;
  }

  Future<List<VersionEntry>> _readIndex() async {
    final file = File(_indexPath);
    if (!file.existsSync()) return <VersionEntry>[];
    final out = <VersionEntry>[];
    // 逐行解析并**跳过坏行**：索引是追加写的，进程被杀可能留下半行。
    // 一行坏掉不该让整个历史不可读。
    for (final line in await file.readAsLines()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final j = jsonDecode(trimmed);
        if (j is Map<String, dynamic>) {
          final e = VersionEntry.fromJson(j);
          if (e != null) out.add(e);
        }
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  String _blobPath(String sha) {
    // 两级目录（git 的做法）：避免单个目录里堆上万文件，
    // 某些文件系统上那会明显变慢
    final prefix = sha.length >= 2 ? sha.substring(0, 2) : 'xx';
    return p.join(_objectsRoot, prefix, sha);
  }
}
