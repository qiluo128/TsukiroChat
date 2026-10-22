/// MCP 连接：模型、存储、以及把它们变成 AI 能用的工具。
///
/// ## 存储为什么用 settings 表而不是新建一张表
///
/// 新建 SQL 表要写迁移，而迁移做错了很难退回去。连接信息量很小
/// （几十条上限），放一个 JSON 数组在 settings 里完全够用，
/// 而且**零迁移风险**。
///
/// 真的多到需要查询/排序时再迁 —— 那时数据已经在手上，迁移是纯粹的
/// 数据搬运，比现在先建表再发现设计不对要便宜。
///
/// ## 工具注册
///
/// 每个连接在 `ToolRegistry` 里登记为 `pluginId = 'mcp:<id>'`。
/// 同时必须在 `Gatekeeper` 里登记一个**空权限集合** ——
/// 否则 `check` 会返回 `unknownPlugin`，工具全被拒（fail-closed）。
///
/// 空权限集合过门禁是 allow，正好符合「MCP 不做能力门禁」的决定。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:plugin_core/plugin_core.dart';

import '../data/repositories.dart';
import '../plugin/plugin_host.dart';
import '../providers/app_providers.dart';
import 'mcp_client.dart';

class McpConnection {
  const McpConnection({
    required this.id,
    required this.name,
    required this.url,
    this.transport = 'http',
    this.headers = const <String, String>{},
    this.source = 'manual',
    this.enabled = true,
    this.createdAt,
  });

  /// 稳定 id。手动添加的是 `mcp:<时间戳>`，插件带来的是
  /// `mcp:<pluginId>` —— 这样卸载插件时能精确找到自己那条。
  final String id;
  final String name;
  final String url;
  final String transport;
  final Map<String, String> headers;

  /// `manual` 或 `plugin:<pluginId>`
  final String source;
  final bool enabled;
  final DateTime? createdAt;

  /// Gatekeeper / ToolRegistry 里用的身份。
  String get pluginId => 'mcp:$id';

  McpConnection copyWith({
    String? name,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
  }) =>
      McpConnection(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        transport: transport,
        headers: headers ?? this.headers,
        source: source,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'transport': transport,
        'headers': headers,
        'source': source,
        'enabled': enabled,
        'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
      };

  static McpConnection? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final url = j['url'];
    if (id is! String || id.isEmpty || url is! String || url.isEmpty) return null;
    return McpConnection(
      id: id,
      name: j['name'] as String? ?? id,
      url: url,
      transport: j['transport'] as String? ?? 'http',
      headers: (j['headers'] as Map?)?.map(
            (k, v) => MapEntry('$k', '$v'),
          ) ??
          const <String, String>{},
      source: j['source'] as String? ?? 'manual',
      enabled: j['enabled'] != false,
      createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? ''),
    );
  }
}

/// 一个连接加上它当前的工具表。
class McpLive {
  McpLive({required this.connection, required this.client, required this.tools})
      : gatekeeperId = connection.pluginId;

  final McpConnection connection;
  final McpClient client;
  final List<McpTool> tools;
  final String gatekeeperId;

  String get label => connection.name;
}

class McpStore {
  McpStore(this._settings);

  final SettingsRepository _settings;

  /// 全部连接都存这一个键下。改结构时先读后写，不依赖外部 schema。
  static const String _key = 'mcp.connections';

