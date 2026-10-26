/// MCP 服务设置页。
///
/// ## 这个页面为什么是必需的
///
/// `McpClient` / `McpStore` / `McpService` 都实现了，但**没有任何入口
/// 能添加一个连接** —— 也就是说整条链路在界面上是死代码。
///
/// ## 关于告知
///
/// 按 `docs/25-mcp.md` §6：MCP **不做能力门禁**（我们的权限体系保护的是
/// 宿主资源，而 MCP server 碰不到）。但要在添加时说清楚一件事：
///
/// **模型调用它的工具时，会把参数发送到那个地址。**
///
/// 一次告知，不是每次确认。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/mcp_client.dart';
import '../../services/mcp_connections.dart';
import '../../theme/app_theme.dart';
import '../../theme/design_tokens.dart';

/// 预设。
///
/// **只放验证过的或官方文档明确的。** 编一个可能失效的 URL 比不放更糟 ——
/// 用户会以为是我们坏了。
class McpPreset {
  const McpPreset({
    required this.name,
    this.url,
    required this.note,
    this.docUrl,
    this.verified = false,
  });

  final String name;

  /// null = 端点需要用户自己从文档里取
  final String? url;
  final String note;
  final String? docUrl;

  /// 是否实测过 `initialize` + `tools/list`
  final bool verified;
}

const List<McpPreset> mcpPresets = <McpPreset>[
  McpPreset(
    name: '4399 开放平台（测试用）',
    url:
        'https://edge.vinkius.com/vk_preview_OF1Kjeu7X4rl6Ls5boYXlX0GCsPYgIZMPQVxqotc/mcp',
    note: '9 个工具，公开预览端点，无需鉴权',
    verified: true,
  ),
  McpPreset(
    name: '麦当劳中国 MCP',
    url: 'https://mcp.mcd.cn',
    // 实测可达（无 token 时 HTTP 403）。
    //
    // 传输是 **Streamable HTTP** —— 客户端必须同时声明
    // `application/json` 和 `text/event-stream`，我们的 client 已经支持。
    //
    // 错误响应**不是 JSON-RPC 格式**，是 `{"code","msg","data"}`，
    // 所以 401/403/429 时要靠把 body 原文带出来才看得懂。
    note: 'Streamable HTTP · 需 Bearer Token（open.mcd.cn/mcp 控制台获取）'
        ' · 每分钟 600 次上限，超限 429',
    docUrl: 'https://open.mcd.cn/mcp',
  ),
];

class McpSettingsPage extends ConsumerStatefulWidget {
  const McpSettingsPage({super.key});

