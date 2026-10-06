/// 记忆实现的统一接口。
///
/// 见 `docs/18-agent-and-memory.md` §3.3。
///
/// ## 为什么要有这一层
///
/// 宿主内置的记忆实现直接读写 SQLite 里的 `memories` 表。这在开始时够用，
/// 但把"记忆怎么存、怎么取、怎么压缩"**焊死在宿主里**了 ——
/// 而这三件事恰恰是记忆插件最想接管的部分（向量检索、图谱、摘要压缩…）。
///
/// 所以留出 [MemoryProvider] 这个缝：
///
/// ```text
/// AgentContextBuilder / memory.* 原语
///        ↓ 只认这个接口
/// MemoryProviderRegistry
///        ↓ 按 agent.memory.providerPluginId 解析
///   ┌────┴────┐
/// 宿主内置    插件实现（走 Bridge）
/// ```
///
/// **上层不认识任何具体实现。** 加一个记忆插件不需要改 [AgentContextBuilder]。
library;

import 'dart:async';

import '../audit/audit.dart';
import '../common/errors.dart';

// ═══════════════════════════ 粒度 ═══════════════════════════

/// 记忆粒度。
///
/// 定义在内核而不是宿主：插件实现 [MemoryProvider] 时要声明
/// [MemoryProvider.supportedScopes]，那是**插件契约的一部分**，
/// 不能只存在于宿主内部。
enum MemoryScope {
  /// 一个智能体一个记忆库，所有对话共享。**默认。**
  agent,

  /// 每个对话各自记忆。
  conversation;

  static MemoryScope parse(String? raw) =>
      raw == 'conversation' ? MemoryScope.conversation : MemoryScope.agent;

  String get label => this == MemoryScope.agent ? '所有对话共享' : '每个对话独立';
}

// ═══════════════════════════ 数据形状 ═══════════════════════════

/// 一条记忆（跨实现的通用形状）。
///
/// [type] 是**开放式字符串**而不是枚举：宿主认识 `fact` / `summary`，
/// 其余由插件自定义。这样加新记忆类型不需要改内核。
class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.content,
    this.type = 'fact',
    this.conversationId,
    this.createdAt,
    this.sourceMessageIds = const <String>[],
    this.metadata = const <String, dynamic>{},
    this.score,
  });

  final String id;
  final String content;
  final String type;

  /// null = 智能体级（所有对话共享）。
  final String? conversationId;

  final DateTime? createdAt;

  /// 可追溯"这条记忆是从哪几句来的"。
  final List<String> sourceMessageIds;

  /// 实现私有数据。**约定放在 `metadata.<providerId>` 下**，
  /// 避免不同实现互相踩。
  final Map<String, dynamic> metadata;

  /// 检索得分。宿主不解释它，只用来排序/截断。
  final double? score;

  @override
  String toString() => 'MemoryRecord($type, ${content.length} 字符)';
}

/// 一次检索请求。
class MemoryQuery {
  const MemoryQuery({
    required this.agentId,
    this.conversationId,
    this.scope = MemoryScope.agent,
    this.limit = 20,
    this.query,
    this.maxChars,
  });

  /// 要谁的记忆。**实现只能读这一个 agent 的** ——
  /// 宿主不会传"列出全部智能体"这种请求。
  final String agentId;

  final String? conversationId;

  /// 粒度。`conversation` 时实现应同时返回智能体级 + 该对话级
  /// （对话级是**附加**在共享记忆之上，不是替换）。
  final MemoryScope scope;

  final int limit;

  /// 语义检索用的关键词/向量文本。文本实现可以忽略它。
  final String? query;

  /// 提示词预算（字符数）。
  ///
  /// **由宿主给，不由实现决定** —— 实现不知道模型的上下文窗口有多大。
  /// 实现应据此截断，而不是返回一大堆让宿主自己砍。
  final int? maxChars;

  @override
  String toString() => 'MemoryQuery($agentId, scope=${scope.name}, limit=$limit)';
}

// ═══════════════════════════ 接口 ═══════════════════════════

