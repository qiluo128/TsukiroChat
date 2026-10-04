# 18 · 智能体、对话与记忆

> **本文是数据模型的核心规格。** 它修正了早期「会话（Session）是核心单位」的设计 ——
> 那是错的：**智能体（Agent）才是核心单位**，对话与记忆都从属于它。

---

## 1. 为什么这个修正重要

早期设计把「会话」当作顶层容器，人设是会话的一个字段。这在只有一个 AI 角色时看不出问题，
但只要用户想要第二个角色就崩了：

| 场景 | 旧模型（会话为核心） | 新模型（智能体为核心） |
|---|---|---|
| 换一个角色聊天 | 新建会话 + 重设人设 → 旧会话的人设被搅乱 | 新建**智能体**，各自独立 |
| 某角色的长期记忆 | 无处安放（记忆只能挂在会话上，换个会话就失忆） | 挂在智能体上，**所有对话共享** |
| 某角色换模型 | 每个会话都要改 | 改智能体一处 |
| 删除某角色的全部记录 | 要逐个删会话 | 删智能体，级联 |

**一句话：智能体是「一个人」，对话是「和这个人的一次聊天」。**
记忆属于「这个人」，不属于「这一次聊天」—— 否则换个话题就失忆，那不叫陪伴。

---

## 2. 实体关系

```
Agent（智能体）—— 核心单位
├─ id / name / avatar
├─ persona          人设（角色卡、开场白、示例对话、世界书）
├─ model_config     该智能体用哪个服务商 / 模型 / 参数
├─ memory_config    记忆粒度配置
├─ created_at / updated_at
│
├─▶ Conversation（对话）—— 多个
│   ├─ id / agent_id / title
│   ├─ status       active | archived
│   ├─ created_at / updated_at
│   └─▶ Message（消息）—— 多条
│       ├─ id / conversation_id / role
│       ├─ content / rich_content
│       ├─ seq / created_at / metadata
│
└─▶ Memory（记忆）—— 多条
    ├─ id / agent_id
    ├─ conversation_id  可选（默认 null = 智能体级）
    ├─ type             fact | summary | vector | graph
    ├─ content / embedding
    └─ created_at / metadata
```

### 2.1 三条独立性保证

| 维度 | 规则 |
|---|---|
| **智能体之间** | 人设、记忆、模型配置**全独立**，互不影响 |
| **对话之间** | 消息独立；**记忆默认共享**（同属一个智能体的记忆库） |
| **记忆之间** | 默认智能体级；`conversation_id` 非空时表示该条记忆只属于某个对话 |

### 2.2 外键与级联

```
删除 Agent        → 级联删除它的全部 Conversation、Message、Memory
删除 Conversation → 级联删除它的全部 Message
                  → **不删除** Memory（记忆属于智能体，不随对话消亡）
删除 Message      → 级联删除它的 rich_content（同表）
```

> **「删对话不删记忆」是刻意的。** 用户删掉一次聊天记录，不代表他想忘掉那次聊天里
> 提到过的事。记忆的删除是独立操作（用户在记忆管理里显式删）。

---

## 3. 记忆的层级：宿主提供层级，插件决定粒度

这是 `docs/01-overview.md` §4「插件自由度」在数据层的体现。

### 3.1 三个层级

| 层级 | 存什么 | 生命周期 |
|---|---|---|
| **智能体级** | 长期记忆：事实、偏好、关系进展 | 跟智能体同生共死 |
| **对话级** | 本次会话的短期上下文 | 跟对话 |
| **消息级** | 单条消息本身 | 跟消息 |

### 3.2 默认行为

**一个智能体一个记忆库，所有对话共享。** 即：`memory_config.scope = 'agent'`。

这是默认，因为陪伴场景的核心诉求是「记得我」—— 如果每个对话各记各的，
用户开个新话题就要重新自我介绍，那不叫陪伴。

### 3.3 插件可以改粒度

`memory_config` 是**声明**，不是实现：

