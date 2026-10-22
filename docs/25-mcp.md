# 25 · MCP 接入

> 状态：设计定稿，待实现
> 相关：`docs/24-agent-tools.md`、`docs/22-capability-market.md`

---

## 1. 定位

MCP 是**能力来源**，不是**安全方案**。

| | 插件 | MCP |
|---|---|---|
| 代码在哪 | 我们进程内（WebView） | 别人的服务器 |
| 能碰宿主资源 | ✅ | ❌ **碰不到** |
| 我们该管什么 | 它能用哪些宿主能力 | 我们**发给它**什么 |

所以：**不给 MCP 加能力门禁。** 理由见 §6。

---

## 2. 方向：只做 Client

```
方向 A  Tsukiro 当 MCP Client  ← 做这个：接入外部 server，扩展 AI 能力
方向 B  Tsukiro 当 MCP Server  ← 不做：需要别的设备连手机，场景窄
```

目录里已有的 `mcp.serve/stop/status` 三个占位声明对应**方向 B**，
保留不动（它们不是错的，只是不做）。

**两者代码几乎没有重叠**，所以那三个占位不能当作"MCP 已经有了"。

---

## 3. 传输：先只支持 HTTP

| 传输 | Android |
|---|---|
| **stdio**（本地子进程） | ❌ 需要 exec，没有就是没有 |
| **HTTP**（JSON-RPC POST） | ✅ 做这个 |
| SSE（流式） | ⏳ 第二阶段 |

> 结论：**Android 上的 MCP 是"连远程"，不是"跑本地"。**

---

## 4. 数据结构

```sql
CREATE TABLE mcp_connections (
  id          TEXT PRIMARY KEY,      -- 'mcp:dev.example.weather'
  name        TEXT NOT NULL,         -- 显示名
  url         TEXT NOT NULL,         -- JSON-RPC endpoint
  transport   TEXT NOT NULL,         -- 目前只有 'http'
  headers     TEXT,                  -- JSON，鉴权头等
  source      TEXT NOT NULL,         -- 'manual' | 'plugin:<pluginId>'
  enabled     INTEGER NOT NULL DEFAULT 1,
  created_at  TEXT NOT NULL
);
```

`source` 区分**手动添加**和**插件带来**的 —— 卸载插件时只删它带来的那些。

**刻意没有 `permissions` 字段**（见 §6）。

---

## 5. 协议实现（最小）

```
POST {url}
Content-Type: application/json
{ "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {} }
```

三步：

| 步骤 | 方法 | 用途 |
|---|---|---|
| 1 | `initialize` | 交换协议版本 / server 信息 |
| 2 | `tools/list` | 拿工具表 |
| 3 | `tools/call` | 调工具 |

**超时**：`initialize` 10s，`tools/call` 60s（工具可能慢）。
**上限**：响应体 1MB（和桥接一致）；`tools/call` 的**参数大小**要记进审计。

---

## 6. 为什么不做能力门禁

我们的权限体系保护的全是**宿主资源**：文件、通讯录、短信、API 额度、界面。

**MCP server 一个都碰不到。** 它在自己服务器上做什么，我们批不批准都改变不了。

所以对它做"能力门禁"是**表演**，不是防护 —— 而且会增加摩擦（每次工具调用弹框，MCP 就没法用了）。

### 我们的真实问题不是"它能做什么"

是：

> **模型会把我们的哪些数据发给它。**

这是**出站数据**问题，不是入站能力问题。

### 所以做三件事，不做门禁

**① 连接时告知**（一次，不是每次）

```
添加 MCP Server
  URL: https://…
  ⚠️ 这个服务器会看到你发给它的任何内容。
     模型调用它的工具时，可能把文件内容作为参数传出去。
  [取消]  [添加]
```

用户输入 URL 这个动作本身就是同意。

**② 审计**

每次 `tools/call` 记：server / tool 名 / **参数字节数** / 耗时。
复用 `AuditSink`，`pluginId = 'mcp:<id>'`。

参数大小是关键 —— 它能回答"是不是把什么大东西发出去了"。

**③ 结果标注来源**

喂给模型时明确标出：

```
[来自 MCP server "天气服务" 的工具结果]
```

抵御不了注入，但比没有好。

### 同意的位置决定要不要门禁

