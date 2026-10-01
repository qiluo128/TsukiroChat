# 05 · 原语层

> **设计纲领：原语越原子，插件越自由。**
> 宿主里不写「查快递」，只写 `net.request`。宿主里不写「读角色卡」，只写 `fs.read`。

---

## 1. 命名与调用约定

### 1.1 命名

```
<域>.<动作>            两级，小写，驼峰动作
sys.time               ✅
sys.getCurrentTime     ❌ 不要冗长
user.profile.getName   ❌ 不要三级
```

域清单：`fs` `sys` `media` `contact` `sms` `call` `calendar` `app` `notification` `location` `net` `ui` `state` `crypto` `a11y` `screen` `model` `tool` `event` `log` `mcp`

### 1.2 调用形态（插件侧）

插件在沙箱 WebView 中，通过注入的全局对象 `tsukiro` 调用。**每个调用都是一次异步 RPC**，返回 Promise。

```js
// 全部返回 Promise，统一 resolve 为 data，reject 为 TsukiroError
const t    = await tsukiro.sys.time({ tz: 'Asia/Shanghai' });
await tsukiro.ui.toast({ text: '你好' });
const txt  = await tsukiro.fs.read({ path: 'notes/a.txt' });
const rep  = await tsukiro.model.chat({ messages: [...], stream: false });
```

流式原语返回 **AsyncIterable**：

```js
for await (const chunk of tsukiro.model.chat({ messages, stream: true })) {
  process.stdout?.write?.(chunk.delta);
}
```

### 1.3 参数与返回

- 参数一律**单对象**，不使用位置参数。理由是未来加可选参数不破坏签名。
- 返回一律**纯 JSON 可序列化**（无函数、无循环引用、`Date` 转 ISO 字符串）。
- 二进制数据用 `{ base64: "..." }` 或经 `fs.saveFile` 落盘后返回沙箱路径。**不返回 data URL**（体积爆炸）。

### 1.4 统一错误模型

宿主侧返回：

```jsonc
{
  "ok": false,
  "error": {
    "code": "PERMISSION_DENIED",
    "message": "插件未获得 media.read 权限",
    "details": { "permission": "media.read" },
    "retryable": false
  }
}
```

插件侧统一 `reject` 为：

```js
class TsukiroError extends Error {
  code;        // 见下表
  details;     // 结构化附加信息
  retryable;   // 是否值得重试
}
```

| code | 含义 | 插件应如何应对 |
|---|---|---|
| `INVALID_ARGS` | 参数不符合 schema | 修代码，不要重试 |
| `PERMISSION_DENIED` | 未授权（未申请或已撤销） | 提示用户去授权页；不要静默吞掉 |
| `PERMISSION_REVOKED` | 曾授权后被撤销 | 同 `PERMISSION_DENIED`，并停止相关功能 |
| `USER_CANCELLED` | 用户在选择器/授权框中取消 | 静默处理，不算错误 |
| `NOT_FOUND` | 文件/联系人/会话不存在 | 按业务处理 |
| `IO_ERROR` | 磁盘/系统 IO 失败 | 可重试一次 |
| `NETWORK_ERROR` | 网络失败 | 可重试（退避） |
| `TIMEOUT` | 超时 | 可重试 |
| `RATE_LIMITED` | 触发限流 | 退避重试 |
| `SANDBOX_VIOLATION` | 试图越出沙箱（路径穿越等） | **不可重试**，已记安全审计 |
| `UNSUPPORTED` | 当前平台不支持该原语 | 降级或禁用功能 |
| `CONFIRM_REQUIRED` | 该操作需每次确认，用户未确认 | 重新发起以触发确认框 |
| `PLUGIN_ERROR` | 插件自身 handler 抛错 | 调试用 |
| `INTERNAL` | 宿主内部错误 | 记录并报告 |

### 1.5 超时与取消

- 默认超时 **10 秒**，可由插件显式传 `{ timeoutMs }` 覆盖，上限 **60 秒**。
- 长任务（下载、录屏）用「任务 id + 事件」模式，不受调用超时限制：
  ```js
  const job = await tsukiro.net.download({ url, to: 'files/a.zip' });  // 立即返回 { jobId }
  tsukiro.event.on('job.progress', e => { if (e.jobId === job.jobId) ... });
  ```

---

## 2. 权限映射

