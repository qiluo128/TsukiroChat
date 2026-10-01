# 09 · 工具与 Agent 循环

> 本文定义两件事：**插件如何给模型加能力**（现在开放），以及**未来如何接管 Agent 循环**（L7，仅留接口）。

---

## 1. 工具注册

### 1.1 从 manifest 到工具表

```
插件安装
  └─▶ manifest.provides.tools[]
        └─▶ ToolRegistry.register()
              ├─ 校验 name 唯一性（冲突则加插件前缀）
              ├─ 校验 handler 文件存在
              ├─ 记录 permissions（工具级）
              └─ 工具表新增条目
```

注册表条目：

```dart
class RegisteredTool {
  final String name;            // 暴露给模型的名字
  final String description;
  final Map<String, dynamic> parameters;   // JSON Schema
  final String pluginId;
  final String pluginVersion;
  final String handler;         // 包内相对路径
  final List<String> permissions;
  final int timeoutMs;
  final bool dangerous;
}
```

### 1.2 工具名冲突

```
插件 A 注册 get_time  →  工具表: get_time            (A)
插件 B 也注册 get_time →  冲突，B 的改名为: b.get_time  (B)
                         且审计记录一次 tool.name_conflict
```

暴露给模型的名字里**不允许**出现 `.`（部分 Provider 的 function name 只接受 `[a-zA-Z0-9_-]`），因此实际使用 `b__get_time`。**不静默覆盖**是硬规则 —— 覆盖会让先装的插件莫名失效。

### 1.3 工具表 → Provider 格式

内部统一用 **JSON Schema**，各 Provider 适配：

```jsonc
// 内部表示
{ "name": "get_time",
  "description": "获取当前时间…",
  "parameters": { "type":"object", "properties": {...}, "required":[] } }
```

```jsonc
// OpenAI 兼容
{ "type": "function",
  "function": { "name": "get_time", "description": "...", "parameters": {...} } }
```

Demo 阶段只接 OpenAI 兼容格式。

### 1.4 工具可见性过滤

送给模型的工具表 = 全量工具 − 不可见工具。三个过滤源：

| 过滤源 | 规则 |
|---|---|
| 权限 | 插件被撤销 `model.chat` 或其工具所需权限被撤销 → 该工具不可见 |
| Skill 白名单 | 若启用了某个 Skill，只保留 `allowedTools`（空数组 = 全部） |
| 用户开关 | 用户可在插件详情页关闭单个工具 |

> **为什么按权限过滤工具**：如果一个工具必然因权限不足而失败，把它给模型只会浪费一次往返并产生无意义的错误。提前隐藏是更干净的做法。

---

## 2. Agent 循环

### 2.1 循环形态

```
AgentLoop.run(sessionId)
  │
  ├─① 组装上下文
  │     persona.systemPrompt
  │   + skill.systemPrompt（若启用）
  │   + 最近 N 条消息（N 由 token 预算决定，不是固定条数）
  │   + 用户新消息
  │
  ├─② 装载工具表（§1.4 过滤后）
  │
  ├─③ 调用模型（流式）
  │     ├─ 收到文本 delta  → 推给 UI
  │     └─ 收到 tool_calls → 累积到工具调用缓冲
  │
  ├─④ 流结束判定
  │     ├─ 有 tool_calls → 进入 ⑤
  │     └─ 无 tool_calls → 进入 ⑦
  │
  ├─⑤ 逐个执行工具（可并行，见 2.3）
  │     ├─ Gatekeeper 校验权限
  │     ├─ Bridge inv tool.invoke → 插件执行
  │     ├─ 结果 / 错误 包装成 role:"tool" 消息
  │     └─ 写审计
  │
  ├─⑥ 把工具结果追加进上下文 → 回到 ③
  │     ⚠ 步数上限 maxSteps（默认 8）→ 超出则以「已达工具调用上限」结束
  │
  └─⑦ 定稿：写入 SQLite（消息 + usage）→ 触发 chat.afterReply 事件
```

### 2.2 终止条件（缺一不可）

| 条件 | 默认 | 超出行为 |
|---|---|---|
| 最大步数 | 8 | 停止循环，把已有内容作为回复，附注「工具调用已达上限」 |
| 单次超时 | 120s | 中断，流式内容保留 |
| 用户取消 | — | 立即中断，已输出内容保留 |
| Token 预算 | 上下文窗口的 80% | 触发历史压缩（阶段 7）或截断 |
| 点数余额 | > 0 | 不足 → 停止并引导充值 |

**必须有步数上限**。没有上限的 Agent 循环遇到「模型反复调同一个工具」会无限烧钱，这是同类产品最常见的线上事故。

### 2.3 工具并行执行

同一轮里多个 `tool_calls`：

| 情况 | 策略 |
|---|---|
| 全部来自不同插件 | **并行**执行 |
| 同一插件的多个工具 | **串行**（插件是单 WebView，并行会引起状态竞争） |
| 含 `dangerous: true` | 串行，且每个都要确认 |
| 含 `confirm` 级权限 | 串行（每个都要弹确认框） |

### 2.4 工具执行失败的处理

**工具失败不中断对话**。失败结果原样交给模型：

```jsonc
{ "role": "tool", "tool_call_id": "call_abc", "content":
  "{\"ok\":false,\"error\":{\"code\":\"PERMISSION_DENIED\",\"message\":\"插件未获得 sys.time 权限\"}}" }
```

模型会看到错误并自行组织语言（理想情况下告诉用户「我需要时间权限」）。这比宿主直接弹错误框体验好得多。

**唯一例外**：工具失败率过高（连续 3 次同一工具失败）→ 宿主在 UI 上给一次提示「某插件似乎有问题」，并把该工具从本轮可见列表中移除，避免模型死循环重试。

