/// 工作区文件管理器。
///
/// ## 为什么这个页面不能省
///
/// AI 的工作区在**应用私有目录**里，而 Android 11+ 上系统文件管理器
/// 基本看不到 `/Android/data`。
///
/// 也就是说：**这个页面是用户看到 AI 产出的唯一入口。**
/// 没有它，AI 在工作区里写了一堆文件，用户永远不知道。
///
/// 所以它不是"锦上添花的调试工具"，是工作区这个功能成立的前提。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/workspace_store.dart';
import '../../theme/app_theme.dart';
import '../../theme/design_tokens.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = await ref.read(workspaceStoreProvider.future);
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

  WorkspaceStore? _store;

  Future<WorkspaceStore> _getStore() async {
    final cached = _store;
    if (cached != null) return cached;
// 赋值表达式的类型是变量的声明类型（WorkspaceStore?），
    // 所以不能直接 return 它 —— 先落到局部变量再分别处理。
    final store = await ref.read(workspaceStoreProvider.future);
    _store = store;
    return store;
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
    final crumbs = _dir.isEmpty ? '根目录' : _dir;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.agentName} 的工作区'),
        actions: <Widget>[
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                    crumbs,
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
              Text(_error!, textAlign: TextAlign.center,
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
      separatorBuilder: (_, _) => Divider(height: 1, color: tokens.divider.withValues(alpha: 0.5)),
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
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => _delete(name, isDir),
          ),
          onTap: () => isDir ? _enter(name) : _preview(name),
        );
      },
    );
  }

  Future<void> _preview(String name) async {
    final rel = _dir.isEmpty ? name : '$_dir/$name';
    try {
      final store = await _getStore();
      final text = await store.readText(widget.agentId, rel);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(text, style: const TextStyle(fontSize: 13)),
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    } catch (e) {
      // 二进制文件读不成 utf8 —— 说清楚，而不是弹一堆乱码或崩掉
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('这个文件没法当文本打开（可能是图片或压缩包）：$e'),
        duration: const Duration(seconds: 3),
      ));
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final rel = _dir.isEmpty ? name : '$_dir/$name';
    try {
      final store = await _getStore();
      await store.delete(widget.agentId, rel, recursive: true);
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
    final rel = _dir.isEmpty ? name : '$_dir/$name';
    try {
      final store = await _getStore();
      await store.createDir(widget.agentId, rel);
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
    final rel = _dir.isEmpty ? name : '$_dir/$name';
    try {
      final store = await _getStore();
      await store.writeText(widget.agentId, rel, '');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建失败：$e')));
    }
  }

  Future<String?> _askName(String title, {String? hint}) async {
    final controller = TextEditingController();
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
    return (result == null || result.isEmpty) ? null : result;
  }
}
