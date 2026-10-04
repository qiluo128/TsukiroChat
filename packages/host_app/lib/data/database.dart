/// 本地 SQLite。
///
/// **schema v2**：智能体（Agent）取代会话成为顶层单位。
/// 见 `docs/18-agent-and-memory.md`。
///
/// v1 只有 `sessions` + `messages` —— 那只在只有一个 AI 角色时成立。
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 数据库封装。
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int schemaVersion = 2;
  static const String fileName = 'tsukiro.db';

  /// 迁移时给旧会话挂的默认智能体 id。
  static const String legacyAgentId = 'agent_default';

  static Future<AppDatabase> open(String directory) async {
    final path = p.join(directory, fileName);
    final db = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        // 外键约束默认关着 —— 不显式打开，删智能体时对话不会级联删除
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createV2(db);
      },
      onUpgrade: (db, from, to) async {
        // 每个版本一段，必须能单独回放（见 docs/10 §2.7）
        if (from < 2) {
          await _migrateV1ToV2(db);
        }
      },
    );
    return AppDatabase._(db);
  }

  // ═══════════════════════════ v2 schema ═══════════════════════════

  static Future<void> _createV2(Database db) async {
    final batch = db.batch();

    // ── 智能体 ──
    batch.execute('''
      CREATE TABLE agents (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        avatar_path   TEXT,
        persona       TEXT NOT NULL DEFAULT '{}',
        model_config  TEXT NOT NULL DEFAULT '{}',
        memory_config TEXT NOT NULL DEFAULT '{}',
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_agents_updated ON agents(updated_at DESC)');

    // ── 对话 ──
    batch.execute('''
      CREATE TABLE conversations (
        id              TEXT PRIMARY KEY,
        agent_id        TEXT NOT NULL,
        title           TEXT NOT NULL,
        status          TEXT NOT NULL DEFAULT 'active',
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL,
        last_message_at INTEGER,
        message_count   INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_conv_agent ON conversations(agent_id, status, updated_at DESC)');

    // ── 消息 ──
    batch.execute('''
      CREATE TABLE messages (
        id                TEXT PRIMARY KEY,
        conversation_id   TEXT NOT NULL,
        role              TEXT NOT NULL,
        content           TEXT,
        rich_content      TEXT,
        tool_calls        TEXT,
        tool_call_id      TEXT,
        status            TEXT NOT NULL DEFAULT 'done',
        error_code        TEXT,
        seq               INTEGER NOT NULL,
        created_at        INTEGER NOT NULL,
        tokens_prompt     INTEGER,
        tokens_completion INTEGER,
        reasoning         TEXT,
        metadata          TEXT,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
    // 会话内按 seq 唯一。**排序用它而不是 created_at** ——
    // 同一毫秒可能插入多条（用户消息 + 工具结果），时间戳会乱序。
    batch.execute('CREATE UNIQUE INDEX idx_msg_seq ON messages(conversation_id, seq)');
    batch.execute('CREATE INDEX idx_msg_conv ON messages(conversation_id, seq DESC)');

    // ── 记忆 ──
    batch.execute('''
      CREATE TABLE memories (
        id                 TEXT PRIMARY KEY,
        agent_id           TEXT NOT NULL,
        conversation_id    TEXT,
        type               TEXT NOT NULL DEFAULT 'fact',
        content            TEXT NOT NULL,
        embedding          BLOB,
        source_message_ids TEXT,
        created_at         INTEGER NOT NULL,
        metadata           TEXT,
        FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
      )
    ''');
    // 注意：**不给 conversation_id 加外键**。删对话不该删记忆（见 docs/18 §2.2）。
    batch.execute('CREATE INDEX idx_mem_agent ON memories(agent_id, created_at DESC)');
    batch.execute('CREATE INDEX idx_mem_conv ON memories(conversation_id)');

    // ── 服务商 ──
    batch.execute('''
      CREATE TABLE providers (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        protocol    TEXT NOT NULL DEFAULT 'openai',
        base_url    TEXT NOT NULL,
        api_key     TEXT NOT NULL DEFAULT '',
        is_official INTEGER NOT NULL DEFAULT 0,
        sort_order  INTEGER NOT NULL DEFAULT 100,
        created_at  INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE provider_models (
        provider_id    TEXT NOT NULL,
        id             TEXT NOT NULL,
        display_name   TEXT,
        context_window INTEGER,
        discovered_at  INTEGER,
        is_manual      INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (provider_id, id),
        FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE CASCADE
      )
    ''');

    // ── 设置 ──
    batch.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
  }

  // ═══════════════════════════ v1 → v2 ═══════════════════════════

  /// 把「会话为核心」迁移成「智能体为核心」。
  ///
  /// 1. 建 v2 的新表
  /// 2. 造一个**空人设**的默认智能体，把旧会话全挂到它下面
  /// 3. 旧消息表重建（改列名 + 加 rich_content / metadata）
  /// 4. 删掉旧的 sessions 表
  ///
  /// **不用 `ALTER TABLE RENAME COLUMN`**：那需要 SQLite 3.25+，
  /// 而 Android 8（API 26，我们的 minSdk）带的是 3.18/3.19。
  /// 建新表 + 拷贝 + 删旧表在所有版本都能跑。
  static Future<void> _migrateV1ToV2(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      // ── 1. 新表 ──
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS agents (
          id            TEXT PRIMARY KEY,
          name          TEXT NOT NULL,
          avatar_path   TEXT,
          persona       TEXT NOT NULL DEFAULT '{}',
          model_config  TEXT NOT NULL DEFAULT '{}',
          memory_config TEXT NOT NULL DEFAULT '{}',
          created_at    INTEGER NOT NULL,
          updated_at    INTEGER NOT NULL
        )
      ''');
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS conversations (
          id              TEXT PRIMARY KEY,
          agent_id        TEXT NOT NULL,
          title           TEXT NOT NULL,
          status          TEXT NOT NULL DEFAULT 'active',
          created_at      INTEGER NOT NULL,
          updated_at      INTEGER NOT NULL,
          last_message_at INTEGER,
          message_count   INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
        )
      ''');
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS memories (
          id                 TEXT PRIMARY KEY,
          agent_id           TEXT NOT NULL,
          conversation_id    TEXT,
          type               TEXT NOT NULL DEFAULT 'fact',
          content            TEXT NOT NULL,
          embedding          BLOB,
          source_message_ids TEXT,
          created_at         INTEGER NOT NULL,
          metadata           TEXT,
          FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
        )
      ''');
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS providers (
          id          TEXT PRIMARY KEY,
          name        TEXT NOT NULL,
          protocol    TEXT NOT NULL DEFAULT 'openai',
          base_url    TEXT NOT NULL,
          api_key     TEXT NOT NULL DEFAULT '',
          is_official INTEGER NOT NULL DEFAULT 0,
          sort_order  INTEGER NOT NULL DEFAULT 100,
          created_at  INTEGER NOT NULL
        )
      ''');
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS provider_models (
          provider_id    TEXT NOT NULL,
          id             TEXT NOT NULL,
          display_name   TEXT,
          context_window INTEGER,
          discovered_at  INTEGER,
          is_manual      INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (provider_id, id),
          FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE CASCADE
        )
      ''');

      // ── 2. 默认智能体（**空人设**）──
      // 旧版本内置了「雪」这个人设；这里刻意不继承 —— 用户要求 AI 不要有默认人设。
      await txn.insert(
        'agents',
        <String, Object?>{
          'id': legacyAgentId,
          'name': '默认智能体',
          'avatar_path': null,
          'persona': '{}',
          'model_config': '{}',
          'memory_config': '{}',
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      // ── 3. 旧会话 → 对话 ──
      final hasSessions = await _tableExists(txn, 'sessions');
      if (hasSessions) {
        await txn.execute('''
          INSERT OR IGNORE INTO conversations
            (id, agent_id, title, status, created_at, updated_at, last_message_at, message_count)
          SELECT
            id,
            '$legacyAgentId',
            title,
            CASE WHEN archived = 1 THEN 'archived' ELSE 'active' END,
            created_at,
            updated_at,
            last_message_at,
            message_count
          FROM sessions
        ''');
      }

      // ── 4. 旧消息表 → 新消息表 ──
      final hasMessages = await _tableExists(txn, 'messages');
      final alreadyMigrated =
          hasMessages && await _columnExists(txn, 'messages', 'conversation_id');
      if (hasMessages && !alreadyMigrated) {
        await txn.execute('''
          CREATE TABLE messages_v2 (
            id                TEXT PRIMARY KEY,
            conversation_id   TEXT NOT NULL,
            role              TEXT NOT NULL,
            content           TEXT,
            rich_content      TEXT,
            tool_calls        TEXT,
            tool_call_id      TEXT,
            status            TEXT NOT NULL DEFAULT 'done',
            error_code        TEXT,
            seq               INTEGER NOT NULL,
            created_at        INTEGER NOT NULL,
            tokens_prompt     INTEGER,
            tokens_completion INTEGER,
            reasoning         TEXT,
            metadata          TEXT,
            FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
          )
        ''');
        // 旧列名是 session_id；旧列 meta → 新列 metadata；旧列 plugin_id 在 v2 里不用了
        await txn.execute('''
          INSERT INTO messages_v2
            (id, conversation_id, role, content, rich_content, tool_calls, tool_call_id,
             status, error_code, seq, created_at, tokens_prompt, tokens_completion, reasoning, metadata)
          SELECT
            id, session_id, role, content, NULL, tool_calls, tool_call_id,
            status, error_code, seq, created_at, tokens_prompt, tokens_completion, reasoning, meta
          FROM messages
        ''');
        await txn.execute('DROP TABLE messages');
        await txn.execute('ALTER TABLE messages_v2 RENAME TO messages');
      }

      // ── 5. 删旧表 ──
      if (hasSessions) {
        await txn.execute('DROP TABLE IF EXISTS sessions');
      }

      // ── 6. 索引 ──
      await txn.execute('CREATE INDEX IF NOT EXISTS idx_agents_updated ON agents(updated_at DESC)');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_conv_agent ON conversations(agent_id, status, updated_at DESC)');
      await txn.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_msg_seq ON messages(conversation_id, seq)');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, seq DESC)');
      await txn.execute(
          'CREATE INDEX IF NOT EXISTS idx_mem_agent ON memories(agent_id, created_at DESC)');
      await txn.execute('CREATE INDEX IF NOT EXISTS idx_mem_conv ON memories(conversation_id)');
    });
  }

  static Future<bool> _tableExists(DatabaseExecutor db, String name) async {
    final r = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      <Object?>[name],
    );
    return r.isNotEmpty;
  }

  static Future<bool> _columnExists(DatabaseExecutor db, String table, String column) async {
    final r = await db.rawQuery('PRAGMA table_info($table)');
    return r.any((row) => row['name'] == column);
  }

  Future<void> close() => db.close();
}
