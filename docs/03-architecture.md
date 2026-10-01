# 03 · 系统架构

## 1. 分层架构

原始六层结构保留，补齐各层职责边界与「谁不能越过谁」。

```
┌───────────────────────────────────────────────────────────────┐
│ ① 插件 manifest —— 能力声明                                    │
│    tools / ui / pages / overlays / mcp / memory / skills /     │
│    permissions / network / config / harness(预留)              │
│    职责：纯声明。不含逻辑，不含密钥。                          │
├───────────────────────────────────────────────────────────────┤
│ ② 宿主注册表 —— 汇总所有插件声明                                │
│    工具表 / UI 插槽表 / 页面表 / MCP 表 / 记忆表 / 权限表      │
│    职责：进程内单一索引。安装/卸载/停用即增删。                │
├───────────────────────────────────────────────────────────────┤
│ ③ 原语层 —— 宿主暴露的最小能力单元                              │
│    fs / sys / media / contact / sms / call / calendar / app /  │
│    notification / location / net / ui / state / crypto /       │
│    a11y / screen / model / tool / event / log / mcp(预留)      │
│    职责：原子化、无业务语义。**唯一**对外能力出口。            │
├───────────────────────────────────────────────────────────────┤
│ ④ 权限守门人 —— 唯一校验点                                      │
│    安装时授权 / 运行时校验 / 可撤销 / 审计                       │
│    职责：每个原语调用在此拦截。插件无法绕过（校验在宿主侧）。   │
├───────────────────────────────────────────────────────────────┤
│ ⑤ 沙箱层 —— 隔离                                            │
│    独立目录 / 独立 state 命名空间 / 网络白名单 / 独立 WebView   │
│    职责：把「插件 A」和「插件 B」「宿主」隔开。                 │
├───────────────────────────────────────────────────────────────┤
│ ⑥ 系统 API —— Android / iOS / Windows                          │
│    职责：真实平台能力。仅宿主可调用，插件永不可见。             │
└───────────────────────────────────────────────────────────────┘
```

### 1.1 调用方向铁律

```
插件代码 ──▶ Bridge ──▶ ④权限守门人 ──▶ ③原语层 ──▶ ⑥系统 API
                ▲                      │
                └──── 结果/事件 ◀───────┘

❌ 插件 ──▶ ⑥系统 API        （不存在这条路径）
❌ 插件 ──▶ 上游 API Key      （manifest 无此字段，原语不返回凭据）
❌ 插件 A ──▶ 插件 B 的沙箱    （路径由宿主拼接，无法构造）
```

**关键设计**：权限校验发生在 **④（宿主侧）**，而不是在 WebView 里做「接口注入」。注入可以被 JS 层绕过（改原型、缓存函数引用），宿主侧校验不能。

---

## 2. 运行时拓扑

```
┌──────────────────────── 宿主进程（Flutter / Dart） ─────────────────────────┐
│                                                                             │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐  ┌───────────────────┐   │
│  │  UI 层      │  │  会话/存储  │  │  Agent 循环   │  │  插件管理器        │   │
│  │ 聊天页      │  │  SQLite    │  │ 工具调度      │  │  安装/卸载/权限    │   │
│  │ 设置页      │  │  迁移      │  │ 流式聚合      │  │  注册表            │   │
│  │ 插件管理页  │  │            │  │              │  │                   │   │
│  └─────┬──────┘  └─────┬──────┘  └──────┬───────┘  └────────┬──────────┘   │
│        │               │                │                   │              │
│  ┌─────┴───────────────┴────────────────┴───────────────────┴──────────┐  │
│  │                        原语层（Primitive Layer）                      │  │
│  │   ⛨ 权限守门人 Gatekeeper  →  审计日志  →  实现/转发                  │  │
│  └────┬──────────────────────────────┬──────────────────────┬──────────┘  │
│       │                              │                      │             │
│  ┌────┴─────┐                 ┌──────┴──────┐        ┌──────┴──────────┐  │
│  │ Bridge   │                 │ 模型客户端   │        │ 插件仓库/存储     │  │
│  │ 服务端    │                 │ Dio + SSE   │        │ sandbox/<id>/    │  │
│  └────┬─────┘                 └──────┬──────┘        └─────────────────┘  │
│       │                              │                                     │
└───────┼──────────────────────────────┼─────────────────────────────────────┘
        │ postMessage / JS Channel    │ HTTPS
        │                              ▼
┌───────┴────────────────┐    ┌──────────────────────┐
│ 沙箱 WebView（每插件 1 个）│    │  API 网关（后期）      │
│  index.js / pages/*.html│    │  LiteLLM 聚合         │
│  ❌ 无系统 API           │    │  ⛨ 上游 Key 只在这里   │
│  ❌ 无 Key               │    │  路由/限流/计费/日志   │
│  ❌ 不能读别的插件目录    │    └──────────┬───────────┘
└─────────────────────────┘               │
                                          ▼
                                 ┌──────────────────┐
                                 │ 上游模型 Provider  │
                                 └──────────────────┘
```

