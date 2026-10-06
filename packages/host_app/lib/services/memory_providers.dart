/// 宿主内置的记忆实现。
///
/// 直接读写 SQLite 的 `memories` 表。它是**兜底实现** ——
/// 插件没配、被卸载、调用失败时都退到它，所以必须永远可用。
///
/// 它也是 [MemoryProvider] 接口的一个范例实现：
/// 插件想接管记忆时照这个样子写就行（只不过要走 Bridge）。
library;

import 'package:plugin_core/plugin_core.dart';

import '../data/models.dart' as host;
import '../data/repositories.dart';

class BuiltinMemoryProvider extends MemoryProvider {
  BuiltinMemoryProvider(this._repos);

  final Future<Repos> _repos;

  @override
  String get providerId => MemoryProviderRegistry.builtinId;

  @override
  String get displayName => '内置记忆';

  @override
  Set<MemoryScope> get supportedScopes => const <MemoryScope>{
        MemoryScope.agent,
        MemoryScope.conversation,
      };

  @override
  bool get supportsStore => true;

  @override
  bool get supportsCompact => false;

  @override
  Future<List<MemoryRecord>> retrieve(MemoryQuery query) async {
    final rows = query.query == null || query.query!.trim().isEmpty
        ? await (await _repos).memories.listFor(
            query.agentId,
            conversationId: query.conversationId,
            scope: query.scope,
            limit: query.limit,
          )
        : await (await _repos).memories.search(
            query.agentId,
            query.query!,
            limit: query.limit,
          );

    return _toRecords(rows, maxChars: query.maxChars);
  }

  @override
  Future<List<String>> store(String agentId, List<MemoryRecord> records) async {
    final ids = <String>[];
    for (final r in records) {
      final entry = host.MemoryEntry(
        id: r.id.isEmpty ? host.newId('mem') : r.id,
        agentId: agentId,
        conversationId: r.conversationId,
        type: _parseType(r.type),
        content: r.content,
        sourceMessageIds: r.sourceMessageIds,
        createdAt: r.createdAt ?? DateTime.now(),
        metadata: r.metadata,
      );
      await (await _repos).memories.add(entry);
      ids.add(entry.id);
    }
    return ids;
  }

  // ─────────────────────────── 转换 ───────────────────────────

  /// 按 [maxChars] 截断。
  ///
  /// **在实现里做而不是丢给调用方** —— 调用方（AgentContextBuilder）
  /// 拿到的应该就是"能直接塞进提示词"的量。让上层自己砍的话，
  /// 每个调用点都要重复一遍这段逻辑，迟早有人忘。
  static List<MemoryRecord> _toRecords(
    List<host.MemoryEntry> rows, {
    int? maxChars,
  }) {
    final out = <MemoryRecord>[];
    var used = 0;
    for (final r in rows) {
      final content = r.content.trim();
      if (content.isEmpty) continue;
      if (maxChars != null && used + content.length > maxChars) {
        // 放不下就停 —— **不截半句**。被砍断的记忆比没有更糟：
        // 模型会把半句话当成完整事实。
        break;
      }
      used += content.length;
      out.add(MemoryRecord(
        id: r.id,
        content: content,
        type: r.type.name,
        conversationId: r.conversationId,
        createdAt: r.createdAt,
        sourceMessageIds: r.sourceMessageIds,
        metadata: r.metadata,
      ));
    }
    return out;
  }

  static host.MemoryType _parseType(String raw) {
    for (final t in host.MemoryType.values) {
      if (t.name == raw) return t;
    }
    return host.MemoryType.custom;
  }
}
