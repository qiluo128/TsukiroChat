/// 工作区文件管理器。
///
/// ## 为什么这个页面不能省
///
/// AI 的工作区在**应用私有目录**里，而 Android 11+ 上系统文件管理器
/// 基本看不到 `/Android/data`。
///
/// 也就是说：**这个页面是用户看到 AI 产出的唯一入口。**
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../services/workspace_store.dart';
import '../services/workspace_versions.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key, required this.agentId, required this.agentName});

  final String agentId;
  final String agentName;

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  /// 当前所在目录（相对工作区根）。空串 = 根。
  String _dir = '';
  List<Map<String, dynamic>> _entries = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;
  WorkspaceStore? _store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<WorkspaceStore> _getStore() async {
    final cached = _store;
    if (cached != null) return cached;
    final store = await ref.read(workspaceStoreProvider.future);
    _store = store;
    return store;
  }

  String _rel(String name) => _dir.isEmpty ? name : '$_dir/$name';

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = await _getStore();
      final list = await store.list(widget.agentId, _dir);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _enter(String name) async {
    setState(() => _dir = _dir.isEmpty ? name : '$_dir/$name');
    await _reload();
  }

  Future<void> _up() async {
    if (_dir.isEmpty) return;
    final i = _dir.lastIndexOf('/');
    setState(() => _dir = i < 0 ? '' : _dir.substring(0, i));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.agentName} 的工作区'),
        actions: <Widget>[
          IconButton(
            tooltip: '最近改动',
            icon: const Icon(Icons.history),
            onPressed: _showAllHistory,
          ),
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _newFolder,
          ),
          IconButton(
            tooltip: '新建文本文件',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: _newFile,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: t.surface,
            child: Row(
              children: <Widget>[
                if (_dir.isNotEmpty)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: _up,
                  ),
                Expanded(
                  child: Text(
                    _dir.isEmpty ? '根目录' : _dir,
                    style: TextStyle(fontSize: 12, color: t.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _body(t)),
        ],
      ),
    );
  }

  Widget _body(AppTokens tokens) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.folder_off_outlined, size: 40, color: tokens.textMuted),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: tokens.textMuted)),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.inbox_outlined, size: 40, color: tokens.textMuted),
            const SizedBox(height: 10),
            Text('这个文件夹是空的',
                style: TextStyle(fontSize: 13, color: tokens.textMuted)),
            const SizedBox(height: 4),
            Text('AI 在这里建的文件会显示出来',
                style: TextStyle(fontSize: 11.5, color: tokens.textMuted)),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: tokens.divider.withValues(alpha: 0.5)),
      itemBuilder: (context, i) {
        final e = _entries[i];
        final name = e['name'] as String? ?? '';
        final isDir = e['isDirectory'] == true;
        final size = (e['size'] as int?) ?? 0;

        return ListTile(
          leading: Icon(
            isDir ? Icons.folder_outlined : Icons.description_outlined,
            color: isDir ? tokens.primary : tokens.textMuted,
            size: 22,
          ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            isDir ? '文件夹' : formatBytes(size),
            style: TextStyle(fontSize: 11.5, color: tokens.textMuted),
          ),
          // **长按出菜单**，而不是每行挂一个删除按钮。
          //
          // 一行挂一个按钮的话，点头部是"打开"、点按钮是"删掉"，
          // 两个动作贴得太近，误删风险高。
          onTap: () => isDir ? _enter(name) : _openFile(name),
          onLongPress: () => _showActions(name, isDir),
        );
      },
    );
  }

  /// 长按菜单。
  Future<void> _showActions(String name, bool isDir) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              dense: true,
              title: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            if (!isDir)
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: const Text('编辑'),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
            if (!isDir)
              ListTile(
                leading: const Icon(Icons.share_outlined, size: 20),
                title: const Text('分享'),
                subtitle: const Text('发到微信 / 邮件 / 其他应用',
                    style: TextStyle(fontSize: 11.5)),
                onTap: () => Navigator.pop(ctx, 'share'),
              ),
                        if (!isDir)
              ListTile(
                leading: const Icon(Icons.history, size: 20),
                title: const Text('历史版本'),
                subtitle: const Text('改错了可以退回去',
                    style: TextStyle(fontSize: 11.5)),
                onTap: () => Navigator.pop(ctx, 'history'),
              ),