---

## 3. 模块划分

### 3.1 纯 Dart 包（无 Flutter 依赖，可单元测试）

这是**先落地的部分**，也是风险最高的部分。剥离 Flutter 依赖，让插件内核在桌面即可测试。

| 包 | 模块 | 职责 |
|---|---|---|
| `plugin_core` | `manifest/` | manifest schema 定义、JSON 解析、校验、版本兼容 |
| | `registry/` | 工具表、插槽表、页面表、权限表；安装/卸载/停用 |
| | `permission/` | 权限清单、分级、授权状态、守门人 `Gatekeeper` |
| | `primitive/` | 原语签名定义、路由（`sys.time` → handler）、参数校验 |
| | `bridge/` | Bridge 消息模型、RPC 编解码、请求/响应关联、流式分片 |
| | `sandbox/` | 沙箱路径解析与路径穿越防护、state 命名空间 |
| | `audit/` | 审计日志模型与写入接口 |
| | `packaging/` | 插件 zip 解析、Zip Slip 防护、目录布局校验 |

### 3.2 Flutter 宿主（阶段 A 之后）

| 模块 | 职责 |
|---|---|
| `app/shell` | 路由、主题、全局状态 |
| `feature/chat` | 聊天页、消息列表、输入框、流式渲染 |
| `feature/plugins` | 插件管理页、安装流程、权限弹窗 |
| `feature/settings` | 设置页（含隐藏的高级设置） |
| `platform/webview` | `flutter_inappwebview` 封装、沙箱数据目录、Bridge 绑定 |
| `platform/native` | 平台通道：文件选择、权限申请、系统能力 |
| `data/db` | Drift 定义、迁移 |
| `data/repo` | 会话/消息/插件/审计仓储（只此一处直接访问 DAO） |
| `net/client` | Dio + SSE 解析 + 重试 |
| `agent/loop` | 默认 Agent 循环（可替换步骤，为 L7 预留） |

### 3.3 依赖方向（严格单向）

```
app/shell ──▶ feature/* ──▶ data/repo ──▶ data/db
                  │
                  ├──▶ agent/loop ──▶ net/client
                  │        │
                  │        └──▶ plugin_core (registry / primitive)
                  │
                  └──▶ platform/* ──▶ plugin_core (bridge / sandbox)
```

`plugin_core` **不依赖任何上层**，也不依赖 Flutter。这是硬约束，违反它就无法单测。

---

## 4. 关键数据流

### 4.1 一条普通消息的旅程

```
用户输入「你好」
  │
  ├─▶ ChatPage 乐观插入 user 消息（本地 id, status=sending）
  ├─▶ Repo.insertMessage()                       → SQLite 落库
  ├─▶ AgentLoop.run(sessionId)
  │     ├─ 组装上下文：persona 系统提示 + 最近 N 条消息
  │     ├─ 收集工具表：registry.allTools()        ← 插件声明的工具
  │     ├─ 构造请求（含 tools 字段）
  │     └─▶ ModelClient.streamChat()  ── HTTPS ──▶ 网关/上游
  │           ◀── SSE chunk ────
  │     ├─ 逐 chunk 回调 UI（append 到 streaming buffer）
  │     └─ 流结束：若含 tool_calls → 见 4.2；否则 finish
  ├─▶ Repo.finalizeMessage()                     → SQLite 更新 + usage
  └─▶ UI 定稿渲染
```

### 4.2 工具调用（时间插件）