/// 记忆实现。
///
/// 宿主内置一份（直接读写 SQLite）；插件实现这份接口，
/// 通过 Bridge 把 `memory.*` 调用转过来。
abstract class MemoryProvider {
  /// 标识。宿主内置用 [MemoryProviderRegistry.builtinId]。
  String get providerId;

  /// 显示名（设置页用）。
  String get displayName;

  /// 支持哪些粒度。
  ///
  /// **宿主据此校验 `agent.memory.scope`**：用户选了"每个对话独立"，
  /// 而插件只支持智能体级时，要么降级、要么明确报错 ——
  /// 不能假装支持然后行为不符。
  Set<MemoryScope> get supportedScopes;

  /// 检索。**唯一必须实现的方法。**
  ///
  /// 只读的实现（比如接一个用户自己维护的向量库）也是合法的 ——
  /// 所以 [store] 与 [compact] 都可以不实现。
  Future<List<MemoryRecord>> retrieve(MemoryQuery query);

  /// 是否支持写入。
  bool get supportsStore => false;

  /// 写入。返回新建记录的 id。
  ///
  /// [MemoryProvider.supportsStore] 为 false 时宿主不应调用它。
  Future<List<String>> store(String agentId, List<MemoryRecord> records) async {
    throw TsukiroException(
      TsukiroErrorCode.unsupported,
      '记忆实现 $providerId 不支持写入',
    );
  }

  /// 是否支持压缩。
  bool get supportsCompact => false;

  /// 压缩：把多条记忆合并成摘要。
  ///
  /// 长时间使用后记忆会越积越多，压缩能力决定它是否可持续 ——
  /// 但它是**可选**的，不实现也能用，只是记忆会一直增长。
  Future<void> compact(String agentId) async {
    throw TsukiroException(
      TsukiroErrorCode.unsupported,
      '记忆实现 $providerId 不支持压缩',
    );
  }
}

// ═══════════════════════════ 注册表 ═══════════════════════════

/// 记忆实现的注册表。
///
/// 上层**只认这个对象**，按 `agent.memory.providerPluginId` 解析出具体实现。
class MemoryProviderRegistry {
  MemoryProviderRegistry({required this.builtin, AuditSink? audit})
      : audit = audit ?? const NullAuditSink() {
    register(builtin);
    _builtinId = builtin.providerId;
  }

  /// 宿主内置实现的 id。
  static const String builtinId = 'host.builtin';

  /// 宿主的兜底实现。**永远存在** —— 插件挂了、没配、超时，都退到它。
  final MemoryProvider builtin;

  final AuditSink audit;
  late final String _builtinId;

  final Map<String, MemoryProvider> _providers = <String, MemoryProvider>{};

  void register(MemoryProvider provider) => _providers[provider.providerId] = provider;

  void unregister(String providerId) {
    if (providerId == _builtinId) return; // 内置的不可摘
    _providers.remove(providerId);
  }

  List<MemoryProvider> get all => _providers.values.toList(growable: false);

  /// 按 id 解析。null / 空 / 找不到 → **返回内置实现**。
  ///
  /// 找不到时退到内置而不是抛异常，是刻意的：插件被卸载、被停用、
  /// 或者 manifest 里写错了 id，都不该让用户**打不开对话**。
  /// 代价是记忆会悄悄换成内置的 —— 但"功能降级"远好过"应用不可用"。
  MemoryProvider resolve(String? providerId) {
    if (providerId == null || providerId.isEmpty) return builtin;
    final p = _providers[providerId];
    if (p == null) {
      audit.write(AuditEntry(
        pluginId: providerId,
        pluginVersion: '?',
        kind: 'memory',
        primitive: 'memory.resolve',
        argsDigest: const <String, dynamic>{},
        result: 'fallback',
      ));
      return builtin;
    }
    return p;
  }

  /// 校验某个 agent 的记忆配置能不能被实现满足。
  ///
  /// 返回 null 表示没问题；否则返回一句给用户看的话。
  String? validate({
    required String? providerPluginId,
    required MemoryScope scope,
  }) {
    final p = resolve(providerPluginId);
    if (p.supportedScopes.contains(scope)) return null;
    return '记忆实现「${p.displayName}」不支持「${scope.label}」，'
        '它会按自己支持的方式工作。';
  }
}
