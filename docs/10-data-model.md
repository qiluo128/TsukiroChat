# 10 · 数据模型

> 双轨：**宿主数据**（会话、消息、插件元信息）存 SQLite；**插件数据**（state、文件）按沙箱目录隔离。

---

## 1. 存储总览

```
<app 数据目录>/
├─ tsukiro.db                     # 宿主 SQLite（Drift）
├─ sandbox/                       # 插件沙箱根
│  └─ <pluginId>/
│     ├─ current -> 1.0.0         # 指向当前启用版本（符号链接由宿主维护）
│     ├─ 1.0.0/                   # 该版本解压内容（只读）
│     │  ├─ manifest.json
│     │  ├─ index.js
│     │  └─ ...
│     ├─ data/                    # 插件私有文件（fs.* 的根，卸载时删除）
│     └─ state.json               # state.* 的存储（见 §4）
├─ avatars/                       # 人设头像
├─ audio/                         # 语音缓存（阶段 7+）
└─ logs/                          # 宿主日志
```

**沙箱规则**：`fs.*` 的 `path` 参数一律相对于 `sandbox/<pluginId>/data/`。宿主用 `p.normalize(p.join(root, userPath))` 后检查 `result.startsWith(root)`，不通过则 `SANDBOX_VIOLATION`。

---

## 2. SQLite Schema

### 2.1 会话与消息

```sql
-- 会话
CREATE TABLE sessions (
  id            TEXT PRIMARY KEY,            -- uuid v7（时间有序，便于分页）
  title         TEXT NOT NULL DEFAULT '新对话',
  persona_id    TEXT,                        -- 关联 personas.id，NULL = 默认人设
  model         TEXT NOT NULL DEFAULT 'default',
  created_at    INTEGER NOT NULL,            -- epoch ms
  updated_at    INTEGER NOT NULL,
  last_message_at INTEGER,                   -- 列表排序用，避免 JOIN
  message_count INTEGER NOT NULL DEFAULT 0,  -- 冗余计数
  archived      INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (persona_id) REFERENCES personas(id) ON DELETE SET NULL
);
CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);
CREATE INDEX idx_sessions_archived ON sessions(archived, updated_at DESC);

-- 消息
CREATE TABLE messages (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL,
  role          TEXT NOT NULL,               -- system | user | assistant | tool
  content       TEXT,                        -- 文本内容；tool 角色存 JSON 字符串
  tool_calls    TEXT,                        -- JSON 数组（assistant 发起工具调用时）
  tool_call_id  TEXT,                        -- tool 角色关联的调用 id
  plugin_id     TEXT,                        -- 由哪个插件产生（tool 消息）
  status        TEXT NOT NULL DEFAULT 'done',-- pending | streaming | done | error | cancelled
  error_code    TEXT,
  seq           INTEGER NOT NULL,            -- 会话内单调递增序号，排序权威
  created_at    INTEGER NOT NULL,
  tokens_prompt     INTEGER,
  tokens_completion INTEGER,
  meta          TEXT,                        -- JSON，扩展用（附件、模型原始 id 等）
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE INDEX idx_messages_session_seq ON messages(session_id, seq);
CREATE UNIQUE INDEX idx_messages_session_seq_uniq ON messages(session_id, seq);

-- 全文检索（阶段 1+）
CREATE VIRTUAL TABLE messages_fts USING fts5(
  content, content='messages', content_rowid='rowid', tokenize='unicode61'
);
```

**设计说明**：

- `seq` 而非 `created_at` 排序：同一毫秒内可能插入多条（用户消息 + 工具结果），时间戳会乱序。
- `last_message_at` / `message_count` 冗余：会话列表页高频查询，避免每次 COUNT。
- `status = 'streaming'`：流式进行中的消息也落库，App 被杀死后可恢复为 `error` 并保留已收内容。

### 2.2 人设

```sql
CREATE TABLE personas (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  avatar_path   TEXT,
  description   TEXT,
  system_prompt TEXT NOT NULL DEFAULT '',
  greeting      TEXT,
  example_dialogs TEXT,                      -- JSON
  tags          TEXT,                        -- JSON 数组
  source        TEXT NOT NULL DEFAULT 'builtin', -- builtin | imported | plugin | shared
  source_ref    TEXT,                        -- 导入来源（URL / 插件 id / 文件 hash）
  source_plugin TEXT,                        -- 来自哪个插件
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);
CREATE INDEX idx_personas_source ON personas(source);
```

