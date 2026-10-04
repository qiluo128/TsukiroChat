# 13 · 开发环境

## 1. 当前环境实况（本机实测）

| 组件 | 状态 | 版本 | 路径 |
|---|---|---|---|
| Windows | ✅ | — | — |
| Git | ✅ | 2.55.0.windows.3 | `C:\Apps\Git\cmd\git.exe` |
| Node.js | ✅ | v26.7.0 | `C:\Program Files\nodejs\node.exe` |
| Python | ✅ | 3.8.6 | `C:\Program Files\python\python.exe` |
| **Dart SDK**（独立） | ✅ 已装 | **3.12.2 stable** | `C:\dev\dart-sdk`，仅用于纯内核单测 |
| **Flutter** | ✅ 已装 | **3.47.6 stable**（Dart 3.13.5） | `C:\dev\flutter` |
| **JDK** | ✅ 已装 | **Temurin 17.0.20.1+1** | `C:\dev\jdk` |
| **Android SDK** | ✅ 已装 | platform 36 / build-tools 36.0.0 / NDK r28c | `C:\dev\android-sdk` |
| **Gradle 家目录** | ✅ 已配 | Gradle 9.3.1 + 国内镜像 | `C:\dev\gradle-home` |
| Android Studio | ⬜ 未装 | — | 不需要：只用 cmdline-tools，省 3–4 GB |
| 模拟器 | ⬜ 未装 | — | **建议用真机** |
| Visual Studio Build Tools | ⬜ 未装 | — | 仅 Windows 桌面目标需要 |

**工具链总计约 10.1 GB**（flutter 3111 + gradle-home 3353 + android-sdk 2805 + dart-sdk 568 + jdk 303 MB）。

**构建验证**：`app-debug.apk` 143.5 MB 构建成功（首次含 NDK 下载，360 秒）。

> **Flutter / Android SDK 已装**（2026-10 更新）。~~不装是刻意的选择~~ —— 当时是为了先把
> 插件内核（纯 Dart、可单测）测透再付那 10 GB。内核与模型层测透之后才装的工具链。
> 见 [15-status](15-status.md) 与 ADR-009。

### 1.1 工具链安装位置约定

```
C:\dev\
├─ dart-sdk\          # 独立 Dart（仅纯内核单测用，与 Flutter 自带的那个并存）
├─ flutter\           # Flutter SDK 3.47.6（自带 Dart 3.13.5）
├─ jdk\               # Temurin JDK 17.0.20.1
├─ android-sdk\       # cmdline-tools + platform 36 + build-tools 36 + NDK r28c
├─ gradle-home\       # GRADLE_USER_HOME：Gradle 分发 + 依赖缓存 + init.gradle
└─ pub-cache\         # （实际落在仓库内 .dart/pub-cache，见 §2.5）
```

**为什么不放在仓库内**：工具链 10 GB，不应进版本控制，也不应随仓库移动。

---

## 1.2 Gradle 国内镜像 —— **不做这步构建一定失败**

实测（`scripts/bench_maven.mjs`）：

| 域名 | 结果 | 影响 |
|---|---|---|
| `maven.google.com` | **TIMEOUT** | 解析 Android 依赖全靠它 |
| `services.gradle.org` | TLS 失败 | Gradle wrapper 下载 Gradle 自身 |
| `maven.aliyun.com/repository/*` | ✅ 可用 | 替代 google / central |
| `mirrors.cloud.tencent.com/gradle` | ✅ 可用 | 替代 Gradle 分发 |

配置：`& .\scripts\setup_gradle.ps1 -PatchTemplates`

1. `C:\dev\gradle-home\init.gradle` —— settings 层兜底
2. **改 Flutter 的工程模板** `settings.gradle.kts.tmpl`：把镜像插进 `repositories {}` 的**最前面**
3. 顺带改已有工程的 `settings.gradle.kts`

### ⚠️ 这里踩过一个坑，值得单独记

第一版用 `init.gradle` 的 `allprojects { repositories { … } }` 注入，构建报：

```
Build was configured to prefer settings repositories over project repositories
but repository 'maven' was added by settings file 'settings.gradle.kts'
```