**每个原语绑定一个必需权限**。调用时宿主先查权限，未授权直接返回 `PERMISSION_DENIED`，**不会执行任何副作用**。

| 原语域 | 权限 | 粒度说明 |
|---|---|---|
| `fs.*` | `fs.read` / `fs.write` / `fs.delete` | 按读/写/删分开 |
| `sys.time` | `sys.time` | 单独的轻权限 |
| `sys.battery` `sys.device` `sys.network` `sys.locale` | `sys.info` | 合并为一档 |
| `sys.clipboard.read` | `sys.clipboard.read` | 读剪贴板更敏感 |
| `sys.clipboard.write` `sys.vibrate` | `sys.clipboard.write` | |
| `media.*`（读） | `media.read` | |
| `media.camera.*` | `media.camera` | |
| `media.audio.record` | `media.microphone` | |
| `contact.*` | `contact.read` | |
| `sms.*` | `sms.read` / `sms.send` | 发送单独授权 |
| `call.make` | `call.make` | |
| `calendar.*` | `calendar.read` / `calendar.write` | |
| `app.list` `app.info` | `app.read` | |
| `app.open` | `app.launch` | |
| `notification.send` | `notification.send` | |
| `notification.listen` | `notification.read` | |
| `location.*` | `location` | |
| `net.request` 等 | `net` + `network.allow` 白名单 | 双重检查 |
| `ui.*` | `ui` | 低风险，但与 `ui.overlay` 分开 |
| `state.*` | 无需权限 | 沙箱内自有存储 |
| `crypto.*` | 无需权限 | 纯计算 |
| `a11y.*` | `a11y` | **每次确认** |
| `screen.capture` | `screen.capture` | **每次确认** |
| `screen.record` | `screen.record` | **每次确认** |
| `model.chat` / `model.embed` / `model.vision` | `model.chat` | 消耗用户点数，需授权 |
| `tool.*` `event.*` `log.*` | 无需权限 | 基础设施 |
| `mcp.*` | `mcp` | 预留 |

---

## 3. 原语清单

图例：**✅ Demo 实现** · 🔷 接口已定义待实现 · ⬜ 预留（仅占位）

### 3.1 文件系统 `fs.*`

**所有路径都是相对沙箱根目录的相对路径**，宿主负责拼接与规范化。绝对路径、`..`、符号链接一律 `SANDBOX_VIOLATION`。

| 原语 | 签名 | 返回 | 权限 | 状态 |
|---|---|---|---|---|
| `fs.list` | `{ path?, recursive?, pattern? }` | `[{name, path, isDir, size, mtime}]` | `fs.read` | 🔷 |
| `fs.read` | `{ path, encoding?='utf8' }` | `{ text }` 或 `{ base64 }` | `fs.read` | **✅** |
| `fs.write` | `{ path, text?, base64?, append?=false }` | `{ bytesWritten }` | `fs.write` | 🔷 |
| `fs.delete` | `{ path, recursive?=false }` | `{ deleted }` | `fs.delete` | 🔷 |
| `fs.meta` | `{ path }` | `{ size, mtime, isDir, exists }` | `fs.read` | 🔷 |
| `fs.mkdir` | `{ path, recursive?=true }` | `{ created }` | `fs.write` | 🔷 |
| `fs.pickFile` | `{ accept?, multiple?=false }` | `[{name, sandboxPath}]` 已复制进沙箱 | `fs.read` | 🔷 |
| `fs.saveFile` | `{ path, suggestedName }` | `{ saved, uri }` 导出沙箱外 | `fs.write` | 🔷 |

```js
// Demo 用到的例子
const note = await tsukiro.fs.read({ path: 'notes/hello.txt' });
// 越界示例 —— 必须被拒绝
await tsukiro.fs.read({ path: '../../host_secret.txt' });  // ❌ SANDBOX_VIOLATION
```

### 3.2 系统 `sys.*`

| 原语 | 签名 | 返回 | 权限 | 状态 |
|---|---|---|---|---|
| `sys.time` | `{ tz? }` | `{ iso, epochMs, human, tz }` | `sys.time` | **✅** |
| `sys.battery` | `{}` | `{ level, charging }` | `sys.info` | 🔷 |
| `sys.network` | `{}` | `{ online, type, metered }` | `sys.info` | 🔷 |
| `sys.device` | `{}` | `{ model, os, osVersion, locale, screen }` | `sys.info` | 🔷 |
| `sys.locale` | `{}` | `{ language, region, timezone, firstDayOfWeek }` | `sys.info` | 🔷 |
| `sys.clipboard.read` | `{}` | `{ text }` | `sys.clipboard.read` | 🔷 |
| `sys.clipboard.write` | `{ text }` | `{ ok }` | `sys.clipboard.write` | 🔷 |
| `sys.vibrate` | `{ ms?=100, pattern? }` | `{ ok }` | `sys.clipboard.write` | 🔷 |

