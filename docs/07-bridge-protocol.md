# 07 · Bridge 协议

> Bridge 是**沙箱 WebView ↔ 宿主** 的唯一通道。插件的一切外部能力都从这里出去，一切宿主事件都从这里进来。

---

## 1. 传输层

| 平台 | 机制 |
|---|---|
| Android | `WebViewCompat.addWebMessageListener`（带 origin 白名单） |
| iOS | `WKScriptMessageHandler` |
| Windows | WebView2 `AddScriptToExecuteOnDocumentCreated` + `postMessage` |
| Flutter 封装 | `flutter_inappwebview` 的 `addJavaScriptHandler` |

**约束**：

1. 只接受来自**本插件 WebView 实例**的消息。宿主为每个插件维护独立实例，消息与 `pluginId` 绑定，插件无法冒充其他插件。
2. 只接受插件的**自有 origin**（`https://<pluginId>.tsukiro.local` 或自定义 scheme）。来自被内嵌 iframe / 外部页面的消息一律丢弃。
3. 消息体大小上限 **1 MB**。更大的数据传输用 `fs.*` 走沙箱路径，不走 Bridge。

---

## 2. 消息封套

所有消息统一为 JSON 对象：

```jsonc
{
  "v": 1,                        // 协议版本
  "kind": "req",                 // req | res | evt | str | err
  "id": "r_7f3a91",              // req/res 配对用；evt 无 id
  "method": "sys.time",          // req: 原语名或内部方法；res: 无
  "params": { "tz": "Asia/Shanghai" },
  "result": { "iso": "..." },    // 仅 res
  "error": { "code": "...", "message": "...", "details": {} },  // 仅 err
  "ts": 1771033421512
}
```

| `kind` | 方向 | 用途 |
|---|---|---|
| `req` | 插件 → 宿主 | 调用原语 |
| `res` | 宿主 → 插件 | 请求成功返回 |
| `err` | 宿主 → 插件 | 请求失败 |
| `evt` | 双向 | 单向事件通知，不需回应 |
| `str` | 宿主 → 插件 | 流式分片（见 §4） |
| `inv` | 宿主 → 插件 | **宿主反向调用**插件（工具执行、生命周期），见 §5 |

---

## 3. 请求 / 响应

### 3.1 插件调用宿主

```js
// 插件侧（由 plugin_sdk 封装，插件作者不用手写）
tsukiro.sys.time({ tz: 'Asia/Shanghai' })
```

展开为：

```jsonc
// → 插件 WebView 发出
{ "v":1, "kind":"req", "id":"r_7f3a91", "method":"sys.time",
  "params":{ "tz":"Asia/Shanghai" }, "ts":1771033421512 }
```

```jsonc
// ← 宿主返回（成功）
{ "v":1, "kind":"res", "id":"r_7f3a91",
  "result":{ "iso":"2026-02-14T10:23:41+08:00", "epochMs":1771033421000,
             "human":"2026年2月14日 10:23:41", "tz":"Asia/Shanghai" },
  "ts":1771033421515 }
```

```jsonc
// ← 宿主返回（失败）
{ "v":1, "kind":"err", "id":"r_7f3a91",
  "error":{ "code":"PERMISSION_DENIED",
            "message":"插件未获得 sys.time 权限",
            "details":{ "permission":"sys.time" },
            "retryable":false },
  "ts":1771033421515 }
```

### 3.2 宿主内部方法（非原语）

宿主注册一批**只对宿主可用**的方法名，插件调用它们会被 `UNSUPPORTED` 拒绝：

```
__host.*        保留命名空间，插件不得调用
```

插件侧 SDK 会拦截 `tsukiro.__host` 的访问并抛错，但仍以宿主侧检查为准。

---

## 4. 流式响应

`model.chat` 这类流式原语，用 `req` 发起，然后宿主连续发 `str` 分片，最后以 `res` 结束。

```
插件                         宿主
  │  req model.chat {stream:true}  │
  ├───────────────────────────────▶│
  │  str {seq:0, delta:"你"}        │
  │◀───────────────────────────────┤
  │  str {seq:1, delta:"好"}        │
  │◀───────────────────────────────┤
  │  str {seq:2, delta:"呀", done:false}
  │◀───────────────────────────────┤
  │  res {usage:{prompt:12,completion:3}}
  │◀───────────────────────────────┤
```

```jsonc
{ "v":1, "kind":"str", "id":"r_7f3a91", "seq":1,
  "delta":"好", "done":false, "ts":... }
```

**规则**：

- `seq` 从 0 单调递增，插件可据此检测丢包（不可靠传输时才用）。
- 中途出错：发 `err` 结束，**已发出的分片不撤回**。插件要自己处理「说了半句然后失败」。
- 取消：插件发 `evt { method: "stream.cancel", params: { id } }`，宿主停止并回 `err { code: "USER_CANCELLED" }`。
- 单次流式响应的分片数上限 **10000**，超出强制终止（防失控）。

### 4.1 异步任务（长任务）

下载、录屏等不占用调用超时，用任务模式：

```
req net.download → res { jobId: "job_1a2b" }
（之后宿主持续发 evt "job.progress"）
evt { method:"job.progress", params:{ jobId:"job_1a2b", loaded:1024, total:51200 } }
evt { method:"job.done",     params:{ jobId:"job_1a2b", result:{ to:"files/a.zip" } } }
evt { method:"job.failed",   params:{ jobId:"job_1a2b", error:{...} } }
```