```
模型返回 tool_calls: [{ name:"get_time", arguments:{...} }]
  │
  ├─▶ AgentLoop 解析
  ├─▶ ToolRegistry.lookup("get_time")
  │     └─ 命中插件声明 → { pluginId:"dev.tsukiro.time", handler:"handlers/get_time.js",
  │                         permissions:["sys.time"] }
  ├─▶ ① 先查权限：Gatekeeper.check(pluginId, "sys.time")
  │     └─ 未授权 → 返回 { ok:false, code:"PERMISSION_DENIED" } 给模型
  ├─▶ ② 转发给插件 WebView：
  │        Bridge.call(pluginId, "tool.invoke",
  │                    { tool:"get_time", args:{...}, callId:"c1" })
  ├─▶ ③ 插件 index.js 内 handler 执行：
  │        const t = await tsukiro.sys.time({ tz: args.tz })
  │        return { time: t.iso, human: t.human }
  ├─▶ ④ 结果经 Bridge 回传宿主
  ├─▶ ⑤ 作为 role:"tool" 消息追加进上下文
  ├─▶ ⑥ 再次调用模型 → 模型生成自然语言回答
  └─▶ 循环结束（最多 maxSteps 轮，防死循环）
```

### 4.3 插件安装（本地 zip）

```
用户点「安装插件」→ 文件选择器选 time-plugin.zip
  │
  ├─▶ ① 读 zip（内存流，不落盘）
  ├─▶ ② 定位 manifest.json（允许根目录或唯一顶层目录）
  ├─▶ ③ 解析 + schema 校验
  │      ✗ 失败 → 提示具体字段错误，中止
  ├─▶ ④ Zip Slip 检查：所有条目路径规范化后必须在解压根内
  │      ✗ 失败 → 中止 + 记录安全事件
  ├─▶ ⑤ 重复 id 检查 / 版本比较
  │      已存在 → 提示「升级 / 覆盖 / 取消」
  ├─▶ ⑥ 权限弹窗：列出 permissions[] 及 reason
  │      用户拒绝 → 中止（不落盘）
  ├─▶ ⑦ 解压到 sandbox/<pluginId>/<version>/
  ├─▶ ⑧ 注册进注册表（工具表 / 插槽表 / 页面表 / 权限表）
  ├─▶ ⑨ 触发 UI 刷新 → 插槽立即出现新按钮
  └─▶ ⑩ 审计：plugin.install
```

> **原子性要求**：③–⑥ 任一步失败，磁盘上不得留下任何残留。实现方式：先解压到临时目录，全部校验通过后再原子 rename 到最终目录。

### 4.4 UI 插槽渲染

```
插件 manifest 声明：
  provides.ui: [{ slot:"chat.toolbar", id:"translate", type:"button", label:"翻译" }]
  │
  ├─▶ 安装时 → SlotRegistry.register("chat.toolbar", decl)
  ├─▶ ChatPage 构建时 → SlotRegistry.get("chat.toolbar")
  ├─▶ 渲染为宿主风格控件（宿主决定外观，插件只给语义）
  ├─▶ 用户点击 → 宿主发事件给插件：
  │      Bridge.emit(pluginId, "ui.click", { slot:"chat.toolbar", id:"translate" })
  └─▶ 插件用 event.on("ui.click", ...) 收到，执行逻辑
         └─ 需要调 AI → tsukiro.model.chat({...})  → 走宿主，插件不接触 Key
```

**设计选择**：插槽控件由**宿主渲染**（不是插件给 HTML），保证视觉一致性和不可伪装性；只有「独立页面」和「覆盖层」才允许插件自带 HTML。详见 [08-ui-slots](08-ui-slots.md)。

---

## 5. 隔离与并发模型

| 资源 | 隔离粒度 | 说明 |
|---|---|---|
| 文件系统 | 每插件每版本独立目录 | `sandbox/<pluginId>/<version>/`，读写均限制在此 |
| 插件状态 | 每插件独立 namespace | `state.get/set` 自动加 `<pluginId>:` 前缀 |
| WebView 实例 | 每插件一个（懒加载） | 不共享 cookie / localStorage / 缓存 |
| 网络 | manifest 白名单 | 白名单外的 `net.request` 被拒绝 |
| 权限 | 每插件独立授权集 | 撤销 A 的权限不影响 B |
| 崩溃 | 插件崩溃不传染宿主 | 捕获 JS 异常 + WebView 进程死亡，停用该插件 |

**线程模型**：

- Dart 主 isolate 负责 UI + 注册表 + 守门人（这些都是轻量内存操作）。
- 数据库操作走 Drift 的后台 isolate。
- 网络流式解析走独立 isolate，chunk 通过 `SendPort` 回主 isolate。
- WebView 天然在平台侧独立线程，Bridge 消息异步投递。

---

## 6. 技术选型

### 6.1 已定选型（Demo / 近期）