两个问题：

1. **新版 Gradle 默认 `PREFER_SETTINGS`**，拒绝项目级仓库
2. 就算能加，`settingsEvaluated` 里**追加**是排在后面的。Gradle 按声明顺序
   **依次尝试**仓库，于是仍然先撞 `google()`（超时）—— **配置"看起来生效了"，构建照样卡住**

**结论：镜像必须改 settings 层的声明顺序并放最前，不能做外围注入。**

---

## 1.3 Android 清单：两个只在 release 包上暴露的坑

装机测试时「测试连接」直接报无网络（**不是超时，是瞬间失败**）。原因有两个，
都只在 release 包上出现 —— debug 包、单测、`flutter analyze` 全都正常。

### ① `INTERNET` 权限只在 `debug/AndroidManifest.xml` 里

Flutter 的模板**故意**这么做（调试要热重载）。但 release 构建合并后的清单里
**没有 INTERNET 权限**，所有网络请求瞬间失败。

**修法**：把 `<uses-permission android:name="android.permission.INTERNET"/>`
加到 `main/AndroidManifest.xml`。

### ② Android 9+ 默认禁止明文 HTTP

用户的 Base URL 常常是 `http://`（国内大量中转站没有证书）。
默认配置下会被系统拦掉，报 `Cleartext HTTP traffic not permitted`。

**修法**：加 `res/xml/network_security_config.xml` 并在 `<application>` 里引用。

**为什么是全局放开而不是白名单**：白名单要求提前知道域名，
而用户的服务商是运行时才知道的，没法预先列出。
补偿措施是宿主在设置页对 `http://` 给出**明确警示**。

> 为什么不阻止 http：国内大量中转站只有 http。
> 阻止它们等于让这些用户完全用不了。

### ③ 验证方式：`node scripts/verify_apk.mjs`

这类问题**只有看最终产物才能发现**。而且有个反直觉的点：

> **AGP 对 release 包会混淆资源文件名** ——
> `res/xml/network_security_config.xml` 在 APK 里变成 `res/XX.xml`。
> 按路径去 APK 里找，会得出"文件没打进去"的**错误结论**。

所以脚本查两处：
1. `build/app/intermediates/merged_manifest/release/.../AndroidManifest.xml`
   —— Gradle 合并后的明文清单，这才是编译进包的那一份
2. `aapt2 dump permissions <apk>` —— 从最终二进制反查
"顺序"这种事不写进文档，下一个人一定会再踩一次。


---

## 2. 沙箱环境下的注意事项（重要）

本机在 DSH 沙箱下运行，实测发现两个必须绕开的坑：

### 2.1 网络：`curl` / PowerShell 的 TLS 不可用

```
curl: (35) schannel: AcquireCredentialsHandle failed:
           SEC_E_NO_CREDENTIALS (0x8009030e)
Invoke-WebRequest: 基础连接已经关闭: 接收时发生错误
```

**原因**：沙箱限制了 schannel 对证书存储/凭据的访问。**网络本身是通的**（DNS 解析正常、TCP 443 可连）。

**绕法**：用 **Node.js** 或 **Python**（它们自带 CA bundle 与 OpenSSL TLS 栈）。

```powershell
# ✅ 可用
node scripts\fetch-dart.mjs
python -c "import urllib.request; print(urllib.request.urlopen('https://pub.dev').status)"

# ❌ 不可用（沙箱内）
curl.exe https://pub.dev
Invoke-WebRequest https://pub.dev
```

这也是 `scripts/fetch-dart.mjs` 存在的原因。

### 2.2 系统信息查询被拒

```
Get-Volume      → 拒绝访问 (HRESULT 0x80041003)
fsutil volume diskfree C:  → Error 5: Access is denied
Get-CimInstance Win32_ComputerSystem → 空结果
```

**影响**：无法在会话内读取磁盘剩余空间。安装 Flutter + Android SDK 前需**手工确认 C 盘可用空间 ≥ 15 GB**。

### 2.3 路径访问范围