---

## 5. 宿主反向调用插件（`inv`）

宿主需要**插件执行代码**时使用。与 `req` 方向相反，但格式对称。

| 方法 | 何时调用 | 参数 | 期望返回 |
|---|---|---|---|
| `tool.invoke` | 模型触发插件工具 | `{ tool, args, callId }` | 工具结果（JSON） |
| `lifecycle.start` | 插件启动 | `{ reason }` | `{}` |
| `lifecycle.stop` | 插件停止 / 卸载前 | `{ reason }` | `{}` |
| `config.change` | 用户改配置 | `{ key, value, all }` | `{}` |
| `permission.change` | 权限授予/撤销 | `{ granted:[], revoked:[] }` | `{}` |
| `ui.click` | 插槽控件被点击 | `{ slot, id }` | `{}` |
| `memory.*` | 记忆接口调用（预留） | 见 09 | 见 09 |
| `harness.step` | L7 步骤接管（预留） | 见 09 | 见 09 |

```jsonc
// 宿主 → 插件：模型要调 get_time
{ "v":1, "kind":"inv", "id":"i_5c1e", "method":"tool.invoke",
  "params":{ "tool":"get_time", "args":{ "timezone":"Asia/Shanghai" },
             "callId":"call_abc123" },
  "ts":... }
```

```jsonc
// 插件 → 宿主：返回工具结果
{ "v":1, "kind":"res", "id":"i_5c1e",
  "result":{ "time":"2026-02-14T10:23:41+08:00", "human":"下午 2 月 14 日 10:23" },
  "ts":... }
```

插件侧由 SDK 路由到 manifest 里声明的 `handler`：

```js
// handlers/get_time.js —— 插件作者只需要写这个
export default async function get_time(args) {
  const t = await tsukiro.sys.time({ tz: args.timezone });
  return { time: t.iso, human: t.human };
}
```

**工具调用超时**：默认 `manifest.provides.tools[].timeoutMs`（10s）。超时后宿主回 `err { code:"TIMEOUT" }` 给**模型**（不是给用户），模型会看到工具失败并自行处理。

---

## 6. 生命周期与握手

```
宿主创建 WebView
   │  加载 https://<pluginId>.tsukiro.local/index.html
   │  （宿主生成的引导页，注入 plugin_sdk 后 import 插件的 index.js）
   ▼
插件 SDK 初始化
   │  发 evt { method:"bridge.hello", params:{ v:1, pluginId, version, hostApi } }
   ▼
宿主校验 pluginId 与 WebView 实例是否匹配
   │  ✗ 不匹配 → 立即销毁 WebView + 记安全审计
   │  ✓ 匹配   → 回 evt { method:"bridge.ready", params:{ hostVersion, granted:[], config:{} } }
   ▼
宿主发 inv lifecycle.start
   │  插件在此处注册事件监听、初始化 state
   ▼
正常运行
   │
   ├─ 插件 JS 抛未捕获异常 → 宿主捕获 → 停用插件 + 通知用户
   ├─ WebView 进程死亡 → 宿主重启一次；连续 2 次 → 停用
   └─ 用户停用 / 卸载 → 宿主发 inv lifecycle.stop（等待最多 2s）→ 销毁 WebView
```

**握手必须完成才能发其他消息**。握手前收到的任何 `req` 一律丢弃并记审计（防止注入的脚本抢跑）。

---

## 7. 安全规则

| 规则 | 说明 |
|---|---|
| **实例绑定** | 消息只能来自创建它的那个 WebView 实例，`pluginId` 由宿主绑定，不信任消息里的自称 |
| **握手门禁** | 未完成 `bridge.hello` / `bridge.ready` 的消息全部丢弃 |
| **方法白名单** | `method` 必须在宿主的方法注册表里，否则 `UNSUPPORTED`；`__host.*` 与 `mcp.*` 对插件关闭（预留除外） |
| **权限前置** | 每个 `req` 先过 `Gatekeeper`，再执行 |
| **大小限制** | 单消息 ≤ 1 MB；超限断开并记审计 |
| **速率限制** | 单插件 200 条消息/秒，超出丢弃 + 警告 |
| **无 `eval`** | WebView 禁用 `eval` / `new Function`（CSP `script-src 'self'`） |
| **CSP** | `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'` |

> **`connect-src 'none'` 是关键**：插件 WebView 内的 `fetch` / `XMLHttpRequest` / `WebSocket` 全部被 CSP 拦死。插件要联网**只能**走 `net.request` 原语。这样白名单才是真的白名单，而不是「建议」。

---

## 8. 协议版本与兼容

- `v: 1` 为当前版本。
- 宿主收到 `v > 支持的最大版本` → 拒绝握手，提示用户升级宿主。
- 新增 `kind` / 方法：不升 `v`，旧客户端收到未知 `method` 时忽略。
- 字段语义变更：升 `v`，宿主与插件 SDK 同时支持两版一轮过渡。

---

## 9. 调试支持（开发模式）

宿主在 debug 构建下提供：

```
设置 → 高级 → 插件调试
  ├─ 实时消息流（彩色打印 req/res/evt/inv）
  ├─ 手动构造消息注入插件（测试插件对异常的处理）
  ├─ 打开 WebView DevTools（Android: chrome://inspect）
  └─ 导出该插件的审计日志为 JSON
```

**release 构建不包含**这些入口。

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：封套格式、req/res/evt/str/inv 五种消息、握手、CSP 安全规则、调试支持 |
