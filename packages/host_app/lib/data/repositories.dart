/// 仓储层。
///
/// 所有 SQL 都在这里，界面不直接碰 Database —— 换存储实现时只改这些文件。
///
/// 划分与 `docs/18-agent-and-memory.md` 的实体一一对应：
/// [AgentRepository] / [ConversationRepository] / [MessageRepository] /
/// [MemoryRepository] / [ProviderRepository]。
library;

import 'dart:convert';

import 'package:model_gateway/model_gateway.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite/sqflite.dart';

import 'database.dart';
import 'models.dart';

/// 一轮对话的准备结果。
///
/// 由 [MessageRepository.prepareTurn] 在一个事务里产出，见那里的说明。
class PreparedChatTurn {
  const PreparedChatTurn({
    required this.userMessageId,
    required this.assistantMessageId,
    required this.userSeq,
    required this.assistantSeq,
  });

  final String userMessageId;
  final String assistantMessageId;
  final int userSeq;
  final int assistantSeq;

  @override
  String toString() =>
      'PreparedChatTurn(user=$userMessageId@$userSeq, assistant=$assistantMessageId@$assistantSeq)';
}

// ═══════════════════════════ 智能体 ═══════════════════════════

class AgentRepository {
  AgentRepository(this._db);

  final AppDatabase _db;
  Database get _d => _db.db;