| 场景 | 同意在哪 | 要不要门禁 |
|---|---|---|
| 用户手动填 URL | 填的那一刻 | ❌ 不需要 |
| **插件一键添加** | 装插件那一刻 | ❌ 不需要，但**必须显式说明** |
| 未来的 MCP 市场（一键订阅） | 无 | ✅ **必须有** |

现在只做前两种。

---

## 7. 插件格式：`provides.mcp`

**这是一键配置的落点。** 插件只要在清单里声明，装上就连。

```jsonc
{
  "id": "dev.example.weather-mcp",
  "name": "天气 MCP",
  "version": "1.0.0",
  "runtime": { "main": "index.js" },   // 可选：不需要代码的可以省
  "provides": {
    "mcp": {
      "name": "天气服务",
      "transport": "http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer xxx" },
      "enabledByDefault": true
    }
  }
}
```

### 语义

| 事件 | 行为 |
|---|---|
| 装插件 | **创建一条连接**（`source = 'plugin:<id>'`），默认 `enabled` |
| 启用/停用插件 | 同步启用/停用连接 |
| 卸载插件 | 删掉它带来的连接 |
| 插件升级 | 更新 url / headers（**用户手改过的话要提示冲突**） |

### 为什么用插件格式

复用了已有的三样东西：**安装流程、权限告知界面、卸载清理**。

不需要新的分发机制，也不需要新的信任讨论 —— **"装插件"就是同意**。

### UI 必须显式说明

装一个 `provides.mcp` 的插件时，卡片上要写清楚：

```
⚠️ 这个插件会添加一个外部服务连接
   天气服务（https://mcp.example.com/mcp）
   AI 调用它的工具时，会把参数发送到该地址。
```

**不能只写"提供 MCP 支持"** —— 用户需要知道数据会去哪。

---

## 8. 工具注册映射

```
MCP server 的一个连接  →  一个虚拟插件（pluginId = 'mcp:<connectionId>'）
      tools/list       →  ToolRegistry.registerPlugin(合成 manifest)
      tools/call       →  走已有 invokeTool 通路
```

工具名加前缀避免冲突：`mcp__<connectionName>__<toolName>`。

**注册的 tool 不带 permissions**（`<String>[]`）—— 空权限列表过门禁时是 `allow`，
正好符合"MCP 不需要门禁"。

> 这里有个隐含依赖：`gatekeeper.check(id, null)` 对未注册的 pluginId 返回
> `unknownPlugin`（fail-closed）。所以 MCP 连接**必须**在 Gatekeeper 里登记
> 一个空权限集合，否则工具全被拒。
> 复用 `registerHost` 的模式，加 `registerExternal(id)`。

---

## 9. 设置界面

**设置 → 高级 → MCP 服务**

```
┌──────────────────────────────────┐
│ MCP 服务                    [+]   │
├──────────────────────────────────┤
│ 天气服务                    ● 开  │
│ https://mcp.example.com/mcp       │
│ 来源：插件「天气 MCP」             │
│                           ⋯ 菜单  │
├──────────────────────────────────┤
│ 我的文件服务               ○ 关   │
│ http://192.168.1.10:8080          │
│ 来源：手动添加                    │
└──────────────────────────────────┘
```

`⋯` 菜单：编辑 / 测试连接 / 查看工具 / 删除。

**「测试连接」** 走 `initialize` + `tools/list`，显示工具数或错误原文
（不美化错误 —— 原文才是能定位问题的那一行）。

---

## 10. 不做的事

| 不做 | 理由 |
|---|---|
| 能力门禁 | §6 |
| stdio 传输 | 需要 exec |
| MCP Server（方向 B） | 场景窄 |
| prompts / resources 两类能力 | 先只做 tools |
| 自动更新 server 列表 | 需要市场，那时才需要门禁 |

---

## 11. 验证清单

实现后必须验证：

1. 手动添加一个 MCP 连接 → 能 `initialize` + `tools/list`
2. 工具出现在模型看到的工具表里
3. `tools/call` 能拿到结果并回给模型
4. server 不可达时**明确报错**，不影响其它工具
5. 装一个 `provides.mcp` 的插件 → 自动建连接
6. 卸载该插件 → 连接被删
7. 审计里有 `mcp:<id>` 的记录，含参数字节数
8. **未登记的 pluginId 仍然被拒**（防退化：加 `registerExternal` 不能顺手放行所有人）

第 8 条最重要 —— 和第 1、2 步做宿主工具时同一个理由。