内置默认人设在首次启动时插入，`id = 'builtin.default'`，`source = 'builtin'`，**不可删除**。

### 2.3 插件

```sql
-- 已安装插件
CREATE TABLE plugins (
  id              TEXT PRIMARY KEY,          -- manifest.id
  name            TEXT NOT NULL,
  version         TEXT NOT NULL,             -- 当前启用版本
  description     TEXT,
  author          TEXT,
  icon_path       TEXT,
  manifest_json   TEXT NOT NULL,             -- 原始 manifest 快照
  source          TEXT NOT NULL,             -- local | url | store
  source_ref      TEXT,
  enabled         INTEGER NOT NULL DEFAULT 1,
  auto_start      INTEGER NOT NULL DEFAULT 1,
  installed_at    INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  crash_count     INTEGER NOT NULL DEFAULT 0,
  sha256          TEXT
);

-- 插件版本历史（支持回滚）
CREATE TABLE plugin_versions (
  plugin_id       TEXT NOT NULL,
  version         TEXT NOT NULL,
  manifest_json   TEXT NOT NULL,
  dir_name        TEXT NOT NULL,             -- sandbox 下的目录名
  installed_at    INTEGER NOT NULL,
  is_current      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (plugin_id, version)
);

-- 权限授权
CREATE TABLE plugin_grants (
  plugin_id       TEXT NOT NULL,
  permission      TEXT NOT NULL,
  level           TEXT NOT NULL,             -- install | confirm
  granted_at      INTEGER NOT NULL,
  granted_by      TEXT NOT NULL DEFAULT 'user',
  PRIMARY KEY (plugin_id, permission)
);

-- 插件配置（config.schema 的实例值）
CREATE TABLE plugin_config (
  plugin_id       TEXT NOT NULL,
  key             TEXT NOT NULL,
  value_json      TEXT NOT NULL,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (plugin_id, key)
);

-- 单个工具的启停（用户级）
CREATE TABLE plugin_tool_toggles (
  plugin_id       TEXT NOT NULL,
  tool_name       TEXT NOT NULL,
  enabled         INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (plugin_id, tool_name)
);
```

### 2.4 设置

```sql
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
```

关键键：

| key | 说明 | 是否敏感 |
|---|---|---|
| `onboarded` | 是否完成首次引导 | 否 |
| `theme` | 主题 id | 否 |
| `provider.baseUrl` | 自定义 Base URL | 否 |
| `provider.model` | 模型名 | 否 |
| `provider.apiKey` | **API Key** | **是 → 存安全存储，不在此表** |
| `advanced.unlocked` | 是否解锁高级设置 | 否 |

> **API Key 绝不进 SQLite**。用 `flutter_secure_storage`（Keychain / EncryptedSharedPreferences）。表中只存一个 `provider.apiKeyRef = "secure:provider.apiKey"` 之类的引用。

### 2.5 审计日志

```sql
CREATE TABLE audit_logs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  ts            INTEGER NOT NULL,
  plugin_id     TEXT NOT NULL,               -- '__host__' 表示宿主自身
  plugin_version TEXT,
  kind          TEXT NOT NULL,               -- primitive | permission | plugin | network
  primitive     TEXT,
  permission    TEXT,
  args_digest   TEXT,                        -- JSON，已脱敏
  result        TEXT NOT NULL,               -- ok | denied | error
  error_code    TEXT,
  duration_ms   INTEGER,
  bytes_out     INTEGER
);
CREATE INDEX idx_audit_ts ON audit_logs(ts DESC);
CREATE INDEX idx_audit_plugin ON audit_logs(plugin_id, ts DESC);

-- 清理：删除 30 天前，且每插件保留不超过 2MB（按估算行数）
```

### 2.6 点数与账单（阶段 3）

```sql
-- 本地缓存的余额（权威值在网关）
CREATE TABLE credit_balance (
  id            INTEGER PRIMARY KEY CHECK (id = 1),  -- 单行表
  balance       INTEGER NOT NULL DEFAULT 0,          -- 点数（整数，避免浮点误差）
  updated_at    INTEGER NOT NULL,
  synced_at     INTEGER
);

-- 本地消费记录
CREATE TABLE credit_ledger (
  id            TEXT PRIMARY KEY,
  ts            INTEGER NOT NULL,
  delta         INTEGER NOT NULL,            -- 正=充值，负=消费
  kind          TEXT NOT NULL,               -- topup | consume | refund | redeem
  session_id    TEXT,
  message_id    TEXT,
  plugin_id     TEXT,                        -- 插件发起的模型调用
  tokens_prompt     INTEGER,
  tokens_completion INTEGER,
  note          TEXT,
  remote_id     TEXT                         -- 网关侧流水号，用于对账
);
CREATE INDEX idx_ledger_ts ON credit_ledger(ts DESC);
```