  @override
  ConsumerState<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends ConsumerState<McpSettingsPage> {
  List<McpConnection> _connections = <McpConnection>[];

  /// 连接失败原因（来自 McpService）。为空表示没失败过。
  Map<String, String> _errors = <String, String>{};

  /// 每个连接实际注册的工具数（-1 = 拿不到 McpService）。
  Map<String, int> _toolCounts = <String, int>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<McpStore> _store() => ref.read(mcpStoreProvider.future);

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = await _store();
      final list = await store.load();
      // 顺便把连接失败原因取出来 —— 它只存在 McpService 的内存里
      final svc = ref.read(mcpServiceProvider).valueOrNull;
      final errs = <String, String>{};
      final counts = <String, int>{};
      if (svc != null) {
        for (final c in list) {
          final e = svc.connectErrorOf(c.id);
          if (e != null) errs[c.id] = e;
          counts[c.id] = svc.toolCountOf(c.id);
        }
      }
      if (!mounted) return;
      setState(() {
        _connections = list;
        _errors = errs;
        _toolCounts = counts;
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

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP 服务'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addConnection,
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
      body: _body(t),
    );
  }

  Widget _body(AppTokens t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.textMuted)),
        ),
      );
    }
    if (_connections.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.extension_outlined, size: 40, color: t.textMuted),
            const SizedBox(height: 10),
            Text('还没有配置 MCP 服务',
                style: TextStyle(fontSize: 13, color: t.textMuted)),
            const SizedBox(height: 4),
            Text('点右下角「添加」接入一个外部 MCP server',
                style: TextStyle(fontSize: 11.5, color: t.textMuted)),
            const SizedBox(height: 16),
            // 预设直接给出来，省得用户去翻文档
            for (final p in mcpPresets)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
                child: OutlinedButton(
                  onPressed: () => _addFromPreset(p),
                  child: Text('预设：${p.name}',
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: _connections.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: t.divider.withValues(alpha: 0.5)),
      itemBuilder: (context, i) {
        final c = _connections[i];
        return ListTile(
          leading: Icon(
            Icons.extension,
            color: c.enabled ? t.primary : t.textMuted,
            size: 22,
          ),
          title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(c.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: t.textMuted)),
              if (_errors[c.id] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '连接失败：' + _errors[c.id]!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: t.danger),
                  ),
                ),
              // **状态说清楚。** 用户看到"测试连接通过"却"AI 看不到工具"，
              // 唯一的原因是它根本没被连 —— 而界面上原来什么都不显示。
              Text(
                _stateText(c),
                style: TextStyle(
                  fontSize: 11.5,
                  color: _stateColor(c, t),
                ),
              ),
              Text(
                c.source == 'manual'
                    ? '手动添加'
                    : '来源：插件 ${c.source.replaceFirst('plugin:', '')}',
                style: TextStyle(fontSize: 11, color: t.textMuted),
              ),
            ],
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (v) => _onAction(v, c),
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'test', child: Text('测试连接')),
              PopupMenuItem<String>(value: 'toggle', child: Text('启用/停用')),
              PopupMenuItem<String>(value: 'delete', child: Text('删除')),
            ],
          ),
          onTap: () => _testConnection(c),
        );
      },
    );
  }

  String _stateText(McpConnection c) {
    if (!c.enabled) return '已停用 —— 不会注册工具';
    final n = _toolCounts[c.id];
    if (n == null) return '状态未知';
    if (n > 0) return '已连接 · $n 个工具';
    return '未连接 —— 0 个工具（点「测试连接」看错误）';
  }

  Color _stateColor(McpConnection c, AppTokens t) {
    if (!c.enabled) return t.textMuted;
    final n = _toolCounts[c.id];
    if (n != null && n > 0) return t.success;
    return t.danger;
  }

  Future<void> _onAction(String action, McpConnection c) async {
    switch (action) {
      case 'test':
        await _testConnection(c);
      case 'toggle':
        final store = await _store();
        await store.upsert(c.copyWith(enabled: !c.enabled));
        await _reload();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除这个 MCP 服务？'),
            content: Text('「${c.name}」会被移除，它的工具将不再可用。'),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('删除')),
            ],
          ),
        );
        if (ok == true) {
          final store = await _store();
          await store.remove(c.id);
          await _reload();
        }
    }
  }

  /// 测试连接：握手 + 拉工具表。
  ///
  /// **错误原文照显示，不美化。** "连接失败"对谁都没用，
  /// 而「HTTP 401」或「连接不上：Connection refused」才是能定位的那一行。
  Future<void> _testConnection(McpConnection c) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Text('正在连接…'),
      duration: Duration(seconds: 1),
    ));
    try {
      final client = McpClient(url: c.url, headers: c.headers);
      final info = await client.initialize();
      final tools = await client.listTools();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(info.name.isEmpty ? '连接成功' : info.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('版本：${info.version.isEmpty ? '(未提供)' : info.version}'),
              Text('协议：${info.protocolVersion.isEmpty ? '(未提供)' : info.protocolVersion}'),
              const SizedBox(height: 10),
              Text('工具 ${tools.length} 个：',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              for (final t in tools.take(20))
                Text('· ${t.name}',
                    style: const TextStyle(fontSize: 12.5)),
              if (tools.length > 20)
                Text('…还有 ${tools.length - 20} 个',
                    style: const TextStyle(fontSize: 12)),
            ],
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    } on McpException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('连接失败：${e.message}'), duration: const Duration(seconds: 5)),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('连接失败：$e'), duration: const Duration(seconds: 5)),
      );
    }
  }

  Future<void> _addFromPreset(McpPreset p) async {
    if (p.url == null) {
      // 端点未知的预设：把文档地址给用户，让他自己取
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(p.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(p.note),
              const SizedBox(height: 10),
              if (p.docUrl != null)
                SelectableText(p.docUrl!,
                    style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 10),
              const Text(
                '拿到端点后用「添加」填进来。\n\n'
                '这里没有预填 URL 是刻意的：编一个可能失效的地址，'
                '你会以为是我们坏了。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
      return;
    }
    await _showAddDialog(
      initialName: p.name,
      initialUrl: p.url,
      note: p.note,
      verified: p.verified,
    );
  }

  Future<void> _addConnection() => _showAddDialog();

  Future<void> _showAddDialog({
    String? initialName,
    String? initialUrl,
    String? note,
    bool verified = false,
  }) async {
    final nameCtl = TextEditingController(text: initialName ?? '');
    final urlCtl = TextEditingController(text: initialUrl ?? '');
    final headerCtl = TextEditingController();

    final result = await showDialog<McpConnection>(
      context: context,
      builder: (ctx) {
        final t = ctx.tokens;
        return AlertDialog(
          title: const Text('添加 MCP 服务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlCtl,
                  decoration: const InputDecoration(
                    labelText: 'MCP 端点',
                    hintText: 'https://…/mcp',
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: headerCtl,
                  decoration: const InputDecoration(
                    labelText: '鉴权头（可选）',
                    hintText: 'Authorization: Bearer xxx',
                  ),
                  autocorrect: false,
                ),
                if (note != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(note,
                      style: TextStyle(fontSize: 11.5, color: t.textMuted)),
                ],
                if (verified) ...<Widget>[
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Icon(Icons.check_circle_outline,
                          size: 14, color: t.success),
                      const SizedBox(width: 4),
                      Text('这个端点已实测可用',
                          style: TextStyle(fontSize: 11.5, color: t.success)),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: t.danger.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.warning_amber_outlined,
                          size: 16, color: t.danger),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '模型调用这个服务的工具时，会把参数发送到上面的地址。'
                          '请确认你信任它。',
                          style: TextStyle(fontSize: 11.5, color: t.text),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: () {
                final name = nameCtl.text.trim();
                final url = urlCtl.text.trim();
                if (url.isEmpty) return;
                // 头只有一行，格式 `Key: Value`。不解析成多行是对的 ——
                // 多行鉴权头的场景极少，而多行输入容易粘错。
                final rawHeader = headerCtl.text.trim();
                final headers = <String, String>{};
                if (rawHeader.contains(':')) {
                  final i = rawHeader.indexOf(':');
                  headers[rawHeader.substring(0, i).trim()] =
                      rawHeader.substring(i + 1).trim();
                }
                Navigator.pop(
                  ctx,
                  McpConnection(
                    id: 'manual-${DateTime.now().millisecondsSinceEpoch}',
                    name: name.isEmpty ? url : name,
                    url: url,
                    headers: headers,
                    createdAt: DateTime.now(),
                  ),
                );
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );

    nameCtl.dispose();
    urlCtl.dispose();
    headerCtl.dispose();
    if (result == null || !mounted) return;

    final store = await _store();
    await store.upsert(result);
    await _reload();
    if (!mounted) return;
    await _testConnection(result);
  }
}