> `sys.time` 是 Demo 的四个原语之一，也是「时间插件」依赖项。注意它是**唯一一个即使无网络也能验证工具调用链路**的原语 —— 所以选它做第一个测试插件。

### 3.3 媒体 `media.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `media.listPhotos` | `{ limit?, album?, since? }` → `[{id, thumbPath, takenAt}]` | `media.read` | 🔷 |
| `media.getPhoto` | `{ id, full?=false }` → `{ sandboxPath }` | `media.read` | 🔷 |
| `media.camera.capture` | `{ facing?='back' }` → `{ sandboxPath }` | `media.camera` | 🔷 |
| `media.camera.record` | `{ facing?, maxMs? }` → `{ jobId }` | `media.camera` | 🔷 |
| `media.audio.record` | `{ maxMs? }` → `{ jobId }` | `media.microphone` | 🔷 |
| `media.audio.play` | `{ path, loop?=false }` → `{ jobId }` | `media.read` | 🔷 |

> 轨道以**沙箱路径**交接，不是 base64 灌进 JS。大文件走路径，小文件才走 base64。

### 3.4 通讯 `contact.*` `sms.*` `call.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `contact.list` | `{ limit?, offset? }` | `contact.read` | 🔷 |
| `contact.get` | `{ id }` | `contact.read` | 🔷 |
| `contact.search` | `{ query, limit? }` | `contact.read` | 🔷 |
| `sms.send` | `{ to, text }` → **每次确认** | `sms.send` | 🔷 |
| `sms.list` | `{ limit?, since?, threadId? }` | `sms.read` | 🔷 |
| `sms.listen` | `{}` → 事件流 | `sms.read` | 🔷 |
| `call.make` | `{ number }` | `call.make` | 🔷 |
| `call.log` | `{ limit? }` | `call.make` | 🔷 |

### 3.5 日历 `calendar.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `calendar.list` | `{ from, to, calendarId? }` | `calendar.read` | 🔷 |
| `calendar.create` | `{ title, start, end, notes?, reminder? }` | `calendar.write` | 🔷 |
| `calendar.update` | `{ id, ...fields }` | `calendar.write` | 🔷 |

### 3.6 应用 `app.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `app.list` | `{ includeSystem?=false }` | `app.read` | 🔷 |
| `app.isInstalled` | `{ package }` | `app.read` | 🔷 |
| `app.info` | `{ package }` | `app.read` | 🔷 |
| `app.open` | `{ package?, uri? }` | `app.launch` | 🔷 |

> `app.open` 对 `uri` 需白名单 scheme（`https` `mailto` `tel` `geo`），禁止 `file://` 与任意 scheme。

### 3.7 通知 `notification.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `notification.send` | `{ title, body, id?, actions? }` | `notification.send` | 🔷 |
| `notification.cancel` | `{ id }` | `notification.send` | 🔷 |
| `notification.listen` | `{}` → 事件流 | `notification.read` | 🔷 |

### 3.8 定位 `location.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `location.get` | `{ accuracy?='balanced' }` | `location` | 🔷 |
| `location.watch` | `{ minIntervalMs? }` → 事件流 | `location` | 🔷 |
| `location.geocode` | `{ lat, lng }` / `{ address }` | `location` + `net` | 🔷 |

### 3.9 网络 `net.*`

**双重检查**：先查 `net` 权限，再查 `network.allow` 白名单里的域名。两者缺一即拒绝并记审计。

| 原语 | 签名 | 返回 | 状态 |
|---|---|---|---|
| `net.request` | `{ url, method, headers?, body?, timeoutMs? }` | `{ status, headers, text/base64 }` | 🔷 |
| `net.download` | `{ url, to, headers? }` | `{ jobId }` 进度走事件 | 🔷 |
| `net.upload` | `{ url, path, field?, headers? }` | `{ jobId }` | 🔷 |
| `net.websocket` | `{ url, protocols? }` → 双向通道 | `{ jobId, send(), onMessage }` | 🔷 |

