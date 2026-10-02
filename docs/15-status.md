# 15 · 当前进度与验证报告

> 最后更新：本轮工作结束时。**这里的「已验证」都是本机真实跑出来的结果，不是计划。**

---

## 1. 总体进度

| 工作项 | 状态 | 证据 |
|---|---|---|
| 需求整理成文档体系 | ✅ 完成 | `docs/` 下 16 篇（含索引） |
| 开发环境准备（Dart SDK） | ✅ 完成 | `C:\dev\dart-sdk`，Dart 3.12.2 |
| 插件内核骨架（纯 Dart） | ✅ 已跑通 | `packages/plugin_core`，**299 个单测全绿，1 个刻意跳过** |
| 静态分析 | ✅ 零问题 | `dart analyze` → `No issues found!` |
| **Demo 可行性验证（无头）** | ✅ **四条流程全通** | `test/demo_e2e_test.dart`，含安全约束与可扩展性 |
| **原语 / 钩子可扩展性** | ✅ 已落地 | 24 域 112 条原语全量注册；钩子总线含错误隔离与超时 |
| 三个测试插件源码 | ✅ 完成 | `plugins/{time-plugin,translate-button,mini-game}` |
| 插件打包流水线 | ✅ 已跑通 | `scripts/pack_plugin.mjs` 产出 3 个 zip + 1 个恶意样本 |
| Zip Slip / 符号链接防护 | ✅ 已实现并测试 | 真实 zip 构造 + 三个真实插件端到端 |
| Flutter 宿主 App | ⬜ 未开始 | 见 [12-demo-plan](12-demo-plan.md) 阶段 A2 |
| WebView + Bridge 实际联通 | ⬜ 未开始 | 阶段 A3 |
| Demo 端到端 21 项验收 | ⬜ 未开始 | 阶段 A4 |

---

## 2. 本轮真实验证结果

### 2.1 环境

```
Dart SDK     3.12.2 (stable) windows_x64   @ C:\dev\dart-sdk   1011 个文件
Node.js      v26.7.0
Git          2.55.0.windows.3
Python       3.8.6
```

下载路径决策：官方 `storage.googleapis.com` 实测约 **0.12 MB/s**（204MB 需 4 小时以上），
`storage.flutter-io.cn` 实测约 **3.7 MB/s**（实际 1 分钟内完成）。已用 `scripts/bench_mirrors.mjs`
固化为可复现的测量，`fetch-dart.mjs` 默认走国内镜像。

### 2.2 插件内核

```
$ dart analyze
Analyzing plugin_core...
No issues found!

$ dart test
00:00 +299 ~1: All tests passed!
```

（`~1` 是一个刻意跳过的用例：`ui.navigate` 仍是占位原语，跳过它正是"未实现 = UNSUPPORTED"的预期状态。）

已实现并测透的模块：

| 模块 | 文件 | 覆盖内容 |
|---|---|---|
| 错误模型 | `src/common/errors.dart` | 17 个错误码 + `retryable` 语义 + Bridge 序列化 |
| 语义化版本 | `src/common/semver.dart` | 解析/比较/预发布、`hostApi` 范围匹配 |
| 权限目录 | `src/permission/permission.dart` | 33 个权限、三级分级、原语→权限映射（含不变量测试） |
| 权限守门人 | `src/permission/gatekeeper.dart` | 6 步判定顺序、声明即上限、撤销即时生效、热路径无 IO |
| manifest 模型 | `src/manifest/manifest.dart` | 工具/UI/页面完整建模，预留段原样保留 |
| manifest 解析 | `src/manifest/parser.dart` | 全字段校验、问题一次性收集、参数简写展开、兼容性检查 |
| 工具注册表 | `src/registry/tool_registry.dart` | 重名加前缀不覆盖、三重可见性过滤、OpenAI 格式导出 |
| 沙箱路径守门 | `src/sandbox/path_guard.dart` | 三层防御：词法 / 真实路径 / 大小写 |
| **Bridge 协议** | `src/bridge/envelope.dart` | 5 种消息编解码、UTF-8 字节级大小限制、拒绝更高协议版本、逐 kind 结构校验、请求 id 配对表、流式分片序号校验 |
| **插件包检查** | `src/packaging/package_inspector.dart` | Zip Slip、符号链接、原生二进制、禁止目录、体积上限、zip bomb、manifest 定位（**纯逻辑，不含 zip 库**） |
| **zip 适配层** | `src/packaging/zip_reader.dart` | `archive` 库适配；**只把通过检查的文件读进内存**（报错路径上不加载可疑内容） |
| **原语注册表** | `src/primitive/primitive_registry.dart` | 全部原语调用的唯一入口；权限→参数→执行→审计一条流水线；`describe()` 自省 |
| **原语目录** | `src/primitive/primitive_catalog.dart` | **24 个域 / 112 条原语全量注册**，Demo 只给 7 个真实现，其余是合法占位状态 |
| **宿主服务接口** | `src/primitive/host_services.dart` | `HostClock` / `HostUi` / `HostFiles` / `SandboxProvider` / `ModelGateway` / `MessageStore` / `ContextSink` / `HostScheduler` |
| **服务注册表** | `src/primitive/service_registry.dart` | 按**类型**取服务，加宿主能力不改内核容器 |
| **钩子总线** | `src/hook/hook_bus.dart` | 9 个相位 + 优先级确定性排序 + **错误隔离** + 超时 + 观察模式违约检测 |
| **审计与脱敏** | `src/audit/audit.dart` | 审计写入接口 + 逐原语脱敏（手机号打码、对话原文不落库、密钥绝不记录） |
| **参数校验** | `src/primitive/schema_validator.dart` | JSON Schema 子集；未知 `type` 值 fail-closed |
| **消息模型** | `src/agent/chat_message.dart` | `ChatMessage` / `ToolCall`，含 OpenAI 格式互转 |
| **无头验证台** | `test/support/headless_host.dart` | 安装流程 + Agent 循环 + 工具分发，**不依赖 Flutter** |

