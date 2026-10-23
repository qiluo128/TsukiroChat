# 26 · 逐智能体的配置（插件 / MCP / 工具 / 参数）

> 状态：**先记录，不实现**。等正式 UI 阶段再做。
> 结论：**不需要结构性重构**，但比我最初估的大 —— 见 §6。

---

## 1. 现状：所有配置都是**全局**的

| 项 | 在哪 | 作用域 |
|---|---|---|
| 插件安装/启用 | `PluginHost._plugins[].enabled` | 全局 |
| 插件权限授予 | `gatekeeper._granted[pluginId]` | 全局（按插件） |
| 插件配置项 | `plugin.config.<pluginId>.<key>` | 全局 |
| 插件工具 | `ToolRegistry` | 全局 |
| MCP 连接 | `mcp.connections`（settings 一条 JSON） | 全局 |
| MCP 工具 | `ToolRegistry`（`pluginId = mcp:<id>`） | 全局 |

**结果**：装了「天气插件」，每个智能体都能用；配了「麦当劳 MCP」，
每个智能体的模型都能看到那 35 个工具。

---

## 2. 两层语义（不可混淆）

### ① 遮蔽层（Scope / Visibility）

> 一个插件的**对外贡献**，对某个智能体是否**生效**。

"对外贡献"包含三类，**三类都要在遮蔽层里**：

| 贡献 | 例子 | 能否逐智能体 |
|---|---|---|
| **工具** | 天气插件的 `get_weather` | ✅ 上下文里就有 agentId |
| **UI 内容** | 礼物插件在主页加「礼物展馆」 | ⚠️ **取决于插槽是否有 agent 上下文** |
| **参数** | MCP 的请求 token | ✅ 调用的发起方是某个智能体 |

#### UI 内容的关键限制：**插槽有没有 agent 上下文**

| 插槽 | 上下文里有 agentId | 能否逐智能体 |
|---|---|---|
| `agent.actions` / `agent.sections` | ✅ | ✅ |
| `chat.toolbar` / `chat.main` | ✅ | ✅ |
| **`home.cards` / `home.background`** | ❌ 主页不属于任何智能体 | ❌ **只能全局** |
| `settings.sections` | ❌ | ❌ |

**所以礼物插件的正确定位是：**

```
插件本身全局启用  → 主页礼物展馆显示（这是全局贡献）
逐智能体开关     → 是否给这个 agent 的模型提供「送礼物」工具
                   （以及展馆里看到的是哪些礼物）
```

**这不是妥协，是它本来的语义**：主页属于"这个应用"，不属于某个 agent。

> 一条可执行的规则：**遮蔽层只作用于上下文里带 `agentId` 的东西。**
> 不带 agentId 的插槽只有"全局开/关"，没有"逐智能体"。

### ② 授权层（Authority）

> 这个插件对某智能体**完全**不可用 —— 包括钩子、后台任务。

**仍然不做**，理由见 §5。

---

## 3. 参数：全局默认 + 逐智能体覆盖

需求原文：

> "一些插件可以设置全局参数也可以逐智能体设置局部参数，
> 比如 mcp 插件可以为不同智能体调 mcp 时让用户选择不同的请求 token"

这是明确且必要的。**解析顺序**：

```
逐智能体覆盖  →  全局插件配置  →  字段默认值
```

---

## 4. 数据（两张表）

```sql
-- ① 逐智能体的启用开关
CREATE TABLE agent_scope (
  agent_id TEXT NOT NULL,
  target   TEXT NOT NULL,   -- 'plugin:<id>' | 'mcp:<connectionId>'
  enabled  INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (agent_id, target)
);

-- ② 逐智能体的参数覆盖
CREATE TABLE agent_config (
  agent_id  TEXT NOT NULL,
  plugin_id TEXT NOT NULL,
  key       TEXT NOT NULL,
  value     TEXT NOT NULL,  -- JSON
  PRIMARY KEY (agent_id, plugin_id, key)
);
```

**没有行 = 继承全局。** 升级后老用户行为不变。

---

## 5. 为什么授权层仍然不做

1. 遮蔽层已经满足"每个智能体用不同的插件/MCP/参数"这个诉求
2. 改 `gatekeeper.check` 加 `agentId` 维度 = **动安全核心**。
   这个月已经在权限层犯过几次（`__host__` 没登记、
   `registerExternal` 差点放行所有人），不适合再叠维度
3. 遮蔽有**明确的降级行为**：插件还在跑，只是不 offer 给这个 agent

### 但要写清一条限制