> **权威性原则**：`credit_balance` 只是缓存。每次启动与每次大额消费后与网关对账；不一致时以网关为准并覆盖本地。

### 2.7 迁移

用 Drift 的 `schemaVersion` + `MigrationStrategy`。

```dart
@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (m) async => m.createAll(),
  onUpgrade: (m, from, to) async {
    // 每个版本一段，必须可单独回放
    if (from < 2) { /* v2 变更 */ }
    if (from < 3) { /* v3 变更 */ }
  },
  beforeOpen: (details) async {
    await customStatement('PRAGMA foreign_keys = ON');
    await customStatement('PRAGMA journal_mode = WAL');   // 并发读写
  },
);
```

**规则**：

- 迁移必须**幂等**，且能在任意历史版本上顺序回放。
- 破坏性变更（删列）分两步发布：先停用（新版本），再删除（下下个版本）。
- 每次 schema 变更必须在 `test/` 加一个「从 vN 迁移到最新」的测试用例。

---

## 3. 索引与性能

| 查询场景 | 依赖索引 |
|---|---|
| 会话列表（按更新时间倒序） | `idx_sessions_updated` |
| 打开会话加载消息 | `idx_messages_session_seq` |
| 消息分页（向上翻） | 同上，`WHERE session_id=? AND seq<? ORDER BY seq DESC LIMIT 50` |
| 插件列表 | 主键 |
| 权限校验（**最高频**） | `plugin_grants` 主键；且在内存里做一层缓存 |
| 审计按插件查看 | `idx_audit_plugin` |
| 消息搜索（阶段 1+） | `messages_fts` |

**权限校验缓存**：`Gatekeeper` 启动时把 `plugin_grants` 全量载入内存 `Map<String, Set<Permission>>`，运行时只读内存。授权/撤销时双写（内存 + DB）。这是热路径，不能每次查库。

---

## 4. 插件 state 存储

`state.*` 原语不落 SQLite（避免每插件建表），用**每插件一个 JSON 文件**：

```jsonc
// sandbox/<pluginId>/state.json
{
  "v": 1,
  "data": {
    "lastQuery": "天气",
    "counter": 42,
    "cache": { "k": "v" }
  },
  "updatedAt": 1771033421512
}
```

| 特性 | 说明 |
|---|---|
| 写入策略 | 内存写 + 100ms 防抖落盘（避免高频 `state.set` 打爆 IO） |
| 原子性 | 写临时文件 + rename |
| 容量限制 | 5 MB，超出 `state.set` 返回 `IO_ERROR` |
| 值类型 | 任意 JSON 可序列化值 |
| 隔离 | 文件在插件自己目录内，路径由宿主拼接，插件无法指定 |
| 卸载 | 默认删除；用户可选「保留数据」（重装后恢复） |

---

## 5. 数据生命周期

| 事件 | 影响 |
|---|---|
| 删除会话 | 级联删除 `messages`（`ON DELETE CASCADE`）+ FTS 条目 |
| 删除人设 | `sessions.persona_id` 置 NULL（会话保留，回到默认人设） |
| 停用插件 | 保留沙箱与数据；仅从注册表移除，插槽消失 |
| 卸载插件 | 删除 `plugins` / `plugin_versions` / `plugin_grants` / `plugin_config` / `plugin_tool_toggles` 行；沙箱目录删除（或按用户选择保留 `data/`） |
| 撤销权限 | 删除对应 `plugin_grants` 行 |
| 清空审计 | `DELETE FROM audit_logs` |
| 用户登出（阶段 3） | 保留本地对话（本地优先），清除 Token 与余额缓存 |

---

## 6. 备份与导出（阶段 1+）

- 导出会话为 JSON / Markdown / TavernAI 兼容格式。
- 导出范围可选：单会话 / 全会话 / 含插件配置（**不含权限凭据、不含 API Key**）。
- 导入时插件配置只在对应插件已安装时应用。

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：完整 SQLite schema、沙箱布局、state JSON 存储、生命周期与迁移规则 |