> **插件不接触宿主自身的网络能力**：`model.*` 走宿主网关，`net.*` 走插件自己的白名单。插件用 `net.*` 直连第三方是允许的（已在白名单内），但绝不能用来打宿主网关的内部接口。

### 3.10 UI `ui.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `ui.toast` | `{ text, durationMs?=2000, kind?='info' }` | `ui` | **✅** |
| `ui.dialog` | `{ title, content, buttons:[{id,label,style}] }` → `{ buttonId }` | `ui` | 🔷 |
| `ui.sheet` | `{ title, itemSchema }` → `{ values }` | `ui` | 🔷 |
| `ui.overlay.show/hide` | `{ overlayId }` | `ui.overlay` | 🔷 |
| `ui.navigate` | `{ pageId, params? }` | `ui` | 🔷 |
| `ui.close` | `{}` | `ui` | 🔷 |
| `ui.setTitle` | `{ title }` | `ui` | 🔷 |
| `ui.setBadge` | `{ count }` | `ui` | 🔷 |
| `ui.render` | ⬜ 已废弃 —— 插件自带 HTML 用 `pages`，宿主内 UI 用 `provides.ui` | — | ⬜ |

> **关于 `ui.render`**：原始需求里有这一项，但「插件让宿主动态渲染任意 UI」会破坏视觉一致性与可辨识原则。本设计改为：宿主内控件走 `provides.ui` 声明式描述，需要完全自定义的走 `provides.pages` 独立页面。`ui.render` 不再实现。

### 3.11 存储 `state.*`

插件私有键值存储，宿主自动加 `<pluginId>:` 前缀。**无需权限**。

| 原语 | 签名 | 返回 |
|---|---|---|
| `state.get` | `{ key, default? }` | `{ value }` |
| `state.set` | `{ key, value }` | `{ ok }` |
| `state.delete` | `{ key }` | `{ deleted }` |
| `state.list` | `{ prefix? }` | `[{ key, value }]` |

容量限制：**单插件 5 MB**，超出 `state.set` 返回 `IO_ERROR` 并提示。

### 3.12 加密 `crypto.*`

纯计算，无需权限。

| 原语 | 签名 | 返回 |
|---|---|---|
| `crypto.hash` | `{ algo='sha256', text?/base64? }` | `{ hex, base64 }` |
| `crypto.random` | `{ bytes=16, encoding='hex' }` | `{ value }` |
| `crypto.encrypt` | `{ algo='aes-256-gcm', key, plaintext }` | `{ iv, ciphertext, tag }` |
| `crypto.decrypt` | `{ algo, key, iv, ciphertext, tag }` | `{ plaintext }` |

> `crypto.*` 提供的是**插件自己的**加解密。宿主不会把用户凭据交给它。

### 3.13 无障碍 `a11y.*` —— 每次确认

| 原语 | 签名 | 权限 |
|---|---|---|
| `a11y.find` | `{ selector }` | `a11y` |
| `a11y.click` | `{ nodeId }` | `a11y` |
| `a11y.setText` | `{ nodeId, text }` | `a11y` |
| `a11y.scroll` | `{ nodeId, direction, distance }` | `a11y` |
| `a11y.screenshot` | `{}` | `a11y` |

### 3.14 截屏 `screen.*` —— 每次确认

| 原语 | 签名 | 权限 |
|---|---|---|
| `screen.capture` | `{}` → `{ sandboxPath }` | `screen.capture` |
| `screen.record` | `{ withAudio?, maxMs? }` → `{ jobId }` | `screen.record` |
| `screen.analyze` | `{ source }` → 走宿主视觉模型 | `screen.capture` + `model.chat` |

### 3.15 模型 `model.*` —— **插件不接触 Key**

所有模型调用经宿主持有凭据发出，插件只拿到结果。计费走网关（阶段 3）/ 本地 Key（Demo）。

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `model.chat` | `{ messages, model?, tools?, temperature?, stream? }` | `model.chat` | **✅** |
| `model.embed` | `{ input, model? }` | `model.chat` | 🔷 |
| `model.vision` | `{ prompt, images:[sandboxPath] }` | `model.chat` | 🔷 |

