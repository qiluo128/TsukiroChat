# plugin_core

Tsukiro Chat 插件内核。**纯 Dart，无 Flutter 依赖。**

## 为什么单独成包

插件系统的技术风险集中在：manifest 校验、权限守门、Bridge 编解码、Zip Slip 防护、工具调用循环。
这些**全部是纯逻辑**，不需要 Android、不需要 WebView。

把它们抽成纯 Dart 包后，可以在桌面用 `dart test` 测透。否则调试域会变成
「Flutter + Android + WebView + JS + Dart」五层混合，一个「插件装不上」要查五个地方。

见 `docs/14-decisions.md` 的 ADR-002 与 ADR-009。

## 快速开始

```powershell
# 在仓库根目录执行
& .\scripts\dart.ps1 pub get        # 或先 cd packages\plugin_core
```

> `scripts/dart.ps1` 会把 `APPDATA` / `LOCALAPPDATA` / `PUB_CACHE` 重定向到 `<repo>\.dart\`。
> 直接调 `dart.exe` 会因为写工作区外而被沙箱拒绝，详见 `docs/13-dev-environment.md`。

```powershell
cd packages\plugin_core
& ..\..\scripts\dart.ps1 analyze    # 需要一次性 danger-full-access 提权
& ..\..\scripts\dart.ps1 test       # 需要一次性 danger-full-access 提权
```

当前状态：**349 个单测全绿，`dart analyze` 零问题。**

## 模块地图

```
lib/
├─ plugin_core.dart                  # 公开 API 出口
└─ src/
   ├─ common/
   │  ├─ errors.dart                 # 17 个错误码 + retryable 语义 + Bridge 序列化
   │  └─ semver.dart                 # 严格 semver 解析/比较 + hostApi 范围匹配
   ├─ permission/
   │  ├─ permission.dart             # 权限目录（33 项 / 三级分级）+ 原语→权限映射
   │  └─ gatekeeper.dart             # 宿主侧唯一校验点，6 步判定顺序
   ├─ manifest/
   │  ├─ manifest.dart               # 数据模型（tools / ui / pages 完整建模）
   │  └─ parser.dart                 # 解析 + 全字段校验 + 简写展开 + 兼容性检查
   ├─ registry/
   │  └─ tool_registry.dart          # 重名加前缀不覆盖 + 三重可见性过滤 + OpenAI 导出
   ├─ sandbox/
   │  └─ path_guard.dart             # 三层路径穿越防御
   ├─ bridge/
   │  └─ envelope.dart               # 5 种 Bridge 消息 + 编解码 + id 配对 + 流式序号
   └─ packaging/
      ├─ package_inspector.dart      # 包安全与结构检查（纯逻辑，无 zip 库依赖）
      └─ zip_reader.dart             # archive 库适配，只加载通过检查的文件
```

## 设计要点（读代码前先读这几条）

### 1. 权限校验在宿主侧，不在 WebView 里

JS 层过滤可被绕过（保存函数引用、改原型、直接构造 Bridge 消息）。
`Gatekeeper.check()` 是唯一权威判定，每次原语调用都要走。

### 2. 声明即上限

插件只能调用自己在 manifest 里**声明过**的权限，即使该权限已授予其他插件。
`GateDecision.notDeclared` 与 `notGranted` 是两个不同的失败原因，插件要能区分。

### 3. 判定顺序本身就是安全策略

```
① 插件是否已注册      → unknownPlugin
② 权限名是否在目录    → unknownPermission
③ 是否为 denied 级    → deniedLevel
④ 插件是否声明        → notDeclared
⑤ 用户是否已授予      → notGranted
⑥ 是否为 confirm 级   → confirmRequired
```

**不要调整这个顺序。** 例如把 ③ 放到 ④ 之前，未声明的 denied 权限会得到错误的原因；
把 ② 放到 ④ 之后，拼错的权限名会被当成「未声明」而不是「不存在」，掩盖配置错误。

### 4. fail-closed

- 未知权限级别 → 按 `denied` 处理
- 未知原语域名 → 返回域名本身（不在目录中 → 拒绝），**绝不返回 null**
- 非法 semver 范围 → 不匹配
- 未知 manifest 字段 → 拒绝

返回 `null` 在 `requiredPermissionFor` 里意味着「无需权限」，那是 fail-open，绝不允许。

### 5. 重名不覆盖

后注册的同名工具改名为 `<插件前缀>__<原名>` 并记入 `conflicts`。
静默覆盖会让先装的插件莫名失效，且极难排查。

## 测试覆盖重点

| 测试文件 | 覆盖 |
|---|---|
| `semver_test.dart` | 解析严格性、比较、预发布、范围匹配 |
| `permission_test.dart` | 目录完整性、高风险权限分级、映射不变量（**曾抓到 3 个 fail-open 缺陷**） |
| `gatekeeper_test.dart` | 6 步判定、声明即上限、撤销即时生效、热路径无 IO |
| `path_guard_test.dart` | `..` / 绝对路径 / UNC / URL 编码 / 双重编码 / NUL / 符号链接 / 大小写 |
| `manifest_parser_test.dart` | 真实插件 manifest + 逐字段非法输入 + 问题一次性收集 |
| `tool_registry_test.dart` | 注册注销、重名冲突、三重过滤、导出格式、排序稳定性 |
| `bridge_codec_test.dart` | 5 种消息往返、UTF-8 字节级大小限制、协议版本拒高、逐 kind 结构校验、id 配对、流式 seq |
| `package_inspector_test.dart` | Zip Slip（8 种写法）、符号链接、原生二进制（10 种扩展名）、禁止目录、体积与 zip bomb、manifest 定位 |
| `zip_reader_test.dart` | 真实 zip（内存构造）+ **三个真实插件端到端**：zip → 检查 → 解析 manifest → 校验文件存在 → 注册工具 → 导出 |

> `zip_reader_test.dart` 会把 `plugins/` 下的三个真实插件当场打成 zip 跑完整链路，
> 所以任何一个插件声明了不存在的文件，测试就会红。

## 尚未实现（见 docs/15-status.md §4）

- `packaging/installer.dart` —— 安装状态机与磁盘原子性（先解压到临时目录再 rename）
- `bridge/session.dart` —— 握手门禁（`bridge.hello` / `bridge.ready`）与 WebView 实例绑定校验
- `audit/` —— 审计日志与参数脱敏
- `registry/slot_registry.dart` / `page_registry.dart` —— UI 插槽表与页面表
