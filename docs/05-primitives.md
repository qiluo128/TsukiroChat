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
| `media.video.play` | `media.read` | 播放不额外授权 |
| `sys.screen.pullBack` `sys.app.lock` `sys.dialog.popup` | `sys.intervene` | **每次确认**；语义为「打断用户当前操作」 |
| `sys.overlay.show` / `sys.overlay.hide` | `sys.overlay` | 仅叠加显示，不打断 |
| `context.inject` / `context.append` | `context.write` | 往 AI 上下文写 |
| `context.onBuild` / `onBeforeModel` / `onAfterModel` | `context.hook` | 注册钩子比单次注入风险更高（持续性），单独一档 |
| `message.get` | `message.read` | 读别人的消息 |
| `message.update` / `append` / `delete` | `message.write` | 改已有消息 |
| `message.send` | `message.send` | **会触发模型调用、消耗点数**，单独一档 |
| `schedule.*` | `schedule` | 后台任务，触发时**重新校验**权限 |
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

#### 3.2.1 高敏感系统操作

这一组会**直接干预用户当前正在做的事**（打断他、锁他的应用、盖住他的屏幕），因此单列为 `confirm` 级：
每次调用都要弹原生确认框，**永不提供「不再询问」**。

| 原语 | 签名 | 返回 | 权限 | 状态 |
|---|---|---|---|---|
| `sys.screen.pullBack` | `{}` | `{ ok }` | `sys.intervene` | ⬜ 预留 |
| `sys.app.lock` | `{ pkg }` | `{ ok }` | `sys.intervene` | ⬜ 预留 |
| `sys.dialog.popup` | `{ title, content, buttons? }` → `{ buttonId }` | `sys.intervene` | ⬜ 预留 |
| `sys.overlay.show` | `{ overlayId }` | `{ ok }` | `sys.overlay` | ⬜ 预留 |
| `sys.overlay.hide` | `{}` | `{ ok }` | `sys.overlay` | ⬜ 预留 |

> **为什么合并为一个 `sys.intervene` 权限而不是五个**：这五个原语的共同性质是「打断用户」，
> 用户对它们的心理预期是同一件事。拆成五个权限只会让安装弹窗更长、用户更麻木，
> 反而不如一个语义清晰的「干预当前操作」+ 逐次确认来得安全。
>
> `sys.overlay.*` 单独一档，因为它只是叠加显示，不打断操作，风险等级低于其余四个。

### 3.3 媒体 `media.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `media.listPhotos` | `{ limit?, album?, since? }` → `[{id, thumbPath, takenAt}]` | `media.read` | 🔷 |
| `media.getPhoto` | `{ id, full?=false }` → `{ sandboxPath }` | `media.read` | 🔷 |
| `media.camera.capture` | `{ facing?='back' }` → `{ sandboxPath }` | `media.camera` | 🔷 |
| `media.camera.record` | `{ facing?, maxMs? }` → `{ jobId }` | `media.camera` | 🔷 |
| `media.audio.record` | `{ maxMs? }` → `{ jobId }` | `media.microphone` | 🔷 |
| `media.audio.play` | `{ path, loop?=false }` → `{ jobId }` | `media.read` | 🔷 |
| `media.video.play` | `{ path, loop?=false, muted?=false }` → `{ jobId }` | `media.read` | 🔷 |

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

### 3.20 上下文注入 `context.*`

宿主提供「往 AI 上下文注入」的能力，但**不预设任何业务概念**。宿主不知道「欲望」「好感度」
是什么，只知道「插件注入了一段文本 / 一个消息 / 一个钩子」。

| 原语 | 签名 | 返回 | 权限 | 状态 |
|---|---|---|---|---|
| `context.inject` | `{ text, position?='append', priority?=100, ttlMs?, scope?='session', tag? }` | `{ injectionId }` | `context.write` | ⬜ 预留 |
| `context.append` | `{ role, content, position?='end' }` | `{ ok }` | `context.write` | ⬜ 预留 |
| `context.onBuild` | `{ handler, priority?=100 }` | `{ hookId }` | `context.hook` | ⬜ 预留 |
| `context.onBeforeModel` | `{ handler, priority?=100 }` | `{ hookId }` | `context.hook` | ⬜ 预留 |
| `context.onAfterModel` | `{ handler, priority?=100 }` | `{ hookId }` | `context.hook` | ⬜ 预留 |

字段说明：

| 字段 | 取值 | 含义 |
|---|---|---|
| `position` | `prepend` / `append` | 注入到 system prompt 的开头还是结尾 |
| `priority` | 数字，越小越靠前 | 多个插件注入时的排序依据 |
| `scope` | `once` / `session` / `persistent` | 只在下一轮 / 本次会话 / 一直有效 |
| `ttlMs` | 毫秒 | 到点自动失效，防止插件注入的内容永久污染上下文 |
| `tag` | 字符串 | 插件自己的标记，便于后续 `context.clear({tag})` 精确撤销 |

**三条硬约束**：

