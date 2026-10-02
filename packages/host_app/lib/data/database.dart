/// 本地 SQLite。
///
/// 表结构见 `docs/10-data-model.md`。Demo 阶段用 sqflite 手工写 SQL，
/// 理由是表结构已定稿、且避开 build_runner 代码生成（每次改表都要跑一次）。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// 数据库封装。
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int schemaVersion = 1;
  static const String fileName = 'tsukiro.db';

  /// 打开（或创建）数据库。
  ///
  /// [directory] 由宿主提供（Android 上是应用私有目录）；测试里传临时目录。
  static Future<AppDatabase> open(String directory) async {
    final path = p.join(directory, fileName);
    final db = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        // 外键约束默认是关的 —— 不显式打开，删会话时消息不会级联删除
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, from, to) async {
        // 每个版本一段，必须能单独回放（见 docs/10 §2.7）
        // if (from < 2) { ... }
      },
    );
    return AppDatabase._(db);
  }

  static Future<void> _createSchema(Database db) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE sessions (
        id              TEXT PRIMARY KEY,
        title           TEXT NOT NULL,
        persona_id      TEXT,
        model           TEXT,
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL,
        last_message_at INTEGER,
        message_count   INTEGER NOT NULL DEFAULT 0,
        archived        INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('CREATE INDEX idx_sessions_sort ON sessions(archived, updated_at DESC)');

    batch.execute('''
      CREATE TABLE messages (
        id                TEXT PRIMARY KEY,
        session_id        TEXT NOT NULL,
        role              TEXT NOT NULL,
        content           TEXT,
        tool_calls        TEXT,
        tool_call_id      TEXT,
        plugin_id         TEXT,
        status            TEXT NOT NULL DEFAULT 'done',
        error_code        TEXT,
        seq               INTEGER NOT NULL,
        created_at        INTEGER NOT NULL,
        tokens_prompt     INTEGER,
        tokens_completion INTEGER,
        reasoning         TEXT,
        meta              TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');
    // 会话内按 seq 唯一。**排序用它而不是 created_at** ——
    // 同一毫秒内可能插入多条（用户消息 + 工具结果），时间戳会乱序。
    batch.execute('CREATE UNIQUE INDEX idx_messages_seq ON messages(session_id, seq)');
    batch.execute('CREATE INDEX idx_messages_session ON messages(session_id, seq DESC)');

    batch.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
  }

  Future<void> close() => db.close();
}

/// 会话与消息的仓储。
///
/// 所有 SQL 都在这里，界面层不直接碰 Database —— 换存储实现时只改这一个文件。
class ChatRepository {
  ChatRepository(this._db);

  final AppDatabase _db;

  Database get _d => _db.db;

  // ─────────────────────────── 会话 ───────────────────────────

  Future<List<ChatSession>> listSessions({bool includeArchived = false}) async {
    final rows = await _d.query(
      'sessions',
      where: includeArchived ? null : 'archived = 0',
      orderBy: 'COALESCE(last_message_at, updated_at) DESC',
    );
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  Future<ChatSession?> getSession(String id) async {
    final rows = await _d.query('sessions', where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    return rows.isEmpty ? null : _sessionFromRow(rows.first);
  }

  Future<ChatSession> createSession({String? title, String? personaId, String? model}) async {
    final now = DateTime.now();
    final session = ChatSession(
      id: newId('s'),
      title: title ?? '新对话',
      personaId: personaId,
      model: model,
      createdAt: now,
      updatedAt: now,
    );
    await _d.insert('sessions', _sessionToRow(session));
    return session;
  }

  Future<void> renameSession(String id, String title) async {
    await _d.update(
      'sessions',
      <String, Object?>{'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> deleteSession(String id) async {
    await _d.delete('sessions', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<void> setSessionModel(String id, String? model) async {
    await _d.update(
      'sessions',
      <String, Object?>{'model': model, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 会话的最后一条消息时间 / 条数。
  ///
  /// 做成冗余字段（而不是每次 COUNT）是为了会话列表页 —— 那是高频查询。
  Future<void> touchSession(String sessionId) async {
    await _d.rawUpdate('''
      UPDATE sessions SET
        last_message_at = (SELECT MAX(created_at) FROM messages WHERE session_id = ?),
        message_count   = (SELECT COUNT(*)      FROM messages WHERE session_id = ?),
        updated_at      = ?
      WHERE id = ?
    ''', <Object?>[
      sessionId,
      sessionId,
      DateTime.now().millisecondsSinceEpoch,
      sessionId,
    ]);
  }

  // ─────────────────────────── 消息 ───────────────────────────

  /// 取某会话的消息（按 seq 升序）。
  ///
  /// [limit] 从**最新往前**取，返回时仍是升序 —— 聊天页要先看到最近的内容。
  Future<List<StoredChatMessage>> listMessages(String sessionId, {int limit = 200}) async {
    final rows = await _d.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      orderBy: 'seq DESC',
      limit: limit,
    );
    return rows.reversed.map(_messageFromRow).toList(growable: false);
  }

  Future<int> nextSeq(String sessionId) async {
    final r = await _d.rawQuery(
      'SELECT COALESCE(MAX(seq), 0) AS m FROM messages WHERE session_id = ?',
      <Object?>[sessionId],
    );
    final maxSeq = (r.first['m'] as num?)?.toInt() ?? 0;
    return maxSeq + 1;
  }

  Future<void> insertMessage(StoredChatMessage message) async {
    await _d.insert('messages', _messageToRow(message));
    await touchSession(message.sessionId);
  }

  /// 局部更新消息（流式追加、定稿、出错都走它）。
  Future<void> updateMessage(
    String id, {
    String? content,
    String? reasoning,
    List<ToolCall>? toolCalls,
    MessageStatus? status,
    String? errorCode,
    int? tokensPrompt,
    int? tokensCompletion,
  }) async {
    final values = <String, Object?>{};
    if (content != null) values['content'] = content;
    if (reasoning != null) values['reasoning'] = reasoning;
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

  Future<void> deleteMessage(String id) async {
    final rows = await _d.query('messages', columns: <String>['session_id'],
        where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    await _d.delete('messages', where: 'id = ?', whereArgs: <Object?>[id]);
    if (rows.isNotEmpty) {
      await touchSession(rows.first['session_id']! as String);
    }
  }

  /// 清空某会话的消息。
  Future<void> clearMessages(String sessionId) async {
    await _d.delete('messages', where: 'session_id = ?', whereArgs: <Object?>[sessionId]);
    await touchSession(sessionId);
  }

  /// 上一次启动时正在流式输出、但进程被杀掉的消息。
  ///
  /// 启动时要把它们标成 error —— 否则界面上会永远显示"正在输入"。
  Future<int> failStaleStreamingMessages() async {
    return _d.update(
      'messages',
      <String, Object?>{'status': MessageStatus.error.name, 'error_code': 'INTERRUPTED'},
      where: 'status = ?',
      whereArgs: <Object?>[MessageStatus.streaming.name],
    );
  }

  // ─────────────────────────── 设置 ───────────────────────────

  Future<String?> getSetting(String key) async {
    final rows = await _d.query('settings', where: 'key = ?', whereArgs: <Object?>[key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
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

  // ─────────────────────────── 行 ↔ 对象 ───────────────────────────

  static ChatSession _sessionFromRow(Map<String, Object?> r) => ChatSession(
        id: r['id']! as String,
        title: r['title']! as String,
        personaId: r['persona_id'] as String?,
        model: r['model'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at']! as int),
        lastMessageAt: r['last_message_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_message_at']! as int),
        messageCount: (r['message_count'] as num?)?.toInt() ?? 0,
        archived: (r['archived'] as num?)?.toInt() == 1,
      );

  static Map<String, Object?> _sessionToRow(ChatSession s) => <String, Object?>{
        'id': s.id,
        'title': s.title,
        'persona_id': s.personaId,
        'model': s.model,
        'created_at': s.createdAt.millisecondsSinceEpoch,
        'updated_at': s.updatedAt.millisecondsSinceEpoch,
        'last_message_at': s.lastMessageAt?.millisecondsSinceEpoch,
        'message_count': s.messageCount,
        'archived': s.archived ? 1 : 0,
      };

  static StoredChatMessage _messageFromRow(Map<String, Object?> r) {
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

    final rawMeta = r['meta'] as String?;
    var meta = const <String, dynamic>{};
    if (rawMeta != null && rawMeta.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMeta);
        if (decoded is Map<String, dynamic>) meta = decoded;
      } catch (_) {}
    }

    return StoredChatMessage(
      id: r['id']! as String,
      sessionId: r['session_id']! as String,
      role: ChatRole.parse(r['role'] as String?),
      content: r['content'] as String?,
      toolCalls: toolCalls,
      toolCallId: r['tool_call_id'] as String?,
      pluginId: r['plugin_id'] as String?,
      status: MessageStatus.parse(r['status'] as String?),
      errorCode: r['error_code'] as String?,
      seq: (r['seq']! as num).toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
      tokensPrompt: (r['tokens_prompt'] as num?)?.toInt(),
      tokensCompletion: (r['tokens_completion'] as num?)?.toInt(),
      reasoning: r['reasoning'] as String?,
      meta: meta,
    );
  }

  static Map<String, Object?> _messageToRow(StoredChatMessage m) => <String, Object?>{
        'id': m.id,
        'session_id': m.sessionId,
        'role': m.role.name,
        'content': m.content,
        'tool_calls': m.toolCalls.isEmpty
            ? null
            : jsonEncode(m.toolCalls.map((t) => t.toJson()).toList()),
        'tool_call_id': m.toolCallId,
        'plugin_id': m.pluginId,
        'status': m.status.name,
        'error_code': m.errorCode,
        'seq': m.seq,
        'created_at': m.createdAt.millisecondsSinceEpoch,
        'tokens_prompt': m.tokensPrompt,
        'tokens_completion': m.tokensCompletion,
        'reasoning': m.reasoning,
        'meta': m.meta.isEmpty ? null : jsonEncode(m.meta),
      };
}