---

## 3. 可替换步骤架构（为 L7 预留）

宿主内部**从第一天起**就把循环拆成可替换步骤。这样 L7 放开时不需要重构。

### 3.1 步骤定义

```dart
abstract class AgentStep {
  String get id;
  /// 返回 null 表示不干预，继续默认行为
  Future<StepResult?> run(AgentContext ctx);
}

class AgentContext {
  final String sessionId;
  final List<ChatMessage> messages;
  final List<RegisteredTool> tools;
  final Map<String, dynamic> config;
  final CancellationToken cancel;
  // 可变部分
  List<ChatMessage> get mutableMessages;
  List<RegisteredTool> get mutableTools;
}
```

### 3.2 默认循环的步骤列表

| 步骤 id | 钩子位置 | 默认行为 |
|---|---|---|
| `context.build` | 调用模型前 | 组装 persona + skill + 历史 |
| `tools.filter` | 调用模型前 | 按权限/Skill/开关过滤工具表 |
| `pre.model` | 调用模型前 | 无操作 |
| `model.call` | — | 发起流式请求 |
| `post.model` | 模型返回后 | 无操作 |
| `tool.dispatch` | 工具执行前 | 权限校验 + 分发 |
| `post.tool` | 工具执行后 | 无操作 |
| `context.compact` | 上下文超预算时 | 截断（阶段 7 换成记忆系统） |
| `finish` | 循环结束 | 落库 + 发事件 |

### 3.3 预留接口（本阶段**不暴露**给插件）

```dart
/// L7 预留 —— 本阶段仅内部使用，插件无法调用
abstract class HarnessRuntime {
  /// 替换某个既有步骤
  void registerStep(String stepId, AgentStep step, {StepMode mode = StepMode.replace});

  /// 注册一个全新步骤，插在指定步骤之前/之后
  void insertStep(String afterStepId, AgentStep step);

  /// 完全接管整个循环
  void registerRuntime(String runtimeId, AgentRuntime runtime);
}

enum StepMode { before, after, replace, wrap }
```

对应 manifest 的 `harness` 字段（见 [04 § 2.10](04-plugin-spec.md)）。**本阶段宿主解析该字段但忽略执行**，仅记录日志，便于验证 schema 是否留够。

### 3.4 L7 放开时的兼容承诺

> **插件今天写的工具，未来在 harness 插件里照样能用。**

保证方式：

- 工具的注册表、参数 schema、handler 调用方式**在 L7 下不变**。
- harness 插件拿到的是同一个 `ToolRegistry` 和同一个 `tool.call` 分发器。
- `tool.invoke` 的 Bridge 消息格式不变。

即：**L7 只增加「决定何时调哪个工具」的自由度，不改变「工具怎么被调用」的机制。**

---

## 4. 模型调用

### 4.1 请求构造

```jsonc
{
  "model": "default",                    // 逻辑模型名，宿主映射
  "messages": [
    { "role": "system",    "content": "<persona>" },
    { "role": "user",      "content": "现在几点了？" },
    { "role": "assistant", "content": null, "tool_calls": [
        { "id": "call_abc", "type": "function",
          "function": { "name": "get_time", "arguments": "{\"timezone\":\"Asia/Shanghai\"}" } } ] },
    { "role": "tool", "tool_call_id": "call_abc", "content": "{\"time\":\"...\"}" }
  ],
  "tools": [ /* §1.3 */ ],
  "tool_choice": "auto",
  "stream": true,
  "temperature": 0.8
}
```

### 4.2 两个入口，同一份实现

| 入口 | 使用方 | 凭据来源 |
|---|---|---|
| 聊天页 | 宿主 AgentLoop | 用户高级设置里的 Key（Demo）/ 网关 Token（正式版） |
| `model.chat` 原语 | 插件 | **同上，由宿主代发** |

**关键**：插件走的是同一个 `ModelClient`，但：

- 插件**不能**传 `baseUrl`、`apiKey`、`headers`（参数 schema 里没有）。
- 插件的 `model` 参数只接受逻辑名。
- 插件调用被限流（30 次/分钟）并计入用户点数。
- 插件调用写审计（只记 token 数，不记内容）。

### 4.3 流式解析要点

- SSE 行缓冲必须处理**跨 chunk 截断**（一个 `data:` 行可能被切成两半）。
- 必须处理 `data: [DONE]`。
- `tool_calls` 的 `arguments` 是**分片拼接**的 JSON 字符串，必须累加到流结束才能 parse。
- 中途网络中断：重试策略为「未收到任何 token 才重试」，已收到 token 则报错但保留已输出内容（避免用户看到内容被重置）。

---

## 5. Demo 阶段的最小实现

Demo 不需要完整的步骤架构，但**接口要按最终形态写**，只是内部只有默认实现。

| 项 | Demo | 后续 |
|---|---|---|
| 工具注册 | ✅ 完整 | — |
| 工具调用循环 | ✅ 但 `maxSteps = 3` | 提到 8 |
| 并行工具执行 | ❌ 全部串行 | 实现 |
| 步骤系统 | ✅ 接口 + 默认 9 个步骤 | 开放给插件 |
| 历史压缩 | ❌ 硬截断最近 20 条 | 记忆系统 |
| 多模型路由 | ❌ 单模型 | 网关 |
| 重试 | ✅ 仅网络层，1 次 | 更细的策略 |
| 点数扣减 | ❌ 用用户自己的 Key | 网关计费 |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：工具注册与冲突、Agent 循环与终止条件、可替换步骤架构、L7 预留接口与兼容承诺 |