```jsonc
// manifest.json —— 插件声明"我要接管这个智能体的记忆"
{
  "provides": {
    "memory": {
      "provider": "memory/index.js",
      "capabilities": ["store", "retrieve", "summarize", "compact"],
      "supportedScopes": ["agent", "conversation"],   // 它支持哪些粒度
      "priority": 100
    }
  }
}
```

宿主提供 [MemoryProvider] 接口，插件实现它。宿主**不预设任何记忆策略** ——
不预设"该记什么"、不预设"怎么检索"、不预设"怎么压缩"。

### 3.4 记忆数据模型（宿主侧兜底）

即使没有任何记忆插件，宿主也要能存"最朴素的那种记忆"（一句话一段文本），
否则用户装了三个记忆插件之前，数据是无处可放的。所以：

```
Memory
├─ id
├─ agent_id          必需
├─ conversation_id   可选；null = 智能体级
├─ type              fact | summary | vector | graph
├─ content           文本内容
├─ embedding         BLOB，可选（向量检索用，阶段 7）
├─ source_message_ids JSON 数组，可追溯"这条记忆是从哪几句来的"
├─ created_at
└─ metadata          JSON，插件私有数据（放在 metadata.<pluginId> 下）
```

`type` 是**开放式枚举**：宿主认识 `fact` / `summary`，其余类型插件自定义，
宿主只当作字符串存储与返回。这样加新记忆类型不需要改宿主。

---

## 4. 服务商与模型（多服务商）

用户的要求：「选模型时会显示哪个模型来自哪个服务商」。

### 4.1 数据模型

```
Provider（服务商）
├─ id
├─ name              显示名，如「测试中转站」
├─ protocol          openai | anthropic | google
├─ base_url
├─ api_key           ⚠ 见 §4.3
├─ is_official       是否我们的官方服务（不可删除）
├─ sort_order
└─ created_at

ProviderModel（某个服务商下的模型）
├─ id                模型名，如 deepseek-v4.1-flash
├─ provider_id
├─ display_name
├─ context_window
├─ discovered_at     从 /v1/models 拉到的时间（null = 手动添加）
└─ is_manual         用户手动加的（有些中转站的模型表不全）
```

### 4.2 为什么模型要单独一张表

「模型」不是服务商的一个字段，而是**实体**，因为：

1. **来源要能显示**：`ProviderModel` 天然带 `provider_id`，UI 直接 join 出服务商名
2. **模型表是动态的**：中转站上游换模型、加路由都会变，需要能"刷新"，
   同时保留用户**手动添加**的那些（`is_manual = true`，刷新时不删）
3. **同一个模型名可能来自多个服务商**（比如两家中转站都有 `gpt-4o`），
   模型名不是全局唯一键，`(provider_id, id)` 才是

### 4.3 API Key 的存储位置

`docs/02-requirements.md` 的 NFR-SEC-05 要求凭据进安全存储
（Keychain / EncryptedSharedPreferences）。

**当前实现状态**：Demo 阶段先存在 SQLite 的 `providers.api_key` 列里，
并**在设置页明确标注**这一点。理由与迁移路径：

- 客户端目前还是直连上游（用户自带 Key），与「密钥只在后端」的最终形态不同
- SQLite 存在应用私有目录，未 root 的设备上其他应用读不到
- 真正需要防的是**备份导出**与**多用户设备**，那两件事在 Demo 阶段都还不存在

**迁移路径**：阶段 3 引入网关后，客户端不再持有上游 Key，
`providers.api_key` 整列删除，改为只存用户 Token（进安全存储）。

---

## 5. 设置页的信息架构

用户明确要求的结构：