if (!isDir)
              ListTile(
                leading: const Icon(Icons.open_in_new, size: 20),
                title: const Text('其他应用打开'),
                subtitle: const Text('用系统里能处理这种文件的应用打开',
                    style: TextStyle(fontSize: 11.5)),
                onTap: () => Navigator.pop(ctx, 'open_with'),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline, size: 20),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline, size: 20),
              title: const Text('移动'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, size: 20),
              title: const Text('删除'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'edit':
        await _openFile(name);
      case 'open_with':
        await _openWith(name);
      case 'history':
        await _showHistory(name);
      case 'share':
        await _share(name);
      case 'rename':
        await _rename(name);
      case 'move':
        await _move(name, isDir: isDir);
      case 'delete':
        await _delete(name, isDir);
    }
  }

  Future<void> _openFile(String name) async {
    try {
      final store = await _getStore();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WorkspaceFilePage(
            agentId: widget.agentId,
            relativePath: _rel(name),
            fileName: name,
            store: store,
          ),
        ),
      );
      // 编辑页可能改了内容，回来刷新大小
      if (mounted) await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('打不开：$e'),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  Future<void> _rename(String name) async {
    final next = await _askName('重命名', initial: name);
    if (next == null || next == name) return;
    try {
      final store = await _getStore();
      final text = await store.readText(widget.agentId, _rel(name));
      await store.writeText(widget.agentId, _rel(next), text);
      await store.delete(widget.agentId, _rel(name));
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
  }

  /// 移动到另一个文件夹。
  ///
  /// **不再手打路径。** 原来弹输入框让人填「相对路径」，
  /// 等于要用户心算目录结构，而且打错了只会得到「移动失败」。
  /// 现在打开目录选择器：点进去、点「移到这里」。
  Future<void> _move(String name, {bool isDir = false}) async {
    final store = await _getStore();
    if (!mounted) return;

    final source = _rel(name);
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _FolderPicker(
        store: store,
        agentId: widget.agentId,
        title: '移动「$name」到…',
        blockedPaths: <String>{_dir},
        // 文件夹不能移到自己内部 —— 那会把自己的父目录挪走
        forbidInside: isDir ? source : null,
      ),
    );
    if (target == null || !mounted) return;

    final dest = target.isEmpty ? name : '$target/$name';
    if (dest == source) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('已经在这个文件夹里了'), duration: Duration(seconds: 1)),
      );
      return;
    }

    try {
      final text = await store.readText(widget.agentId, source);
      await store.writeText(widget.agentId, dest, text);
      await store.delete(widget.agentId, source);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已移动到 ${target.isEmpty ? '根目录' : target}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('移动失败：$e')));
    }
  }