### 2.3 测试抓到的真实缺陷（值得记录）

写代码时看不出来、**跑测试才暴露**的问题，全部已修：

| # | 缺陷 | 严重度 | 说明 |
|---|---|---|---|
| 1 | `requiredPermissionFor('fs.read')` 返回 `fs` | **高（安全）** | 域名兜底跳过了精确表，`fs` / `media` / `app` 这些不存在的权限名导致映射失效。若放任，等于权限校验按错误的名字查询 |
| 2 | `requiredPermissionFor('media.read')` 返回 `media` | **高（安全）** | 同上 |
| 3 | `location` / `net` / `ui` / `a11y` / `mcp` 映射为 `null` | **高（安全）** | 无点号的权限名被「原语必须是 domain.action」的格式检查误杀，返回 null = 无需权限 = **fail-open** |
| 4 | `SemVer.parse` 接受 `v1.0.0` | 中 | 宽松解析会让 `v1.0.0` 与 `1.0.0` 变成两个不同版本字符串，版本比较与去重埋坑 |
| 5 | `Style.macOS` 不存在 | 低（编译错误） | `path` 包的 `Style` 只有 `posix`/`windows`/`url`，macOS 在它眼里也是 posix |
| 6 | `expandParameterShorthand` 复制而非复用完整 schema | 低 | 破坏引用一致性 |
| 7 | **文档里的 manifest 布局例子自相矛盾** | 中（文档缺陷） | `docs/04-plugin-spec.md` 把 `src/manifest.json` 列为「两层，拒绝」，但它与 `time-plugin-1.0.0/manifest.json` 结构完全相同，规则上无法一个拒一个收。写测试时才暴露，已修正文档（真正的两层是 `a/b/manifest.json`） |
| 8 | **宿主的 hostApi 版本与插件声明的主版本对不上** | **高（集成）** | 三个插件的 manifest 都写 `hostApi: "^1.0.0"`，而无头宿主报 `0.1.0` → `satisfiesHostApi` 判不兼容 → **三个插件一个都装不上**，下游 16 个用例连锁失败。教训：`minHostVersion` 是下限（0.1.0 被 1.0.0 满足），`hostApi` 是**范围匹配**（major 必须相同），两者语义不同，很容易配出自相矛盾的清单 |
| 9 | 测试假实现用 `text.codeUnits` 存中文 | 中（测试缺陷） | 中文的 code unit（U+4F60 = 20320）塞进 `Uint8List` 被截成 8 位，读回乱码。**任何"字符串 → 字节"的转换都必须显式 UTF-8** |

**其中 1–3 都是 fail-open 方向的缺陷** —— 如果不写这几条测试，权限系统会静默失效而没人发现。这正好验证了 ADR-009「先做纯 Dart 内核 + 单测」的判断：这些问题在 Flutter + Android + WebView 混合环境里几乎不可能定位。

第 7 条说明另一件事：**规格文档本身也需要被测试检验**。文档里一个想当然的例子直接和实现规则冲突，只有把它写成断言才会暴露。

### 2.4 插件打包

```
dev.tsukiro.time-1.0.0.zip            2.4 KB  sha256 cae77f10…
dev.tsukiro.translate-1.0.0.zip       4.1 KB  sha256 fb3c0b83…
dev.tsukiro.guess-number-1.0.0.zip    4.4 KB  sha256 9264e061…
dev.tsukiro.time-1.0.0-MALICIOUS.zip  2.6 KB  ← 含 ../evil-traversal.txt，用于测 Zip Slip 防护
```

打包脚本自身也抓到一个真实问题：`translate-button` 声明了 `pages/preview.html` 但文件不存在，安装前校验直接拒绝。这正是设计意图——**校验要在安装前拦住，而不是等到用户打开页面才白屏**。