- 默认沙箱策略为 `workspace-write`，只可写 `C:\Users\24074\Documents\TsukiroChat`。
- 写入 `C:\dev\` 需要一次性提权（`danger-full-access`）。

### 2.4 命名管道被禁（影响 `dart analyze` / `dart test`）

```
CreateFile failed 5 (拒绝访问)
ProcessException: 拒绝访问。 (at ../../runtime/bin/process_win.cc:742)
  Command: C:\dev\dart-sdk\bin\dartaotruntime ... analysis_server_aot.dart.snapshot
```

Dart 的 `analyze` 与 `test` 会启动 `analysis_server` / `frontend_server` 子进程并通过
**命名管道**通信。沙箱的两种受限模式都不允许创建命名管道，因此这两条命令**需要一次性
提权**（`danger-full-access`）。

不需要提权的命令：`dart pub get`、`dart format`、`dart run <单文件>`。

### 2.5 Dart 默认会写工作区外

```
PathAccessException: Creation failed,
  path = 'C:\Users\24074\AppData\Roaming\.dart-tool' (OS Error: 拒绝访问。, errno = 5)
```

Dart 默认把分析/遥测配置写到 `%APPDATA%\.dart-tool`，把包缓存写到
`%LOCALAPPDATA%\Pub\Cache`。两者都在工作区外，会被拒绝。

**解决方式**：`scripts/dart.ps1` 把三个环境变量重定向进仓库：

```powershell
$env:APPDATA      = "<repo>\.dart\AppData\Roaming"
$env:LOCALAPPDATA = "<repo>\.dart\AppData\Local"
$env:PUB_CACHE    = "<repo>\.dart\pub-cache"
```

`.dart/` 已在 `.gitignore` 中。

### 2.6 下载源速度差异巨大

实测（`scripts/bench_mirrors.mjs`，每个源拉 8 秒）：

| 源 | 吞吐 | 204MB 预计耗时 |
|---|---|---|
| `storage.flutter-io.cn` | **3.69 MB/s** | **约 1 分钟** |
| `storage.googleapis.com` | 0.12 MB/s | 约 4 小时 |
| 清华 TUNA / 中科大 / 上交 | HTTP 403 / 404 | 不可用 |

`fetch-dart.mjs` 因此默认走 `flutter-io.cn`。装 Flutter SDK 时同理，应设：

```powershell
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL           = 'https://pub.flutter-io.cn'
```

---

## 3. 安装步骤

### 3.1 Dart SDK（阶段 A1 需要）—— 已在本机验证通过

```powershell
# 1) 下载到仓库 .tmp/（Node 绕过 schannel TLS 问题；默认走国内镜像）
node scripts\fetch-dart.mjs
#    → .tmp\dartsdk-windows-x64.zip  204.2 MB
#      sha256 77fd96c823ed09a85e58209a2c5f16b0fc02e5ed4f3e3d46fddf4be763d498d6

# 2) 解压到 C:\dev\dart-sdk  （需要提权 danger-full-access）
#    用 .NET ZipFile 而不是 Expand-Archive：1011 个文件，前者 3.6 秒
Add-Type -AssemblyName System.IO.Compression.FileSystem
$staging = 'C:\dev\_dart_staging'
New-Item -ItemType Directory -Force -Path 'C:\dev', $staging | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory(
  'C:\Users\24074\Documents\TsukiroChat\.tmp\dartsdk-windows-x64.zip', $staging)
Move-Item "$staging\dart-sdk" 'C:\dev\dart-sdk'
Remove-Item $staging -Recurse -Force

# 3) 验证
C:\dev\dart-sdk\bin\dart.exe --version
#    → Dart SDK version: 3.12.2 (stable) ... on "windows_x64"

# 4) 加入 PATH（可选；本仓库的 scripts\dart.ps1 已用绝对路径，不依赖 PATH）
[Environment]::SetEnvironmentVariable(
  'PATH', "C:\dev\dart-sdk\bin;" + [Environment]::GetEnvironmentVariable('PATH','User'), 'User')
