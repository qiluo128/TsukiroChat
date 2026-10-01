# 15 · 当前进度与验证报告

> 最后更新：本轮工作结束时。**这里的「已验证」都是本机真实跑出来的结果，不是计划。**

---

## 1. 总体进度

| 工作项 | 状态 | 证据 |
|---|---|---|
| 需求整理成文档体系 | ✅ 完成 | `docs/` 下 16 篇（含索引） |
| 开发环境准备（Dart SDK） | ✅ 完成 | `C:\dev\dart-sdk`，Dart 3.12.2 |
| 插件内核骨架（纯 Dart） | ✅ 已跑通 | `packages/plugin_core`，**271 个单测全绿** |
| 静态分析 | ✅ 零问题 | `dart analyze` → `No issues found!` |
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
00:00 +271: All tests passed!
```

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
| ~~1~~ | ~~`bridge/codec` + 单测~~ | — | ✅ **已完成**（`src/bridge/envelope.dart`）。握手门禁尚在宿主侧实现 |
| ~~2~~ | ~~`packaging`（inspector）+ 单测~~ | — | ✅ **已完成**（`package_inspector.dart` + `zip_reader.dart`）。**installer 状态机仍未做** |
| 3 | `audit` + redactor + 单测 | — | 审计脱敏（手机号打码、内容不落库、密钥绝不记录） |
| 4 | `registry/slot_registry` + `page_registry` | — | 插槽表与页面表，UI 扩展点的宿主侧 |
| 5 | `packaging/installer.dart` | 2 | 安装状态机与磁盘原子性（先解压到临时目录再 rename） |
| 6 | `bridge/session.dart` | 1 | 握手门禁 `bridge.hello` / `bridge.ready`、实例绑定校验 |
| 7 | Flutter 宿主项目初始化 | 需确认是否装 Flutter | `flutter create --platforms=android` |
| 8 | 聊天页 + Drift + Dio SSE | 7 | Demo 流程 1 |
| 9 | Android SDK + 真机/模拟器 | 7 | 需 ≥ 15 GB 磁盘，建议真机 |
| 10 | WebView 容器 + Bridge 落地 | 6, 8 | 阶段 A3 |
| 11 | 四个原语实现 | 10 | `sys.time` / `ui.toast` / `fs.read` / `model.chat` |
| 12 | 端到端 21 项验收 | 全部 | 阶段 A4 |

**建议**：先把 3–6 做完（仍是纯 Dart，可单测），再决定 Flutter + Android SDK 那次大下载。这样即使环境准备受阻，插件内核也已经是完整可信的。

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