  Future<List<Agent>> list() async {
    final rows = await _d.rawQuery('''
      SELECT a.*,
        (SELECT COUNT(*) FROM conversations c WHERE c.agent_id = a.id AND c.status = 'active') AS conv_count,
        (SELECT COUNT(*) FROM memories m WHERE m.agent_id = a.id) AS mem_count
      FROM agents a
      ORDER BY a.updated_at DESC
    ''');
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<Agent?> get(String id) async {
    final rows = await _d.query('agents', where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<int> count() async {
    final r = await _d.rawQuery('SELECT COUNT(*) AS n FROM agents');
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// 新建智能体。**人设默认为空** —— 用户要求 AI 不要有默认人设。
  Future<Agent> create({String? name, Persona? persona}) async {
    final now = DateTime.now();
    final agent = Agent(
      id: newId('agent'),
      name: name ?? '新智能体',
      persona: persona ?? Persona.empty,
      createdAt: now,
      updatedAt: now,
    );
    await _d.insert('agents', _toRow(agent));
    return agent;
  }

  Future<void> update(Agent agent) async {
    agent.updatedAt = DateTime.now();
    await _d.update('agents', _toRow(agent), where: 'id = ?', whereArgs: <Object?>[agent.id]);
  }

  /// 删除智能体。**级联删除它的对话、消息、记忆**（外键 ON DELETE CASCADE）。
  Future<void> delete(String id) async {
    await _d.delete('agents', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  // ── 行 ↔ 对象 ──

  static Agent _fromRow(Map<String, Object?> r) => Agent(
        id: r['id']! as String,
        name: r['name']! as String,
        avatarPath: r['avatar_path'] as String?,
        persona: Persona.fromJson(_decode(r['persona'])),
        model: AgentModelConfig.fromJson(_decode(r['model_config'])),
        memory: MemoryConfig.fromJson(_decode(r['memory_config'])),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at']! as int),
        conversationCount: (r['conv_count'] as num?)?.toInt() ?? 0,
        memoryCount: (r['mem_count'] as num?)?.toInt() ?? 0,
      );

  static Map<String, Object?> _toRow(Agent a) => <String, Object?>{
        'id': a.id,
        'name': a.name,
        'avatar_path': a.avatarPath,
        'persona': jsonEncode(a.persona.toJson()),
        'model_config': jsonEncode(a.model.toJson()),
        'memory_config': jsonEncode(a.memory.toJson()),
        'created_at': a.createdAt.millisecondsSinceEpoch,
        'updated_at': a.updatedAt.millisecondsSinceEpoch,
      };
}

// ═══════════════════════════ 对话 ═══════════════════════════

class ConversationRepository {
  ConversationRepository(this._db);

  final AppDatabase _db;
  Database get _d => _db.db;

  Future<List<Conversation>> listByAgent(
    String agentId, {
    ConversationStatus status = ConversationStatus.active,
  }) async {
    final rows = await _d.query(
      'conversations',
      where: 'agent_id = ? AND status = ?',
      whereArgs: <Object?>[agentId, status.name],
      orderBy: 'COALESCE(last_message_at, updated_at) DESC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<Conversation?> get(String id) async {
    final rows =
        await _d.query('conversations', where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<Conversation> create(String agentId, {String? title}) async {
    final now = DateTime.now();
    final c = Conversation(
      id: newId('conv'),
      agentId: agentId,
      title: title ?? '新对话',
      createdAt: now,
      updatedAt: now,
    );
    await _d.insert('conversations', _toRow(c));
    return c;
  }

  Future<void> rename(String id, String title) async {
    await _d.update(
      'conversations',
      <String, Object?>{'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 归档 / 恢复。
  Future<void> setStatus(String id, ConversationStatus status) async {
    await _d.update(
      'conversations',
      <String, Object?>{'status': status.name, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 彻底删除。**消息级联删除，但记忆保留** —— 见 docs/18 §2.2。
  Future<void> delete(String id) async {
    await _d.delete('conversations', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 更新冗余字段（最后消息时间 / 条数）。
  Future<void> touch(String conversationId) async {
    await _d.rawUpdate('''
      UPDATE conversations SET
        last_message_at = (SELECT MAX(created_at) FROM messages WHERE conversation_id = ?),
        message_count   = (SELECT COUNT(*)      FROM messages WHERE conversation_id = ?),
        updated_at      = ?
      WHERE id = ?
    ''', <Object?>[
      conversationId,
      conversationId,
      DateTime.now().millisecondsSinceEpoch,
      conversationId,
    ]);
  }

  static Conversation _fromRow(Map<String, Object?> r) => Conversation(
        id: r['id']! as String,
        agentId: r['agent_id']! as String,
        title: r['title']! as String,
        status: ConversationStatus.parse(r['status'] as String?),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at']! as int),
        lastMessageAt: r['last_message_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_message_at']! as int),
        messageCount: (r['message_count'] as num?)?.toInt() ?? 0,
      );

  static Map<String, Object?> _toRow(Conversation c) => <String, Object?>{
        'id': c.id,
        'agent_id': c.agentId,
        'title': c.title,
        'status': c.status.name,
        'created_at': c.createdAt.millisecondsSinceEpoch,
        'updated_at': c.updatedAt.millisecondsSinceEpoch,
        'last_message_at': c.lastMessageAt?.millisecondsSinceEpoch,
        'message_count': c.messageCount,
      };
}

// ═══════════════════════════ 消息 ═══════════════════════════

class MessageRepository {
  MessageRepository(this._db);

  final AppDatabase _db;
  Database get _d => _db.db;

  Future<List<StoredChatMessage>> list(String conversationId, {int limit = 200}) async {
    final rows = await _d.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: <Object?>[conversationId],
      orderBy: 'seq DESC',
      limit: limit,
    );
    return rows.reversed.map(_fromRow).toList(growable: false);
  }

  Future<int> nextSeq(String conversationId) async {
    final r = await _d.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS m FROM messages WHERE conversation_id = ?',
      <Object?>[conversationId],
    );
    return ((r.first['m'] as num?)?.toInt() ?? 0) + 1;
  }

  Future<void> insert(StoredChatMessage message) async {
    await _d.insert('messages', _toRow(message));
    await ConversationRepository(_db).touch(message.conversationId);
  }

  /// 原子地准备一轮对话：插入用户消息 + 助手占位消息 + 更新会话计数。
  ///
  /// **为什么必须是一个事务**：早先是「先 insert 用户消息，再 insert 助手占位」
  /// 两次独立调用。如果进程在这两步之间被杀（Android 上很常见），
  /// 库里就留下一条**永远等不到回复**的用户消息 —— 界面上它看起来像发失败了，
  /// 但重发又会出现两条一模一样的。
  ///
  /// **为什么 seq 要在事务里算**：[nextSeq] + [insert] 是典型的读后写竞态。
  /// 两次并发调用会拿到同一个 seq，撞上 `idx_msg_seq` 唯一索引直接抛异常。
  /// sqflite 会把同一连接上的事务串行化，所以事务内 `MAX(seq)+1` 是安全的。
  Future<PreparedChatTurn> prepareTurn(
    String conversationId, {
    required String userText,
    String? userId,
    String? assistantId,
    DateTime? now,
  }) async {
    final ts = now ?? DateTime.now();
    final uid = userId ?? newId('m');
    final aid = assistantId ?? newId('m');

    return _d.transaction<PreparedChatTurn>((txn) async {
      final r = await txn.rawQuery(
        'SELECT COALESCE(MAX(seq), 0) AS m FROM messages WHERE conversation_id = ?',
        <Object?>[conversationId],
      );
      final base = (r.first['m'] as num?)?.toInt() ?? 0;
      final userSeq = base + 1;
      final assistantSeq = base + 2;

      await txn.insert(
        'messages',
        _toRow(StoredChatMessage(
          id: uid,
          conversationId: conversationId,
          role: ChatRole.user,
          content: userText,
          seq: userSeq,
          createdAt: ts,
        )),
      );
      await txn.insert(
        'messages',
        _toRow(StoredChatMessage(
          id: aid,
          conversationId: conversationId,
          role: ChatRole.assistant,
          status: MessageStatus.streaming,
          seq: assistantSeq,
          createdAt: ts,
        )),
      );

      // 计数器与标题也在同一个事务里 —— 否则并发下会话列表会显示错条数
      await txn.rawUpdate('''
        UPDATE conversations SET
          title           = CASE
                              WHEN title = '新对话' OR TRIM(title) = '' THEN ?
                              ELSE title
                            END,
          last_message_at = ?,
          message_count   = message_count + 2,
          updated_at      = ?
        WHERE id = ?
      ''', <Object?>[
        _titleFrom(userText),
        ts.millisecondsSinceEpoch,
        ts.millisecondsSinceEpoch,
        conversationId,
      ]);

      return PreparedChatTurn(
        userMessageId: uid,
        assistantMessageId: aid,
        userSeq: userSeq,
        assistantSeq: assistantSeq,
      );
    });
  }

  static String _titleFrom(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '新对话';
    return flat.length <= 18 ? flat : '${flat.substring(0, 18)}…';
  }

  Future<void> update(
    String id, {
    String? content,
    String? reasoning,
    Map<String, dynamic>? richContent,
    List<ToolCall>? toolCalls,
    MessageStatus? status,
    String? errorCode,
    int? tokensPrompt,
    int? tokensCompletion,
  }) async {
    final values = <String, Object?>{};
    if (content != null) values['content'] = content;
    if (reasoning != null) values['reasoning'] = reasoning;
    if (richContent != null) values['rich_content'] = jsonEncode(richContent);
    if (toolCalls != null) {
      values['tool_calls'] = jsonEncode(toolCalls.map((t) => t.toJson()).toList());
    }
    if (status != null) values['status'] = status.name;
    if (errorCode != null) values['error_code'] = errorCode;
    if (tokensPrompt != null) values['tokens_prompt'] = tokensPrompt;
    if (tokensCompletion != null) values['tokens_completion'] = tokensCompletion;
    if (values.isEmpty) return;
    await _d.update('messages', values, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<void> delete(String id) async {
    final rows = await _d.query('messages',
        columns: <String>['conversation_id'], where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    await _d.delete('messages', where: 'id = ?', whereArgs: <Object?>[id]);
    if (rows.isNotEmpty) {
      await ConversationRepository(_db).touch(rows.first['conversation_id']! as String);
    }
  }

  Future<void> clear(String conversationId) async {
    await _d.delete('messages', where: 'conversation_id = ?', whereArgs: <Object?>[conversationId]);
    await ConversationRepository(_db).touch(conversationId);
  }

  /// 上次进程被杀时正在流式输出、但没定稿的消息。
  /// 启动时要把它们标为 error —— 否则界面永远显示"正在输入"。
  Future<int> failStaleStreaming() async => _d.update(
        'messages',
        <String, Object?>{
          'status': MessageStatus.error.name,
          'error_code': 'INTERRUPTED',
        },
        where: 'status = ?',
        whereArgs: <Object?>[MessageStatus.streaming.name],
      );

  static StoredChatMessage _fromRow(Map<String, Object?> r) {
    final rawTools = r['tool_calls'] as String?;
    var toolCalls = const <ToolCall>[];
    if (rawTools != null && rawTools.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawTools);
        if (decoded is List) {
          toolCalls = decoded
              .whereType<Map<String, dynamic>>()
              .map(ToolCall.fromOpenAi)
              .toList(growable: false);
        }
      } catch (_) {
        // 坏数据不该让整个会话打不开
      }
    }

    return StoredChatMessage(
      id: r['id']! as String,
      conversationId: r['conversation_id']! as String,
      role: ChatRole.parse(r['role'] as String?),
      content: r['content'] as String?,
      richContent: _decode(r['rich_content']),
      toolCalls: toolCalls,
      toolCallId: r['tool_call_id'] as String?,
      status: MessageStatus.parse(r['status'] as String?),
      errorCode: r['error_code'] as String?,
      seq: (r['seq']! as num).toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
      tokensPrompt: (r['tokens_prompt'] as num?)?.toInt(),
      tokensCompletion: (r['tokens_completion'] as num?)?.toInt(),
      reasoning: r['reasoning'] as String?,
      metadata: _decode(r['metadata']) ?? const <String, dynamic>{},
    );
  }

  static Map<String, Object?> _toRow(StoredChatMessage m) => <String, Object?>{
        'id': m.id,
        'conversation_id': m.conversationId,
        'role': m.role.name,
        'content': m.content,
        'rich_content': m.richContent == null ? null : jsonEncode(m.richContent),
        'tool_calls':
            m.toolCalls.isEmpty ? null : jsonEncode(m.toolCalls.map((t) => t.toJson()).toList()),
        'tool_call_id': m.toolCallId,
        'status': m.status.name,
        'error_code': m.errorCode,
        'seq': m.seq,
        'created_at': m.createdAt.millisecondsSinceEpoch,
        'tokens_prompt': m.tokensPrompt,
        'tokens_completion': m.tokensCompletion,
        'reasoning': m.reasoning,
        'metadata': m.metadata.isEmpty ? null : jsonEncode(m.metadata),
      };
}

// ═══════════════════════════ 记忆 ═══════════════════════════

class MemoryRepository {
  MemoryRepository(this._db);

  final AppDatabase _db;
  Database get _d => _db.db;

  /// 取某个智能体的记忆。
  ///
  /// [conversationId] 非空时，返回「智能体级 + 该对话级」两部分 ——
  /// 因为对话级记忆是**附加**在共享记忆之上的，不是替换。
  Future<List<MemoryEntry>> listFor(
    String agentId, {
    String? conversationId,
    MemoryScope scope = MemoryScope.agent,
    int limit = 200,
  }) async {
    if (scope == MemoryScope.agent) {
      final rows = await _d.query('memories',
          where: 'agent_id = ?', whereArgs: <Object?>[agentId],
          orderBy: 'created_at DESC', limit: limit);
      return rows.map(_fromRow).toList(growable: false);
    }

    final rows = await _d.query(
      'memories',
      where: 'agent_id = ? AND (conversation_id IS NULL OR conversation_id = ?)',
      whereArgs: <Object?>[agentId, conversationId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<String> add(MemoryEntry entry) async {
    await _d.insert('memories', _toRow(entry), conflictAlgorithm: ConflictAlgorithm.replace);
    return entry.id;
  }

  Future<void> update(MemoryEntry entry) async {
    await _d.update('memories', _toRow(entry), where: 'id = ?', whereArgs: <Object?>[entry.id]);
  }

  Future<void> delete(String id) async {
    await _d.delete('memories', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 朴素的文本检索（宿主兜底用）。
  ///
  /// 真正的检索策略由插件的 `MemoryProvider` 决定 ——
  /// 宿主不预设"怎么找"，只提供一张能查的表。
  Future<List<MemoryEntry>> search(String agentId, String keyword, {int limit = 20}) async {
    final rows = await _d.query(
      'memories',
      where: 'agent_id = ? AND content LIKE ?',
      whereArgs: <Object?>[agentId, '%$keyword%'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<int> countOf(String agentId) async {
    final r = await _d.rawQuery(
        'SELECT COUNT(*) AS n FROM memories WHERE agent_id = ?', <Object?>[agentId]);
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  static MemoryEntry _fromRow(Map<String, Object?> r) {
    final ids = r['source_message_ids'] as String?;
    return MemoryEntry(
      id: r['id']! as String,
      agentId: r['agent_id']! as String,
      conversationId: r['conversation_id'] as String?,
      type: MemoryType.parse(r['type'] as String?),
      content: r['content'] as String? ?? '',
      sourceMessageIds: ids == null
          ? const <String>[]
          : (jsonDecode(ids) as List).map((e) => '$e').toList(growable: false),
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
      metadata: _decode(r['metadata']) ?? const <String, dynamic>{},
    );
  }

  static Map<String, Object?> _toRow(MemoryEntry m) => <String, Object?>{
        'id': m.id,
        'agent_id': m.agentId,
        'conversation_id': m.conversationId,
        'type': m.type.name,
        'content': m.content,
        'source_message_ids':
            m.sourceMessageIds.isEmpty ? null : jsonEncode(m.sourceMessageIds),
        'created_at': m.createdAt.millisecondsSinceEpoch,
        'metadata': m.metadata.isEmpty ? null : jsonEncode(m.metadata),
      };
}

// ═══════════════════════════ 服务商 ═══════════════════════════

class ProviderRepository {
  ProviderRepository(this._db);

  final AppDatabase _db;
  Database get _d => _db.db;

  /// 官方服务的占位 id。它排在列表最前、不可删除。
  static const String officialId = 'provider_official';

  /// 所有服务商（官方置顶，其余按 sort_order）。
  Future<List<ModelProvider>> list() async {
    final rows = await _d.rawQuery('''
      SELECT p.*,
        (SELECT COUNT(*) FROM provider_models m WHERE m.provider_id = p.id) AS model_count
      FROM providers p
      ORDER BY p.is_official DESC, p.sort_order ASC, p.created_at ASC
    ''');
    return rows.map(_fromRow).toList(growable: false);
  }

  /// 可用的服务商（填了 baseUrl + key）。
  Future<List<ModelProvider>> listUsable() async =>
      (await list()).where((p) => p.isUsable).toList(growable: false);

  Future<ModelProvider?> get(String id) async {
    final rows = await _d.query('providers', where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<void> upsert(ModelProvider p) async {
    await _d.insert('providers', _toRow(p), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ModelProvider> create({
    required String name,
    required ProviderProtocol protocol,
    required String baseUrl,
    required String apiKey,
  }) async {
    final p = ModelProvider(
      id: newId('prov'),
      name: name,
      protocol: protocol,
      baseUrl: baseUrl,
      apiKey: apiKey,
      createdAt: DateTime.now(),
    );
    await upsert(p);
    return p;
  }

  Future<void> delete(String id) async {
    if (id == officialId) return; // 官方服务不可删
    await _d.delete('providers', where: 'id = ? AND is_official = 0', whereArgs: <Object?>[id]);
  }

  /// 确保官方服务那一行存在（占位，本期不实现真正的充值）。
  Future<void> ensureOfficial() async {
    final existing = await get(officialId);
    if (existing != null) return;
    await upsert(ModelProvider(
      id: officialId,
      name: '官方服务',
      protocol: ProviderProtocol.openai,
      baseUrl: '',
      apiKey: '',
      isOfficial: true,
      sortOrder: 0,
      createdAt: DateTime.now(),
    ));
  }

  // ── 模型 ──

  Future<List<ProviderModel>> modelsOf(String providerId) async {
    final rows = await _d.query('provider_models',
        where: 'provider_id = ?', whereArgs: <Object?>[providerId], orderBy: 'is_manual DESC, id ASC');
    return rows.map(_modelFromRow).toList(growable: false);
  }

  /// 所有模型 + 它们的服务商 —— 「选模型时显示来自哪个服务商」用的就是这个。
  Future<List<ModelChoice>> allChoices({bool onlyUsable = true}) async {
    final providers = onlyUsable ? await listUsable() : await list();
    final out = <ModelChoice>[];
    for (final p in providers) {
      for (final m in await modelsOf(p.id)) {
        out.add(ModelChoice(provider: p, model: m));
      }
    }
    return out;
  }

  /// 用拉取到的模型表覆盖「自动发现」的那些。
  ///
  /// **手动添加的（`is_manual = true`）不删** ——
  /// 有些中转站的模型表不全，用户手动补的不能被一次刷新清掉。
  Future<void> replaceDiscovered(String providerId, List<ModelInfo> models) async {
    await _d.transaction((txn) async {
      await txn.delete(
        'provider_models',
        where: 'provider_id = ? AND is_manual = 0',
        whereArgs: <Object?>[providerId],
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final m in models) {
        await txn.insert(
          'provider_models',
          <String, Object?>{
            'provider_id': providerId,
            'id': m.id,
            'display_name': m.displayName,
            'context_window': m.contextWindow,
            'discovered_at': now,
            'is_manual': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> addManualModel(String providerId, String modelId, {String? displayName}) async {
    await _d.insert(
      'provider_models',
      <String, Object?>{
        'provider_id': providerId,
        'id': modelId,
        'display_name': displayName,
        'discovered_at': null,
        'is_manual': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeModel(String providerId, String modelId) async {
    await _d.delete('provider_models',
        where: 'provider_id = ? AND id = ?', whereArgs: <Object?>[providerId, modelId]);
  }

  // ── 行 ↔ 对象 ──

  static ModelProvider _fromRow(Map<String, Object?> r) => ModelProvider(
        id: r['id']! as String,
        name: r['name']! as String,
        protocol: ProviderProtocol.parse(r['protocol'] as String?),
        baseUrl: r['base_url'] as String? ?? '',
        apiKey: r['api_key'] as String? ?? '',
        isOfficial: (r['is_official'] as num?)?.toInt() == 1,
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 100,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
        modelCount: (r['model_count'] as num?)?.toInt() ?? 0,
      );

  static Map<String, Object?> _toRow(ModelProvider p) => <String, Object?>{
        'id': p.id,
        'name': p.name,
        'protocol': p.protocol.name,
        'base_url': p.baseUrl,
        'api_key': p.apiKey,
        'is_official': p.isOfficial ? 1 : 0,
        'sort_order': p.sortOrder,
        'created_at': p.createdAt.millisecondsSinceEpoch,
      };

  static ProviderModel _modelFromRow(Map<String, Object?> r) => ProviderModel(
        providerId: r['provider_id']! as String,
        id: r['id']! as String,
        displayName: r['display_name'] as String?,
        contextWindow: (r['context_window'] as num?)?.toInt(),
        discoveredAt: r['discovered_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['discovered_at']! as int),
        isManual: (r['is_manual'] as num?)?.toInt() == 1,
      );
}

// ═══════════════════════════ 设置 ═══════════════════════════

class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;
  Database get _d => _db.db;

  Future<String?> get(String key) async {
    final rows = await _d.query('settings', where: 'key = ?', whereArgs: <Object?>[key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> set(String key, String value) async {
    await _d.insert(
      'settings',
      <String, Object?>{
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

// ═══════════════════════════ 聚合入口 ═══════════════════════════

/// 一把拿到全部仓储。
///
/// 界面层注入这一个对象就够了，不用记住五个 repository 的名字。
class Repos {
  Repos(AppDatabase db)
      : agents = AgentRepository(db),
        conversations = ConversationRepository(db),
        messages = MessageRepository(db),
        memories = MemoryRepository(db),
        providers = ProviderRepository(db),
        settings = SettingsRepository(db);

  final AgentRepository agents;
  final ConversationRepository conversations;
  final MessageRepository messages;
  final MemoryRepository memories;
  final ProviderRepository providers;
  final SettingsRepository settings;

  /// 首次启动的初始化。
  ///
  /// - 确保官方服务那一行存在（占位）
  /// - **不创建任何默认智能体** —— 由界面引导用户新建（见 docs/18 §6）
  Future<void> bootstrap() async {
    await providers.ensureOfficial();
    await messages.failStaleStreaming();
  }
}

// ═══════════════════════════ 辅助 ═══════════════════════════

Map<String, dynamic>? _decode(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}