---

## 3. 本机沙箱的四个坑（已固化到脚本与文档）

| 坑 | 表现 | 处理 |
|---|---|---|
| schannel 无凭据 | `curl` / `Invoke-WebRequest` 报 `SEC_E_NO_CREDENTIALS` | 用 Node / Python 下载（`scripts/fetch-dart.mjs`） |
| Dart 写工作区外 | `pub get` 报 `PathAccessException: C:\Users\...\AppData\Roaming\.dart-tool` | `scripts/dart.ps1` 把 `APPDATA` / `LOCALAPPDATA` / `PUB_CACHE` 重定向进仓库 `.dart/` |
| 命名管道被禁 | `dart analyze` / `dart test` 报 `CreateFile failed 5`（要起 `frontend_server` 子进程） | 这两条命令需一次性 `danger-full-access` 提权；`pub get` / `format` 不需要 |
| 系统信息被拒 | `Get-Volume` / `fsutil` 拒绝访问 | 磁盘空间只能手工确认（Flutter + Android SDK 需 ≥ 15 GB） |

---

## 4. 下一步（按依赖顺序）

| # | 任务 | 依赖 | 说明 |
|---|---|---|---|
| ~~1~~ | ~~`bridge` 编解码~~ | — | ✅ **已完成**（`src/bridge/envelope.dart`） |
| ~~2~~ | ~~`packaging` 包检查~~ | — | ✅ **已完成**（`package_inspector.dart` + `zip_reader.dart`） |
| ~~3~~ | ~~`audit` + redactor~~ | — | ✅ **已完成**（`src/audit/audit.dart`） |
| ~~4~~ | ~~原语注册表与钩子总线~~ | — | ✅ **已完成**（`primitive_registry.dart` / `hook_bus.dart` / 全量目录） |
| ~~5~~ | ~~无头 demo 可行性验证~~ | — | ✅ **已完成**（`test/demo_e2e_test.dart`，四条流程全通） |
| 6 | `registry/slot_registry` + `page_registry` | — | 插槽表与页面表。**这是新增 `chat.message.after` 的前置**，也是 `slot.list` 自省原语的前置 |
| 7 | `packaging/installer.dart` | 2 | 安装状态机与磁盘原子性（先解压到临时目录再 rename） |
| 8 | `bridge/session.dart` | 1 | 握手门禁 `bridge.hello` / `bridge.ready`、WebView 实例绑定校验 |
| 9 | `context` / `message` / `schedule` 的接口实现 | 4 | 内核侧接口已定（`ContextSink` / `MessageStore` / `HostScheduler`），差纯 Dart 参考实现与单测 |
| 10 | `provides.theme` 解析为强类型（L1 设计令牌） | — | 令牌白名单 + 未知令牌名拒绝 |
| 11 | `layout` / `replaces` 写进 manifest schema（不执行） | — | NFR-COMP-01：字段一次留全 |
| 12 | Flutter 宿主项目初始化 | 需装 Flutter | `flutter create --platforms=android` |
| 13 | 聊天页 + Drift + Dio SSE | 12 | Demo 流程 1 |
| 14 | Android SDK + 真机/模拟器 | 12 | 需 ≥ 15 GB 磁盘，建议真机 |
| 15 | WebView 容器 + Bridge 落地 | 8, 13 | 阶段 A3。**在此之前 `headless_host.dart` 的桩要换成真的 JS 运行时** |
| 16 | 端到端 21 项验收（真机） | 全部 | 阶段 A4 |

**建议**：6–11 全部仍是纯 Dart、可单测。做完再决定 Flutter + Android SDK 那次 6–8 GB 下载 —— 那样即使环境准备受阻，插件内核与 Demo 逻辑都已经是完整可信的。

> **无头验证台的边界**：`test/support/headless_host.dart` 能证明**架构成立**，
> 不能证明「WebView 能跑 JS」。后者只有真机验证，是阶段 A3 的事。
> 详见该文件顶部的说明。

---

## 5. 与文档的偏差（已回写）

| 原文档写法 | 实际做法 | 原因 |
|---|---|---|
| `PUB_CACHE = C:\dev\pub-cache` | 改为仓库内 `.dart/pub-cache` | 沙箱不允许写工作区外，每次 pub 都提权不可接受 |
| `scripts/dart.ps1` 用法写 `pwsh -File` | 实际用 `& .\scripts\dart.ps1` | 本机未安装 PowerShell 7，只有 Windows PowerShell |
| `analysis_options` 启用 `require_trailing_commas` | 已移除 | 纯格式偏好，产生 57 条 info 噪音，遮蔽真正重要的检查 |
| `accounts` 声明「`dart analyze` 零 warning」 | 现为零 issue | 已达成，改为更严的标准 |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：进度表、真实验证结果、测试抓到的 6 个缺陷、沙箱四坑、下一步 |