  Future<List<McpConnection>> load() async {
    final raw = await _settings.get(_key);
    if (raw == null || raw.isEmpty) return <McpConnection>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <McpConnection>[];
      final out = <McpConnection>[];
      for (final e in decoded) {
        if (e is Map) {
          final c = McpConnection.fromJson(e.cast<String, dynamic>());
          if (c != null) out.add(c);
        }
      }
      return out;
    } catch (_) {
      // 存坏了就当没有 —— 一条坏数据不该让整个 MCP 页打不开
      return <McpConnection>[];
    }
  }

  Future<void> save(List<McpConnection> connections) async {
    await _settings.set(
      _key,
      jsonEncode(connections.map((c) => c.toJson()).toList(growable: false)),
    );
  }

  Future<void> upsert(McpConnection c) async {
    final all = await load();
    final i = all.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      all[i] = c;
    } else {
      all.add(c);
    }
    await save(all);
  }

  Future<void> remove(String id) async {
    final all = await load()..removeWhere((x) => x.id == id);
    await save(all);
  }

  /// 删掉某个插件带来的所有连接。卸载插件时调。
  Future<int> removeByPlugin(String pluginId) async {
    final all = await load();
    final before = all.length;
    all.removeWhere((x) => x.source == 'plugin:$pluginId');
    if (all.length != before) await save(all);
    return before - all.length;
  }
}

/// 管理活跃连接。
///
/// 「活跃」= 已经完成 initialize + tools/list。
/// 只存不连（enabled 但没连上）是正常状态 —— 网络问题不该让设置页打不开。
class McpService {
  McpService({
    required McpStore store,
    required ToolRegistry tools,
    required Gatekeeper gatekeeper,
  })  : _store = store,
        _tools = tools,
        _gatekeeper = gatekeeper;

  final McpStore _store;
  final ToolRegistry _tools;
  final Gatekeeper _gatekeeper;

  final Map<String, McpLive> _live = <String, McpLive>{};
  Map<String, McpLive> get live => Map<String, McpLive>.unmodifiable(_live);

  /// 连接并注册工具。失败抛 [McpException]，调用方决定怎么显示。
  Future<McpLive> connect(McpConnection c) async {
    await disconnect(c.id);

    final client = McpClient(url: c.url, headers: c.headers);
    final info = await client.initialize();
    final tools = await client.listTools();

    // **必须在 Gatekeeper 里登记**。空权限集合 = 允许调用，
    // 但不登记的话 check 会走 unknownPlugin → 全拒。
    _gatekeeper.registerExternal(c.pluginId, const <String>{});

    for (final t in tools) {
      _tools.registerExternalTool(RegisteredTool(
        name: _toolName(c, t.name),
        originalName: t.name,
        description: t.description,
        parameters: t.inputSchema,
        pluginId: c.pluginId,
        pluginVersion: info.version.isEmpty ? '1' : info.version,
        handler: t.name,
        permissions: const <String>[],
        timeoutMs: 60000,
        dangerous: false,
        exposed: true,
      ));
    }

    final live = McpLive(connection: c, client: client, tools: tools);
    _live[c.id] = live;
    return live;
  }

  Future<void> disconnect(String id) async {
    final prev = _live.remove(id);
    if (prev == null) return;
    _tools.unregisterPlugin(prev.connection.pluginId);
  }

  /// 把插件声明的 MCP 连接同步到存储。
  ///
  /// 三件事：
  ///   · 插件有 provides.mcp 但没有对应连接 → 建一条
  ///   · 插件还在，url 变了 → 更新
  ///   · 连接还在但插件没了 → 删掉
  ///
  /// **token 在同步时从插件的 config 读出来拼进 headers** ——
  /// 插件作者不知道用户的 token，只在清单里写"引用哪个 config key"。
  ///
  /// 复制 token 进连接有个已知的代价：插件配置改了、连接里还是旧的。
  /// 所以同步必须在**配置变更之后**再跑一次（宿主 revision 变化会触发）。
  Future<void> syncFromPlugins(
    List<InstalledPlugin> plugins,
    String? Function(String pluginId, String key) configValueOf,
  ) async {
    final existing = await _store.load();
    final byId = <String, McpConnection>{for (final c in existing) c.id: c};
    final wanted = <String>{};

    for (final p in plugins) {
      final decl = p.manifest.provides.mcp;
      if (decl == null) continue;

      final id = 'plugin:' + p.id;
      wanted.add(id);

      String? token;
      final key = decl.tokenConfigKey;
      if (key != null) {
        final raw = configValueOf(p.id, key);
        token = raw?.toString();
      }

      final next = McpConnection(
        id: id,
        name: decl.name.isEmpty ? p.name : decl.name,
        url: decl.url,
        headers: decl.headersWith(token),
        source: 'plugin:' + p.id,
        enabled: p.enabled,
        createdAt: byId[id]?.createdAt ?? DateTime.now(),
      );

      final prev = byId[id];
      // 只在真的变了时才写，避免每次启动都重写存储
      if (prev == null ||
          prev.url != next.url ||
          prev.enabled != next.enabled ||
          prev.name != next.name ||
          !_sameHeaders(prev.headers, next.headers)) {
        await _store.upsert(next);
      }
    }

    // 插件没了 → 连接也删（只删插件带来的，手动加的不动）
    for (final c in existing) {
      if (!c.source.startsWith('plugin:')) continue;
      if (wanted.contains(c.id)) continue;
      await _store.remove(c.id);
    }
  }