| 模块 | 选型 | 理由 | 备选 |
|---|---|---|---|
| 宿主语言 | **Flutter + Dart** | 一套代码覆盖 Android/iOS，且 `plugin_core` 可用纯 Dart 写、桌面单测 | Kotlin + Compose（仅 Android，开发快但绑定平台） |
| 本地数据库 | **Drift** | 类型安全、编译期 SQL 校验、迁移能力强、支持后台 isolate | sqflite（轻但无类型安全）、Isar（已停维护） |
| 网络 | **Dio** | 拦截器、流式响应、取消、超时控制成熟 | `http`（太薄） |
| WebView | **flutter_inappwebview** | JS Channel 双向通信、独立数据目录、可注入脚本 | `webview_flutter`（通信能力弱） |
| 状态管理 | **Riverpod** | 编译期安全、易测试、无需 BuildContext | Provider / Bloc |
| 路由 | **go_router** | 声明式、深链接支持（人设包分享链接要用） | Navigator 2.0 手写 |

### 6.2 后续选型（阶段 3+）

| 模块 | 选型 | 理由 |
|---|---|---|
| 向量检索 | sqlite-vec | 与 SQLite 同库，无额外进程；阶段 7 记忆系统用 |
| 安全存储 | flutter_secure_storage | Keychain / EncryptedSharedPreferences |
| 签名校验 | Ed25519（`cryptography` 包） | 纯 Dart，跨平台一致 |
| 网关 | Python FastAPI + LiteLLM | LiteLLM 已聚合 100+ Provider，省大量适配工作 |
| 网关数据库 | Postgres（初期可 SQLite） | 行锁、事务成熟，卡密兑换需要 |
| 缓存/限流 | Redis | 限流 + 健康检查状态共享 |
| 密钥管理 | 环境变量 → 后期 Vault/KMS | 起步够用，别过早复杂化 |

### 6.3 关键选型理由展开

**为什么先用纯 Dart 做 `plugin_core`？**

Demo 最大的技术风险不是 UI，而是：manifest 校验、权限守门、Bridge 编解码、工具调用循环、Zip Slip 防护。这些全部是纯逻辑，不需要 Android。先在桌面用 `dart test` 把它们测透，再接 Flutter，可以把「装不上插件」的问题域从「Flutter + Android + WebView + JS + Dart 五层混合调试」压缩到「纯 Dart 单测」。

**为什么插槽控件由宿主渲染而不是插件给 HTML？**

1. 视觉一致性：插件 UI 如果全是自带 HTML，十个插件十种风格，产品感崩掉。
2. 不可伪装：原则要求插件不能伪装宿主 UI，宿主渲染天然满足。
3. 性能：声明式控件零 WebView 开销，只有独立页面才付 WebView 成本。

**为什么权限校验必须在宿主侧？**

任何在 WebView 内做的「接口注入」都能被 JS 绕过：保存函数引用、改 `Object.getPrototypeOf`、用 `Function.prototype.call`。唯一可靠的位置是宿主侧 —— 插件发出的每个 RPC 都要过 `Gatekeeper.check()`。

---

## 7. 仓库布局（最终形态）

```
TsukiroChat/
├─ docs/                          # 本文档体系
├─ packages/
│  ├─ plugin_core/                # 纯 Dart，可单测 —— 先做
│  │  ├─ lib/
│  │  │  ├─ plugin_core.dart      # 公开 API 导出
│  │  │  └─ src/
│  │  │     ├─ manifest/          # manifest schema + 解析 + 校验
│  │  │     ├─ registry/          # 工具/插槽/页面/权限 注册表
│  │  │     ├─ permission/        # 权限模型 + Gatekeeper
│  │  │     ├─ primitive/         # 原语路由与参数校验
│  │  │     ├─ bridge/            # Bridge 消息编解码
│  │  │     ├─ sandbox/           # 路径解析 + 穿越防护
│  │  │     ├─ packaging/         # zip 解析 + Zip Slip 防护
│  │  │     └─ audit/             # 审计日志
│  │  └─ test/
│  ├─ plugin_sdk/                 # JS 侧：tsukiro.* API 封装（后续）
│  └─ host_app/                   # Flutter App（阶段 A 之后）
├─ plugins/                       # 官方示例 / 测试插件源码
│  ├─ time-plugin/
│  ├─ translate-button/
│  └─ mini-game/
├─ scripts/
│  ├─ check_env.ps1               # 环境自检
│  ├─ install_dart.ps1            # 下载安装 Dart SDK
│  └─ pack_plugin.mjs             # 把插件目录打成 zip
├─ registry/                      # （阶段 4）中心索引
└─ .github/workflows/             # （阶段 4）插件打包 + 签名
```

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：分层架构 + 运行时拓扑 + 四条关键数据流 + 选型理由 |