> **遮蔽 ≠ 授权。** 屏蔽工具**不能**阻止一个插件的钩子和后台行为。

真有"绝对不许碰 A"的需求时再做授权维度。现在没有。

---

## 6. 逐智能体 token 会**改变 MCP 那层的设计**（这一节是重点）

我最初的方案把 token 在启动时**拼进 `McpConnection.headers` 并落库**。
逐智能体 token 直接推翻这个做法。

### 为什么

```
现在： syncFromPlugins 读一次 config.token
       → headers 存进 mcp.connections
       → 启动时连一次

逐智能体：同一个连接，A 用 token1、B 用 token2
       → headers 不能在连接上，必须在**每次调用时**按 agent 现算
```

### 更重要的是：**一个连接可能对应多个登录身份**

token 不同 = 麦当劳账号不同 = **`tools/list` 可能不同**（不同账号能看到的东西不一样）。
所以不能只"换头"，可能要**每个 (连接, 智能体) 一个 client 实例**。

### 两个可选实现，代价差很大

| 方案 | 做法 | 代价 | 风险 |
|---|---|---|---|
| **A. 按调用注头** | 一个 client，`callTool(headers:)` 每次传 | 小 | 若工具表因账号而异 → 工具列表是"某一次的"，可能不准 |
| **B. 每 (连接, agent) 一个 client** | `_live[connectionId][agentId]` | 大：N 个 WebView 之外的 HTTP client + N 倍 `tools/list` | 但语义正确 |

**选择依据**：如果 MCP server 的工具表与账号无关（多数是这样），A 够用且便宜；
如果工具表随账号变，必须 B。

> **这件事现在不能拍板，因为没有第二个账号可测。**
> 建议：**先按 A 实现**（按调用注头），并在代码里留一句
> "如果发现工具表因账号而异，改成按 (连接, agent) 建 client"。
> 这也是唯一能在只有一个 token 的情况下验证的方案。

### 对现有代码的影响

| 现在 | 要改成 |
|---|---|
| `McpConnection.headers` 存 token | plugin 来源的连接**不存** token；headers 从配置现算 |
| `McpService.callTool(connectionId, tool, args)` | 加 `agentId` |
| `ChatController` 的 MCP 分派 | 传当前 agentId |
| `McpClient` 的 headers 在构造时固定 | `callTool(..., {headers})` 支持按调用覆盖 |

**这是真实的结构性改动**，但只动 MCP 层内部，不影响插件系统。

---

## 7. 估算（修正我最初的说法）

我最初写"可见性 = 半天"。**在加上 UI 贡献和逐智能体参数之后，这个估算不成立。**

| 块 | 估算 | 说明 |
|---|---|---|
| `agent_scope` + `agent_config` 两张表 + 读写 | 小 | 纯数据 |
| 工具过滤（`toOpenAiTools(allowed:)`） | 小 | 2 处调用点 |
| **UI 插槽过滤**（带 agentId 的那些） | 小 | `visibleUi` 已带上下文 |
| **逐智能体参数解析 + 配置 UI** | **中** | 要在 `PluginConfigPage` 上加"这是全局还是这个 agent"的选择 |
| **MCP 按调用注头 + agentId 贯通** | **中** | 见 §6，要动 MCP 内部 |
| 授权层 | **不做** | 见 §5 |

**总体：中等，不是小。** 但仍然是**加法**（新增过滤层和两张表），
**不需要重构现有结构** —— 这一点最初判断成立。

---

## 8. 附带记录：UI 目前的简陋之处

| 项 | 说明 |
|---|---|
| 逐智能体插件 / MCP / 参数 | 见本文档 |
| 工作区时间线没有筛选 | 只有全量列表 |
| 插件市场没有分类/搜索 | 未开始 |
| 设置页没有分组导航 | 一长条 `ListView` |
| 逐智能体背景 | `appearance.chat.background` 是全局 key |

最后一条特别便宜：改成 `appearance.chat.background.<agentId>` 即可，
**没有结构变化**。

### 一个建议加进正式 UI 阶段的东西

**「这个智能体能看见什么」应该是可预览的列表，而不是一堆开关。**

```
这个智能体能用：
  ☑ 时间插件        3 个工具
  ☑ 麦当劳 MCP      35 个工具
  ☐ 礼物插件
→ 38 个工具会进上下文
```

理由：**开关的后果是"进上下文"**，不是"装了/没装"。
让用户看到工具数，他才能判断这个 agent 的上下文预算被吃掉多少 ——
那直接影响回答质量和费用。

现在**没有任何地方能看到"这个 agent 一共能看到多少工具"**，是个盲区。