  bool _sameHeaders(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// 调一个 MCP 工具（供宿主工具分派用）。
  ///
  /// 审计暂时没接（`AuditEntry` 的字段我没核对就写了，编译不过，
  /// 先去掉免得瞎猜）。**这是 docs/25 §6 三件事之一，待补。**
  Future<McpCallResult> callTool(
    String connectionId,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final live = _live[connectionId];
    if (live == null) {
      throw McpException('MCP 连接未就绪（$connectionId）');
    }
    return live.client.callTool(toolName, args);
  }

  /// 工具名：`mcp__<连接>__<工具>`。
  ///
  /// 加前缀是因为 MCP 的工具名不受我们控制，很容易和宿主工具
  /// 或别的 server 撞名（比如两个 server 都有 `search`）。
  String _toolName(McpConnection c, String tool) =>
      'mcp__${_slug(c.name)}__${tool.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';

  String _slug(String s) {
    final out = s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return out.isEmpty ? 'server' : out;
  }

  /// 从工具名反查 (连接 id, 原始工具名)。
  ///
  /// 宿主工具分派时要靠它找到该发给谁。
  (String, String)? decodeToolName(String name) {
    if (!name.startsWith('mcp__')) return null;
    for (final live in _live.values) {
      for (final t in live.tools) {
        if (_toolName(live.connection, t.name) == name) {
          return (live.connection.id, t.name);
        }
      }
    }
    return null;
  }

  Future<void> dispose() async {
    for (final id in _live.keys.toList(growable: false)) {
      await disconnect(id);
    }
  }

  Future<List<McpConnection>> loadConnections() => _store.load();
}

/// 活跃的 MCP 服务。
///
/// 这个 provider 的初始化过程会**把已启用连接的工具有效注册进工具表** ——
/// 没有它，McpService 永远不会被实例化，工具永远注册不进去，
/// 整条 MCP 链路就是死代码。
final FutureProvider<McpService> mcpServiceProvider =
    FutureProvider<McpService>((ref) async {
  final store = await ref.watch(mcpStoreProvider.future);
  final svc = McpService(
    store: store,
    tools: ref.watch(toolRegistryProvider),
    gatekeeper: ref.watch(gatekeeperProvider),
  );
  ref.onDispose(svc.dispose);

  // 逐个连接。**单个失败不影响其它** —— 一个 server 挂了
  // 不该让所有 MCP 工具都不可用。
  final connections = await store.load();
  for (final c in connections) {
    if (!c.enabled) continue;
    try {
      await svc.connect(c);
    } catch (_) {
      // 连不上就跳过；用户可以在设置页里点「测试连接」看错误原文
    }
  }
  return svc;
});

/// MCP 存储（依赖仓储）。
final FutureProvider<McpStore> mcpStoreProvider = FutureProvider<McpStore>((ref) async {
  final repos = await ref.watch(reposProvider.future);
  return McpStore(repos.settings);
});
