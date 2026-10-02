# Tsukiro Chat

面向人机恋 / AI 陪伴圈子的轻量、低门槛、可插件化扩展的聊天平台。

> **一句话定位**：下载 → 30 秒内开始对话。用户不需要找 API 站、配 Key、填 URL。

仓库：<https://github.com/qiluo128/TsukiroChat>

---

## 项目状态

| 工作项 | 状态 |
|---|---|
| 需求与架构文档 | ✅ 完成（`docs/` 16 篇，含索引） |
| 开发环境准备 | ✅ Dart SDK 3.12.2 @ `C:\dev\dart-sdk` |
| 插件内核（纯 Dart） | ✅ **299 个单测全绿，`dart analyze` 零问题** |
| 三个测试插件源码 + 打包流水线 | ✅ 完成（含 Zip Slip 恶意样本） |
| Flutter 宿主 App | ⬜ 未开始 |
| Demo 端到端验收 | ⬜ 未开始 |

详见 [docs/15-status.md](docs/15-status.md)。

---

## 仓库结构

```
TsukiroChat/
├─ docs/                     # 文档体系（先读 docs/README.md）
├─ packages/
│  └─ plugin_core/           # 纯 Dart：manifest / 权限 / 工具注册 / 沙箱（无 Flutter 依赖，可单测）
│     ├─ lib/src/
│     └─ test/
├─ plugins/                  # 官方测试插件源码
│  ├─ time-plugin/           # 工具调用链路
│  ├─ translate-button/      # UI 插槽 + 插件调 AI
│  └─ mini-game/             # 独立页面 + 页面内调 AI
├─ scripts/                  # 环境、下载、打包工具
│  ├─ check_env.ps1          # 环境自检
│  ├─ dart.ps1               # Dart 命令包装（重定向家目录以适配沙箱）
│  ├─ fetch-dart.mjs         # 下载 Dart SDK（Node，绕过 schannel 问题）
│  ├─ bench_mirrors.mjs      # 下载源测速
│  └─ pack_plugin.mjs        # 插件打包 + 安装前校验（零依赖 zip writer）
├─ dist/                     # 打包产物（不进版本控制）
└─ .dart/                    # Dart 的 pub 缓存与配置（不进版本控制）
```

工具链统一装在 `C:\dev\`：

```
C:\dev\
├─ dart-sdk\                        # ✅ 已装
└─ flutter\  jdk\  android-sdk\     # ⬜ Flutter 宿主阶段再装（约 6–8 GB）
```

---

## 快速开始

```powershell
# 环境自检
& .\scripts\check_env.ps1

# 插件内核：静态分析 + 单元测试
#   analyze / test 需要一次性 danger-full-access 提权（沙箱禁止命名管道，见 docs/13）
& .\scripts\dart.ps1 pub get
& .\scripts\dart.ps1 analyze        # → No issues found!
& .\scripts\dart.ps1 test           # → All tests passed!  (299)

# 打包三个测试插件
foreach ($p in 'time-plugin','translate-button','mini-game') {
  node scripts\pack_plugin.mjs "plugins\$p" --out dist
}

# 造一个含 Zip Slip 的恶意包，用于验证宿主的防护
node scripts\pack_plugin.mjs plugins\time-plugin --out dist --malicious-traversal
```

---

## 阅读顺序

1. [docs/15-status.md](docs/15-status.md) —— **现在做到哪了**（含真实验证结果）
2. [docs/01-overview.md](docs/01-overview.md) —— 定位、核心原则、术语表、自由度七层
3. [docs/02-requirements.md](docs/02-requirements.md) —— 带编号的功能 / 非功能需求
4. [docs/03-architecture.md](docs/03-architecture.md) —— 分层架构、运行时拓扑、关键数据流
5. [docs/04-plugin-spec.md](docs/04-plugin-spec.md) —— 插件包格式与 manifest 完整 schema
6. [docs/12-demo-plan.md](docs/12-demo-plan.md) —— Demo 实施与 21 项验收脚本

---

## 核心约束（不可违反）

1. **密钥只在后端** —— 客户端和插件永远接触不到上游 API Key。
2. **插件不碰系统 API** —— 必须走宿主原语，宿主是唯一守门人。
3. **权限安装时授权** —— 同意后不再打扰，但可随时撤销，撤销即刻生效。
4. **框架尽可能底层** —— 原语原子化（`fs.read`，而不是「读角色卡」），插件自由组合。
5. **默认路径极简** —— 高级配置默认隐藏，普通用户不接触任何技术项。

---

## 本机沙箱的四个坑

已在 `scripts/` 里绕开，细节见 [docs/13-dev-environment.md](docs/13-dev-environment.md)：

| 坑 | 绕法 |
|---|---|
| `curl` / `Invoke-WebRequest` 拿不到 TLS 凭据 | 用 Node / Python 下载 |
| Dart 默认写 `%APPDATA%`（工作区外） | `scripts/dart.ps1` 重定向到 `.dart/` |
| `dart analyze` / `dart test` 需要命名管道 | 这两条命令提权跑 |
| 官方下载源慢 30 倍 | 用 `storage.flutter-io.cn` |
