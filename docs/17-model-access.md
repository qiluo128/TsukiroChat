# 17 · 模型接入层

> 宿主用哪套协议、怎么切供应商、模型名从哪来、以及**实测确认过哪些真实行为**。
>
> 代码在 `packages/model_gateway`（纯 Dart，可脱离 Flutter 单测，也能直接连真实 API）。

---

## 1. 为什么需要独立一层

三件事让「直接调 OpenAI 接口」不够用：

1. **协议不止一套。** OpenAI / Anthropic / Google 的请求体、鉴权、工具调用表示、
   流式增量格式**全都不同** —— 不是改个路径那么简单。
2. **模型名不能写死。** 中转站的模型是动态的（上游换模型、加路由都会变），
   把名字写进客户端迟早失效。必须能从供应商拉模型表。
3. **推理模型是新常态。** `deepseek-v4.1-flash` 这类模型有独立的思维链字段、
   token 预算包含思维链、响应时间可能是普通模型的十倍。这些都必须在接入层处理掉，
   不能漏给上层。

所以：接入层把三套协议收敛成一套 `ModelRequest` / `ModelReply`，
上层（Agent 循环、`model.chat` 原语、插件）看不到协议差异。

---

## 2. 三套协议的差异（实现要点）

| | OpenAI 兼容 | Anthropic | Google Gemini |
|---|---|---|---|
| 聊天路径 | `POST {base}/chat/completions` | `POST {base}/messages` | `POST {base}/models/{model}:generateContent` |
| 模型表 | `GET {base}/models` | `GET {base}/models` | `GET {base}/models` |
| 鉴权 | `Authorization: Bearer` | `x-api-key` + `anthropic-version` | `?key=` 查询参数 |
| system prompt | messages 里 `role:system` | **顶层 `system` 字段** | **`systemInstruction`** |
| 必填字段 | `model`、`messages` | 还要 `max_tokens` | — |
| 工具定义 | `tools[].function.parameters` | `tools[].input_schema` | `tools[].functionDeclarations[].parameters` |
| 工具调用（响应） | `message.tool_calls[]` | `content[]` 里 `type:'tool_use'` | `parts[].functionCall` |
| 工具结果（回填） | `role:'tool'` + `tool_call_id` | `role:'user'` + `tool_result` 块 | `role:'user'` + `functionResponse` |
| 工具调用 id | 有 | 有 | **没有**（要自己造，见下） |
| 流式 | `data:` JSON 分片 | 命名事件（`content_block_delta`） | `alt=sse` |

### 2.1 Gemini 没有工具调用 id

Gemini 的 `functionResponse` 只认**函数名**，不认 id。而 OpenAI 系的 Agent 循环
是按 id 关联「哪次调用对应哪个结果」的。

变通：我们在 `ToolCall.id` 里塞 `name::<序号>`，回填时解析回函数名。
这是协议本身的限制，不是设计选择 —— 代价是**同一轮里同名工具被调用多次时，
Gemini 侧无法区分**。多轮同名调用不受影响（顺序一致）。

---

## 3. 实测确认的行为（`deepseek-v4.1-flash` via 中转站）

跑 `packages/model_gateway/test/live_api_test.dart` 得到的事实，不是推测：

| 观察 | 含义 |
|---|---|
| `GET /v1/models` 返回 6 个模型，145ms | 模型表可用，设置页可以做成"刷新模型列表"而不是手填 |
| 非流式 + `max_tokens=600` 耗时 **20–30 秒** | **宿主必须默认用流式。** 让用户对着空白界面等 24 秒不可接受 |
| `max_tokens=16` 时正文为空、思维链有内容 | `max_tokens` **包含思维链**。预算给小了，钱花了但用户看不到回复 |
| 流式 27 个增量（正文 8 块 / 思维链 17 块） | 思维链是**独立字段独立推送**的，不能混进正文 |
| 工具调用成功，模型自己填了 `{timezone: "Asia/Shanghai"}` | function calling 可用，且会推断参数 —— 工具的 `description` 写得好是值得的 |
| 最后一个 chunk `choices: []` 且只带 `usage` | 用量在**空 choices 的尾包**里，不能因为 choices 空就跳过 |
| 响应里有 `cost_cny` / `trace_id` / `reasoning_available` | 中转站私有字段，**必须原样保留**，解析层丢掉就再也拿不回来 |
| 错误 key → `401 Invalid API key` | 鉴权失败能被正确分类为 `auth`，不是静默失败 |

### 3.1 由此得出的产品结论

1. **默认走流式。** 非流式只用于短、非推理的调用（如翻译）。
2. **推理模型的 token 预算要给足。** 设置页应给「思维链预算」的说明，而不是只写 max_tokens。
3. **思维链要能折叠显示。** 它是排障与调优的关键信息，但默认不该占据主界面。
4. **中转站的模型表要能刷新。** 否则上游换模型后用户会看到"模型不存在"。