/// 分享一个文件到系统分享面板。
  ///
  /// 用 share_plus 而不是自己做 Intent：应用私有目录的文件要发给别的
  /// 应用，必须过一个 FileProvider，而且各家的 provider authority 不同。
  /// 自己拼 Intent 会在部分厂商 ROM 上直接崩。
  /// 全部文件的历史（跨文件的时间线）。
  ///
  /// 和「按文件看历史」不同，这个回答的是另一个问题：
  /// **AI 刚才动了什么？**
  ///
  /// 用户发现文件不对时，往往不知道是哪个文件、什么时候变的。
  /// 单个文件的历史帮不上这个忙 —— 需要一条跨文件的时间线。
  Future<void> _showAllHistory() async {
    final store = await _getStore();
    List<VersionEntry> entries;
    try {
      entries = await store.versionsFor(widget.agentId).allHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读不到历史：$e')));
      return;
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<VersionEntry>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final t2 = ctx.tokens;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.75,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text('最近改动',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Text(
                            '还没有任何历史\n（文件被改过之后才会出现在这里）',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12.5, color: t2.textMuted),
                          ),
                        )
                      : ListView.separated(
                          itemCount: entries.length,
                          separatorBuilder: (_, _) => Divider(
                              height: 1,
                              color: t2.divider.withValues(alpha: 0.5)),
                          itemBuilder: (_, i) {
                            final e = entries[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.history, size: 20),
                              title: Text(
                                e.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${_fmtTime(e.at)} · ${e.source} · '
                                '${formatBytes(e.bytes)}',
                                style: TextStyle(
                                    fontSize: 11.5, color: t2.textMuted),
                              ),
                              onTap: () => Navigator.pop(ctx, e),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('回到这个版本？'),
        content: Text(
          '「${picked.path}」会被替换成 ${_fmtTime(picked.at)} 的内容。\n\n'
          '当前内容也会留一份历史，所以这次操作本身也能撤销。',
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await store.restore(widget.agentId, picked.path, picked.sha);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已恢复 ${picked.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('恢复失败：$e')));
    }
  }

  /// 看这个文件的历史版本，并可以回滚。
  ///
  /// 每次写文件都会留一份快照（内容寻址，同样的内容只存一份）。
  /// 这个入口是「改错了能退回去」真正可用的地方 ——
  /// 服务层有了但没入口，等于没有。
  Future<void> _showHistory(String name) async {
    final store = await _getStore();
    final rel = _rel(name);
    List<VersionEntry> entries;
    try {
      entries = await store.versionsFor(widget.agentId).history(rel);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读不到历史：$e')));
      return;
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<VersionEntry>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final t2 = ctx.tokens;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '「$name」的历史',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Text(
                            '还没有历史（这个文件还没被改过）',
                            style: TextStyle(
                                fontSize: 12.5, color: t2.textMuted),
                          ),
                        )
                      : ListView.separated(
                          itemCount: entries.length,
                          separatorBuilder: (_, _) => Divider(
                              height: 1,
                              color: t2.divider.withValues(alpha: 0.5)),
                          itemBuilder: (_, i) {
                            final e = entries[i];
                            final isLatest = i == 0;
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                isLatest
                                    ? Icons.check_circle_outline
                                    : Icons.history,
                                size: 20,
                                color:
                                    isLatest ? t2.primary : t2.textMuted,
                              ),
                              title: Text(
                                _fmtTime(e.at) + (isLatest ? '（当前）' : ''),
                              ),
                              subtitle: Text(
                                '${e.source} · ${formatBytes(e.bytes)}',
                                style: TextStyle(
                                    fontSize: 11.5, color: t2.textMuted),
                              ),
                              trailing: isLatest
                                  ? null
                                  : const Icon(Icons.restore, size: 18),
                              onTap: isLatest
                                  ? null
                                  : () => Navigator.pop(ctx, e),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('回到这个版本？'),
        content: Text(
          '「$name」会被替换成 ${_fmtTime(picked.at)} 的内容。\n\n'
          '当前内容也会留一份历史，所以这次操作本身也能撤销。',
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await store.restore(widget.agentId, rel, picked.sha);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已恢复到该版本')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('恢复失败：$e')));
    }
  }

  String _fmtTime(DateTime at) {
    final l = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// 用系统里能处理这种文件的应用打开。
  ///
  /// 和「分享」的区别是语义：
  ///   分享        = 把这个文件交给别的应用或人（通常有接收方）
  ///   其他应用打开 = 我不想在应用内看，用编辑器/看图器打开它
  ///
  /// 行为上确实重叠（系统面板里也可能选到应用），但用户想"编辑这个
  /// txt"时会去找「打开」而不是「分享」。
  Future<void> _openWith(String name) async {
    try {
      final store = await _getStore();
      final absolute = store.resolve(widget.agentId, _rel(name));
      final result = await OpenFilex.open(absolute);
      if (result.type == ResultType.done) return;
      if (!mounted) return;
      // 失败也要说清楚是哪种失败 —— "打开失败"对谁都没用
      final reason = switch (result.type) {
        ResultType.noAppToOpen => '系统里没有能打开这种文件的应用',
        ResultType.permissionDenied => '系统拒绝了访问这个文件的权限',
        ResultType.fileNotFound => '文件不存在（可能刚被删除）',
        _ => result.message,
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reason),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开失败：$e')));
    }
  }
  Future<void> _share(String name) async {
    try {
      final store = await _getStore();
      final absolute = store.resolve(widget.agentId, _rel(name));
      if (!mounted) return;
      // sharePositionOrigin 在 iPad 上是必需的（否则崩），
      // 在 Android 上被忽略 —— 顺手给上没坏处。
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await Share.shareXFiles(
        <XFile>[XFile(absolute)],
        subject: name,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('分享失败：$e')));
    }
  }

  Future<void> _delete(String name, bool isDir) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? '删除文件夹' : '删除文件'),
        content: Text(isDir
            ? '「$name」及其中的所有内容会被永久删除。'
            : '「$name」会被永久删除。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final store = await _getStore();
      await store.delete(widget.agentId, _rel(name), recursive: true);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  Future<void> _newFolder() async {
    final name = await _askName('新建文件夹');
    if (name == null) return;
    try {
      final store = await _getStore();
      await store.createDir(widget.agentId, _rel(name));
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建失败：$e')));
    }
  }

  Future<void> _newFile() async {
    final name = await _askName('新建文件', hint: 'notes.txt');
    if (name == null) return;
    try {
      final store = await _getStore();
      await store.writeText(widget.agentId, _rel(name), '');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建失败：$e')));
    }
  }

  Future<String?> _askName(String title, {String? initial, String? hint}) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint ?? '名字'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

/// 目录选择器。
///
/// 只显示文件夹（选文件没有意义）。点进去可以继续下钻，
/// 底部固定「移到这里」。
class _FolderPicker extends StatefulWidget {
  const _FolderPicker({
    required this.store,
    required this.agentId,
    required this.title,
    this.blockedPaths = const <String>{},
    this.forbidInside,
  });

  final WorkspaceStore store;
  final String agentId;
  final String title;

  /// 不允许选的目录（比如文件当前所在的目录）
  final Set<String> blockedPaths;

  /// 不允许进入的目录树（移动文件夹时，不能移进自己）
  final String? forbidInside;

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  String _dir = '';
  List<String> _dirs = <String>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final entries = await widget.store.list(widget.agentId, _dir);
      if (!mounted) return;
      setState(() {
        _dirs = entries
            .where((e) => e['isDirectory'] == true)
            .map((e) => e['name'] as String)
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dirs = <String>[];
        _loading = false;
      });
    }
  }

  Future<void> _enter(String name) async {
    setState(() => _dir = _dir.isEmpty ? name : '$_dir/$name');
    await _load();
  }

  void _up() {
    if (_dir.isEmpty) return;
    final i = _dir.lastIndexOf('/');
    setState(() => _dir = i < 0 ? '' : _dir.substring(0, i));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final insideForbidden = widget.forbidInside != null &&
        (_dir == widget.forbidInside ||
            _dir.startsWith('${widget.forbidInside!}/'));
    final canPick = !widget.blockedPaths.contains(_dir) && !insideForbidden;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(widget.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              color: t.surface,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: <Widget>[
                  if (_dir.isNotEmpty)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      onPressed: _up,
                    ),
                  Expanded(
                    child: Text(_dir.isEmpty ? '根目录' : _dir,
                        style: TextStyle(fontSize: 12, color: t.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _dirs.isEmpty
                      ? Center(
                          child: Text('这里没有子文件夹',
                              style: TextStyle(
                                  fontSize: 12.5, color: t.textMuted)),
                        )
                      : ListView(
                          children: <Widget>[
                            for (final d in _dirs)
                              ListTile(
                                dense: true,
                                leading: Icon(Icons.folder_outlined,
                                    size: 20, color: t.primary),
                                title: Text(d,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                trailing:
                                    const Icon(Icons.chevron_right, size: 18),
                                onTap: () => _enter(d),
                              ),
                          ],
                        ),
            ),
            if (insideForbidden)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('不能把文件夹移到它自己里面',
                    style: TextStyle(fontSize: 11.5, color: t.danger)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      canPick ? () => Navigator.pop(context, _dir) : null,
                  icon: const Icon(Icons.drive_file_move_outline, size: 18),
                  label: Text(
                      _dir.isEmpty ? '移到这里（根目录）' : '移到这里'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件查看 / 编辑页。
///
/// **原来是弹对话框。** 改成整页的理由：
///
///   - 对话框里只看得见几行，长文本只能滚着看
///   - 对话框不能编辑 —— 想改一个字得让 AI 改
///   - 键盘弹起来会顶掉对话框的一半
class WorkspaceFilePage extends StatefulWidget {
  const WorkspaceFilePage({
    super.key,
    required this.agentId,
    required this.relativePath,
    required this.fileName,
    required this.store,
  });

  final String agentId;
  final String relativePath;
  final String fileName;
  final WorkspaceStore store;

  @override
  State<WorkspaceFilePage> createState() => _WorkspaceFilePageState();
}

class _WorkspaceFilePageState extends State<WorkspaceFilePage> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _dirty = false;
  String? _error;
  String _original = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text =
          await widget.store.readText(widget.agentId, widget.relativePath);
      if (!mounted) return;
      setState(() {
        _original = text;
        _controller.text = text;
        _loading = false;
        _dirty = false;
      });
    } catch (e) {
      if (!mounted) return;
      // 二进制文件读不成 utf8 —— 说清楚，而不是弹乱码
      setState(() {
        _error = '这个文件没法当文本打开（可能是图片或压缩包）\n\n$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    try {
      await widget.store
          .writeText(widget.agentId, widget.relativePath, _controller.text);
      if (!mounted) return;
      setState(() {
        _original = _controller.text;
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fileName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          if (_dirty)
            IconButton(
              tooltip: '撤销修改',
              icon: const Icon(Icons.undo),
              onPressed: () => setState(() {
                _controller.text = _original;
                _dirty = false;
              }),
            ),
          IconButton(
            tooltip: '保存',
            icon: Icon(Icons.save_outlined, color: _dirty ? t.primary : null),
            onPressed: _loading || _error != null ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: t.textMuted)),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.45,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '空文件',
                    ),
                    onChanged: (v) {
                      final dirty = v != _original;
                      if (dirty != _dirty) setState(() => _dirty = dirty);
                    },
                  ),
                ),
    );
  }
}
