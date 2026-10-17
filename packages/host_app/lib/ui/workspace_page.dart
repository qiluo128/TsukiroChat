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

import '../services/workspace_store.dart';
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
      case 'rename':
        await _rename(name);
      case 'move':
        await _move(name);
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

  Future<void> _move(String name) async {
    final target = await _askName(
      '移动到哪个文件夹',
      initial: _dir,
      hint: '相对工作区根，留空表示根目录',
    );
    if (target == null) return;
    final dest = target.isEmpty ? name : '$target/$name';
    try {
      final store = await _getStore();
      // 先确保目标目录存在，否则写文件会在错的地方建
      if (target.isNotEmpty) await store.createDir(widget.agentId, target);
      final text = await store.readText(widget.agentId, _rel(name));
      await store.writeText(widget.agentId, dest, text);
      await store.delete(widget.agentId, _rel(name));
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('移动失败：$e')));
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