---

## 4. 用法

```dart
final config = ProviderConfig.openAiCompat(
  baseUrl: 'http://103.236.91.136:52165/v1',
  apiKey: 'sk-...',                 // 只在宿内存内存，绝不进日志/审计/插件
  defaultModel: 'deepseek-v4.1-flash',
  displayName: '测试中转站',
);

final gateway = HttpModelGateway(config: config);

// 设置页「测试连接」：只拉模型表，不消耗 token
final check = await gateway.check();
if (!check.ok) {
  print('${check.errorKind}: ${check.errorMessage}');
} else {
  for (final m in check.models) print(m.id);
}

// 带工具调用的流式对话
final reply = await gateway.completeStreaming(
  ModelRequest(
    messages: [ChatMessage.user('现在几点')],
    tools: [ /* OpenAI 格式的工具声明 */ ],
  ),
  onDelta: (d) => stdout.write(d.content ?? ''),
);
if (reply.hasToolCalls) {
  print('模型要调：${reply.toolCalls.first.name}');
}
```

换成 Anthropic / Google 只需改 `ProviderConfig`：

```dart
final config = ProviderConfig(
  protocol: ProviderProtocol.anthropic,   // 或 .google
  baseUrl: 'https://api.anthropic.com/v1',
  apiKey: '...',
  defaultModel: 'claude-sonnet-4-5',
);
```

**上层代码一行都不用改。**

---

## 5. 可测性设计

| 层 | 怎么做 | 效果 |
|---|---|---|
| `HttpTransport` | 接口化，真实实现用 `dart:io`，测试用 `FakeTransport` | 适配器逻辑可以脱离网络穷举测试 |
| 协议适配器 | `ProtocolAdapter` 接口，三套实现各自独立 | 加第四套协议 = 加一个文件 |
| SSE 解析 | 独立成 `sse.dart`，纯函数 | 跨 chunk 拆分、`\r\n`、`[DONE]`、无尾换行都能单测 |
| 工具调用拼接 | `StreamAccumulator` 独立 | 「JSON 被从任意位置切开」这个经典坑有专门测试 |
| 真实 API | `live_api_test.dart`，**默认跳过** | CI 不花钱；要验证时显式开环境变量 |

跑真实 API 测试：

```powershell
# 首次：建本地配置（已 gitignore），之后不用再设任何环境变量
Copy-Item dev\dev-config.example.json dev\dev-config.json   # 填入 apiKey

& .\scripts\run_live_test.ps1              # 跑真实 API
& .\scripts\run_live_test.ps1 -WithOffline # 顺带跑离线测试
```

**配置来源优先级：环境变量 > `dev/dev-config.json` > 无（跳过）**。
都没有时整个文件跳过，**不会失败** —— CI 上不配任何东西也能跑通。

### 为什么真 Key 不提交

仓库是 public 的。把 Key 写进被提交的文件意味着：

1. GitHub 密钥扫描几分钟内标记它（可能自动吊销）
2. 爬虫持续扫 GitHub，捞到就消耗额度
3. **删掉文件不等于删掉密钥** —— git 历史里还在

所以真实配置放 `dev/dev-config.json`（gitignore），仓库只提交
`dev/dev-config.example.json` 模板。**便利性完全一样**（脚本自动读，不用设环境变量），
区别只是不公开。

### Android 侧复用同一份配置

同一份 JSON 直接放进 Flutter 工程的 assets：

```yaml
# pubspec.yaml
flutter:
  assets:
    - assets/dev-config.json
```

```dart
final raw = await rootBundle.loadString('assets/dev-config.json');
final config = ProviderConfig.fromJson(jsonDecode(raw)['provider']);
```

`ProviderConfig.fromJson` / `toJson` 就是为这个场景准备的（设置页持久化也用它）。

⚠️ **打包发给用户时务必去掉这个 asset。** 正式版走网关（用户 Token），
客户端不该带任何上游 Key —— 这是设计红线（原则 4）。

---

## 6. 与后端的边界

现在的接入层是**客户端直连**（Demo 阶段用户自带 Key）。正式版要变成：

```
客户端 ──(用户 Token)──▶ API 网关 ──(上游 Key)──▶ 供应商
```

变化只有一处：`ProviderConfig.apiKey` 换成用户 Token，`baseUrl` 指向自建网关。
**适配器、SSE 解析、工具拼接全都不动** —— 因为网关对外暴露的仍然是 OpenAI 兼容协议。

这也是「密钥只在后端」原则能落地的前提：接入层从第一天起就不把 Key 写进任何
会被序列化出去的结构（`ProviderConfig.toString()` 打码、`AuditRedactor` 只记 host）。

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：三套协议差异表、实测确认的 8 条行为、可测性设计、与后端的边界 |