```
设置
├─ 模型配置                          ← 单独一个入口
│  ├─ 【官方服务】默认分区的替代        ← 不必选分区，充值即用
│  │   ├─ 余额 / 额度
│  │   ├─ 兑换码
│  │   └─ 充值入口
│  │   （本期只留 UI，不实现）
│  │
│  └─ 配置 API
│     ├─ 已添加的服务商列表（含模型数）
│     └─ 添加服务商
│        ├─ 名称 / 协议 / Base URL / API Key
│        └─ 拉取模型表 / 手动添加模型
│
├─ 对话
├─ 关于
```

**关键设计**：官方服务与自建服务商**在同一个列表里**，官方那个置顶且不可删除。
不给用户「选分区」的负担 —— 默认就走官方，想折腾再往下拉配置 API。

选模型时，每一项都显示来源：

```
选择模型
├─ 官方服务
│  └─ tsukiro-chat-pro          官方服务 · 1.2 元/万 token
└─ 测试中转站
   ├─ deepseek-v4.1-flash       测试中转站
   └─ deepseek-v4-pro           测试中转站
```

---

## 6. 去掉默认人设

用户要求：**AI 不要有默认人设。**

原来的设计里内置了一个「雪」的角色（`docs/12-demo-plan.md` §2 的「内置一个默认角色」），
这与「智能体是核心单位」冲突 —— 有默认人设，就等于宿主编排了一个特定角色，
而正确的做法是**用户新建智能体时自己填人设**。

改动：

| 位置 | 原来 | 现在 |
|---|---|---|
| `dev-config.json` | 有 `persona` 段（雪） | **删掉** |
| `AppConfig` | 提供 `persona` | **不再提供** |
| 首次启动 | 无 | 创建一个**空人设**的默认智能体，名字「新智能体」 |
| `AgentLoop` | 必须有 persona | persona 为空时**不注 system 消息** |

> **为什么空人设时连 system 消息都不发，而不是发一句"你是一个助手"**：
> 用户没设人设时，任何宿主自作的系统提示词都是在替他做决定。
> 上游模型有自己的默认行为，那才是中立的起点。

---

## 7. 与插件的边界

| 事实 | 说明 |
|---|---|
| 插件**不绑定**智能体 | 插件是全局安装的，智能体是用户创建的，两者不是从属关系 |
| 插件可以往智能体界面塞 UI | 通过插槽 `agent.header` / `agent.actions` / `agent.sections` |
| 插件可以有自己的独立界面 | 不依赖智能体，走 `provides.pages` |
| 插件可以选择记忆粒度 | 通过 `memory_config` + `MemoryProvider` 实现 |
| 插件不能读别的插件的记忆 | `metadata` 按 `<pluginId>` 命名空间隔离 |

### 7.1 新增插槽

在 `docs/08-ui-slots.md` 的清单上补三个智能体相关插槽：

```
agent.header        智能体界面标题栏（状态指示）
agent.actions       智能体界面操作区（编辑、分享）
agent.sections      智能体详情页分区（心情面板、记忆管理入口）
```

---

## 8. 落地清单

| # | 事项 | 状态 |
|---|---|---|
| 1 | 数据表 `agents` / `conversations` / `messages` / `memories` / `providers` / `provider_models` | 本文档同批 |
| 2 | schema v1 → v2 迁移（`sessions` 拆成 `conversations` + 默认智能体） | 本文档同批 |
| 3 | 去掉默认人设 | 本文档同批 |
| 4 | 智能体 CRUD + 编辑页 | 本文档同批 |
| 5 | 对话归档 / 恢复 | 本文档同批 |
| 6 | 服务商注册表 + 模型选源 | 本文档同批 |
| 7 | 设置页重构（模型配置入口） | 本文档同批 |
| 8 | 官方服务（余额 / 兑换码 / 充值） | ⬜ **只留 UI，阶段 3 实现** |
| 9 | `MemoryProvider` 接口与默认实现 | ⬜ 阶段 7 |
| 10 | `api_key` 迁到安全存储 | ⬜ 阶段 3（网关上线后整列删除） |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10 | 初版：智能体为核心单位的修正、三层记忆、多服务商、设置页信息架构、去默认人设 |