```

**不要**把 `PUB_CACHE` 设到 `C:\dev`：沙箱不允许写工作区外，会导致每次 `pub get` 都要提权。
统一用 `scripts/dart.ps1`，它会把 Dart 的家目录重定向到仓库内的 `.dart/`。

### 3.2 Flutter SDK（阶段 A2 需要）

```powershell
git clone --depth 1 -b stable https://github.com/flutter/flutter.git C:\dev\flutter
C:\dev\flutter\bin\flutter --version
C:\dev\flutter\bin\flutter config --android-sdk C:\dev\android-sdk
C:\dev\flutter\bin\flutter doctor
```

### 3.3 JDK 17（Flutter Android 构建需要）

推荐 Eclipse Temurin 17（LTS）。

```powershell
# 下载后解压到 C:\dev\jdk
[Environment]::SetEnvironmentVariable('JAVA_HOME', 'C:\dev\jdk', 'User')
[Environment]::SetEnvironmentVariable(
  'PATH', "C:\dev\jdk\bin;" + [Environment]::GetEnvironmentVariable('PATH','User'), 'User')
```

### 3.4 Android SDK（阶段 A2 需要）

只装命令行工具，不装 Android Studio（省 3–4 GB）。

```powershell
# 1) 下载 commandlinetools-win-*.zip → 解压到 C:\dev\android-sdk\cmdline-tools\latest
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'C:\dev\android-sdk', 'User')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', 'C:\dev\android-sdk', 'User')

# 2) 安装必需组件
C:\dev\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat `
  "platform-tools" "platforms;android-34" "build-tools;34.0.0"

# 3) 接受许可
C:\dev\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat --licenses

# 4) 真机调试：开启 USB 调试，然后
C:\dev\android-sdk\platform-tools\adb.exe devices
```

**模拟器（可选，额外 2–4 GB）**：

```powershell
sdkmanager.bat "system-images;android-34;google_apis;x86_64" "emulator"
avdmanager.bat create avd -n tsukiro -k "system-images;android-34;google_apis;x86_64"
emulator.exe -avd tsukiro
```

> **建议优先用真机**。WebView 行为、权限模型、性能表现在真机上才是真实的；模拟器只能验证功能性。

### 3.5 版本清单（目标版本）

| 组件 | 目标版本 | 备注 |
|---|---|---|
| Dart | stable 最新 | 随 Flutter 升级；单测阶段用独立 SDK |
| Flutter | stable channel | `flutter --version` 记录到 README |
| JDK | 17 (LTS) | Flutter 要求 ≥ 17 |
| Android compileSdk | 34 | |
| Android minSdk | 26 (Android 8.0) | 见 NFR-COMP-04 |
| Android targetSdk | 34 | |
| Kotlin | 随 Flutter 模板 | |
| Gradle | 随 Flutter 模板 | |

---

## 4. 项目本地配置

### 4.1 `packages/plugin_core/pubspec.yaml`

```yaml
name: plugin_core
description: Tsukiro Chat 插件内核 —— manifest 解析、权限守门人、工具注册表、Bridge 协议。纯 Dart，无 Flutter 依赖。
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.5.0

dependencies:
  archive: ^3.6.1        # zip 解析
  path: ^1.9.0           # 路径规范化与穿越检测
  meta: ^1.15.0
  collection: ^1.18.0

dev_dependencies:
  test: ^1.25.0
  lints: ^4.0.0
```

**为什么 `archive` 而不是自己解析 zip**：`archive` 提供流式条目读取与 CRC 校验，且能拿到条目元数据（判断是否符号链接）。自己解析 zip 是重复造轮子且容易出安全漏洞。

**为什么 `path` 而不是字符串拼接**：跨平台分隔符差异（Windows `\` vs POSIX `/`）是路径穿越漏洞的常见来源。`p.path.normalize` + `p.isWithin` 是正确处理方式。

### 4.2 `analysis_options.yaml`

```yaml
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
  errors:
    # 安全相关，升级为错误
    avoid_dynamic_calls: error
    unused_import: error
    unused_local_variable: warning

linter:
  rules:
    - always_declare_return_types
    - prefer_final_locals
    - avoid_print            # 用日志接口，不用 print
    - require_trailing_commas