1. **可撤销**。每次注入返回 `injectionId`。插件停用 / 崩溃时，宿主**自动清空该插件的全部注入**。
   插件不能靠"注入后不管"来留后门。
2. **有上限**。单插件注入总长度上限（默认 8 KB），且所有插件注入总量上限（默认 32 KB）。
   防止某个插件把上下文撑爆、把用户的 token 烧光。
3. **可审计**。每次注入记审计（只记 tag 与长度，不记内容全文）。

> **为什么不做 `context.replace`**：让插件替换整个 system prompt 会让插件能冒充宿主设定的人设，
> 也会让多个插件互相覆盖到不可预期。只给「追加 + 排序 + 撤销」，能力足够且可控。

### 3.21 消息操作 `message.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `message.update` | `{ messageId, patch }` | `message.write` | ⬜ 预留 |
| `message.append` | `{ messageId, content }` | `message.write` | ⬜ 预留 |
| `message.send` | `{ content, role?='assistant' }` | `message.send` | ⬜ 预留 |
| `message.delete` | `{ messageId }` | `message.write` | ⬜ 预留 |
| `message.get` | `{ messageId }` / `{ sessionId, limit? }` | `message.read` | ⬜ 预留 |

`patch` 只允许改**白名单字段**：`content` / `richContent` / `meta.<pluginId>.*`。
**不允许**改 `id` / `role` / `sessionId` / `createdAt` / `status` —— 那些是宿主的结构字段，
让插件改会造成数据模型自相矛盾。

`message.send` 与 `message.append` 分开的理由：前者会**触发一次模型调用**（消耗点数），
后者只是改已有消息的显示。两者风险与成本差一个量级，因此权限也分开。

### 3.22 调度 `schedule.*`

| 原语 | 签名 | 权限 | 状态 |
|---|---|---|---|
| `schedule.once` | `{ delayMs, handler, tag? }` | `schedule` | ⬜ 预留 |
| `schedule.interval` | `{ periodMs, handler, tag?, immediate?=false }` | `schedule` | ⬜ 预留 |
| `schedule.cancel` | `{ id }` | `schedule` | ⬜ 预留 |
| `schedule.list` | `{}` → `[{ id, kind, periodMs, nextRunAt, tag }]` | `schedule` | ⬜ 预留 |

用于「自动触发对话」「定时检查状态」这类场景。

**四条约束**（没有约束的调度器就是耗电与烧钱黑洞）：

| 约束 | 默认 | 说明 |
|---|---|---|
| 最短周期 | 60 秒 | `periodMs < 60000` 直接拒绝；想更频繁请用事件，不要轮询 |
| 单插件任务数上限 | 16 | 超出 `RATE_LIMITED` |
| 宿主休眠时的行为 | 暂停 | 醒来后**不补跑**错过的周期，只按新周期继续 |
| 触发时的权限 | **重新校验** | 用户在任务创建后撤销了权限 → 该任务自动取消并通知插件 |

最后一条尤其重要：**调度任务不能成为绕过权限的通道**。任务每次触发都要重走守门人，
而不是在创建时校验一次就一劳永逸。

### 3.23 关于 `ui.render` 的取舍

补充文档里重新列出了 `ui.render`。**本设计不实现它**，理由与 ADR-004 一致：

- 宿主内控件走 `provides.ui` **声明式描述**（宿主渲染，保证视觉一致与不可伪装）
- 需要完全自定义外观的走 `provides.pages` **独立页面**（WebView 容器）

「让宿主动态渲染插件给的任意 UI 树」会同时破坏这两条：既拿不到一致性，又绕过了容器的
可辨识性要求（插件可以渲染出一模一样的宿主界面）。能力上并不缺失 —— 独立页面已经给了
完全自由。

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

其它原语在 Demo 阶段**必须返回 `UNSUPPORTED`**（而不是崩溃或静默），这样插件的降级逻辑也能被测到。

### 4.1 但接口必须一次留全

Demo 只**实现**四个原语，但底层必须**注册全部 23 个域**。区别在于：

| | Demo 做法 |
|---|---|
| 注册表 | 全部原语在 `PrimitiveRegistry` 里注册（含 `implemented: false` 的） |
| 未实现的原语 | handler 是统一的一个「返回 `UNSUPPORTED`」占位实现 |
| 自省 | `registry.describe()` 能列出全部原语及其权限、参数 schema、实现状态 |
| 加新原语 | 只需 `registry.register(spec)`，**不改宿主核心任何一行** |

这样做的理由：如果 Demo 只把四个原语硬编码进一个 `switch`，那么后面每加一个原语都要
动宿主核心，插件框架就退化成了「宿主写死的功能列表」。**这正是本补充文档要防的事。**

见 `docs/16-extensibility.md`。

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：统一调用/错误/超时约定、权限映射表、19 个域完整清单、Demo 范围 |
| 2026-02 | 移除 `ui.render`（与视觉一致性原则冲突），改为 `provides.ui` + `provides.pages` |