```js
// 翻译按钮插件的核心调用
const res = await tsukiro.model.chat({
  messages: [
    { role: 'system', content: '你是翻译引擎，只输出译文，不要解释。' },
    { role: 'user',   content: `把下面内容翻译成${target}：\n${text}` }
  ],
  stream: false
});
tsukiro.ui.toast({ text: res.text.slice(0, 40) });
```

**重要约束**：
- `model.chat` 的 `model` 参数只接受**逻辑模型名**（如 `default` / `fast` / `smart`），由宿主映射到真实模型。Demo 阶段可忽略此项。
- `model.chat` **不允许**传递上游凭据、Base URL。参数里根本没有这些字段。
- 宿主对每个插件做**调用频率与 token 上限**限制（防插件偷偷刷爆用户点数）。

### 3.16 工具 `tool.*`

| 原语 | 签名 | 返回 | 说明 |
|---|---|---|---|
| `tool.list` | `{ scope?='all' }` | `[{name, description, pluginId}]` | 列出可用工具 |
| `tool.call` | `{ name, args }` | 工具结果 | 插件调用**其他插件**的工具；同样过权限与审计 |

> `tool.call` 让插件可以组合彼此能力（如「翻译插件」复用「词典插件」）。跨插件调用需被调插件声明「可被调用」（`provides.tools[].exposed = true`，默认 true）。

### 3.17 事件 `event.*`

| 原语 | 签名 | 说明 |
|---|---|---|
| `event.on` | `{ name, handler }` | 订阅宿主事件 |
| `event.emit` | `{ name, data }` | 发事件（只在**自己**的命名空间内，宿主自动加前缀） |
| `event.off` | `{ name, handler? }` | 取消订阅 |

**宿主向插件发出的事件**（只读，插件不能伪造）：

| 事件 | 载荷 | 触发时机 |
|---|---|---|
| `ui.click` | `{ slot, id }` | 插槽控件被点击 |
| `lifecycle.start` | `{ reason }` | 插件启动 |
| `lifecycle.stop` | `{ reason }` | 插件停止 |
| `config.change` | `{ key, value }` | 用户改了配置 |
| `permission.change` | `{ granted:[], revoked:[] }` | 权限变化 |
| `tool.invoke` | `{ tool, args, callId }` | 模型调用插件工具 |
| `chat.message` | `{ sessionId, role, text }` | 新消息（需 `chat.read` 权限） |
| `chat.beforeSend` | `{ sessionId, text }` | **可拦截并修改**用户将要发送的内容 |
| `chat.afterReply` | `{ sessionId, text }` | 模型回复完成 |
| `page.open` / `page.close` | `{ pageId }` | 插件页面打开/关闭 |

### 3.18 日志 `log.*`

写入宿主日志与审计，无需权限。

| 原语 | 签名 |
|---|---|
| `log.info` / `log.warn` / `log.error` | `{ message, data? }` |

单插件日志限速：**100 条/分钟**，超出丢弃并记一次 `RATE_LIMITED`。

### 3.19 MCP `mcp.*` —— 预留

| 原语 | 签名 | 状态 |
|---|---|---|
| `mcp.serve` | `{ id, port?=0 }` → `{ url }` | ⬜ 预留 |
| `mcp.stop` | `{ id }` | ⬜ 预留 |
| `mcp.status` | `{ id }` | ⬜ 预留 |

---

## 4. Demo 范围

Demo 只实现四个原语，刻意选得**足够小**但能覆盖所有链路：

| 原语 | 覆盖什么 |
|---|---|
| `sys.time` | ✅ 工具调用链路（模型 → 工具 → 插件 → 原语 → 回传） |
| `ui.toast` | ✅ 宿主 UI 副作用 + 权限为低风险的路径 |
| `model.chat` | ✅ 插件调 AI（且证明插件拿不到 Key） |
| `fs.read` | ✅ 沙箱路径约束 + 路径穿越防护 |

**为什么是这四个**：它们分别命中「工具调用」「宿主 UI 副作用」「模型代理」「沙箱文件」四条独立链路。四个都通，说明原语层的路由、权限、审计、沙箱四套机制都工作正常。

其它原语在 Demo 阶段**必须在宿主侧返回 `UNSUPPORTED`**（而不是崩溃或静默），这样插件的降级逻辑也能被测到。

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：统一调用/错误/超时约定、权限映射表、19 个域完整清单、Demo 范围 |
| 2026-02 | 移除 `ui.render`（与视觉一致性原则冲突），改为 `provides.ui` + `provides.pages` |