```

`strict-casts` + `avoid_dynamic_calls` 对安全代码很重要：manifest 是外部输入，动态调用会让类型错误变成运行时崩溃。

### 4.3 常用命令

统一用包装脚本 `scripts/dart.ps1`（它负责重定向 Dart 的家目录）：

```powershell
# 依赖 —— 不需要提权
& .\scripts\dart.ps1 pub get

# 静态分析 —— 需要一次性 danger-full-access 提权（命名管道）
& .\scripts\dart.ps1 analyze
# 期望输出: No issues found!

# 单元测试 —— 需要一次性 danger-full-access 提权
& .\scripts\dart.ps1 test
# 期望输出: All tests passed!   (当前 169 个)

# 跑单个文件
& .\scripts\dart.ps1 test test\gatekeeper_test.dart

# 只看失败
& .\scripts\dart.ps1 test --reporter=failures-only

# 格式化 —— 不需要提权
& .\scripts\dart.ps1 format .
```

> 注意：本机只装了 Windows PowerShell（没有 PowerShell 7），所以不要用 `pwsh -File`，
> 直接 `& .\scripts\dart.ps1` 调用。

插件的打包与校验（Node，不需要提权）：

```powershell
node scripts\pack_plugin.mjs plugins\time-plugin --out dist
node scripts\bench_mirrors.mjs 8          # 复现镜像测速
& .\scripts\check_env.ps1                 # 环境自检
```

---

## 5. 目录与文件约定

| 约定 | 规则 |
|---|---|
| 源码 | 全部 UTF-8，无 BOM |
| 换行 | LF（`.gitattributes` 强制） |
| 缩进 | Dart 2 空格；JSON 2 空格 |
| 文件名 | 小写 snake_case |
| 类名 | PascalCase |
| 常量 | lowerCamelCase（Dart 惯例，非 SCREAMING_CASE） |
| 文档 | 公开 API 必须有 `///` 注释 |

`.gitattributes`：

```
* text=auto eol=lf
*.png binary
*.zip binary
*.ttf binary
```

---

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `curl` 报 `SEC_E_NO_CREDENTIALS` | 沙箱限制 schannel 证书凭据 | 改用 Node / Python（TLS 栈自带 CA） |
| `dart pub get` 报 `PathAccessException: ...\.dart-tool` | Dart 默认写 `%APPDATA%`，工作区外 | 用 `scripts\dart.ps1`（重定向到家目录） |
| `dart analyze` / `dart test` 报 `CreateFile failed 5` | 需起子进程 + 命名管道，受限沙箱禁止 | 这两条命令用 `danger-full-access` 提权跑一次 |
| 下载 Flutter / Dart 慢到不可用 | 默认走 `storage.googleapis.com`（实测 0.12 MB/s） | 用 `storage.flutter-io.cn`（实测 3.7 MB/s） |
| `flutter doctor` 报 Android 许可未接受 | 未跑 `--licenses` | `sdkmanager.bat --licenses` |
| Gradle 首次构建极慢 | 下载 Gradle 发行版 | 手工预置 `~/.gradle`，或换国内镜像 |
| WebView 在模拟器上行为异常 | 模拟器 WebView 版本旧 | 用真机验证 |
| Windows 路径大小写导致穿越检测漏过 | 未规范化大小写 | `path_guard` 做 `toLowerCase()` 比较（有专门单测） |
| `Get-Volume` / `fsutil` 拒绝访问 | 沙箱限制 WMI 与卷查询 | 磁盘空间只能手工确认 |
| `pwsh` 不是可识别的命令 | 本机只有 Windows PowerShell | 用 `& .\scripts\dart.ps1`，不要用 `pwsh -File` |

---

## 7. 环境自检脚本

见 `scripts/check_env.ps1`，输出各组件版本与路径，并标出缺失项，同时检测沙箱的四个坑。

```powershell
& .\scripts\check_env.ps1
```

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：本机实况、沙箱两个坑与绕法、Dart/Flutter/JDK/Android 安装步骤、约定与 FAQ |
