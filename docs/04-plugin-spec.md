# 04 · 插件规范

> 本文是插件作者的**合约**。宿主按此加载，插件按此编写。任何字段变更走 `manifestVersion` 兼容策略。

---

## 1. 插件包格式

一个插件就是一个 zip 文件。

```
time-plugin-1.0.0.zip
├─ manifest.json            【必需】能力声明，位于 zip 根目录
├─ index.js                 【必需】入口脚本，由 runtime.main 指定
├─ handlers/                【可选】工具处理器
│  └─ get_time.js
├─ pages/                   【可选】独立页面 HTML
│  └─ game.html
├─ assets/                  【可选】图标、图片、字体
│  └─ icon.png
├─ themes/                  【可选】美化包
├─ personas/                【可选】人设包
└─ README.md                【可选】说明
```

### 1.1 允许的目录层级

宿主查找 `manifest.json` 的规则：**zip 根目录**，或**恰好一个顶层目录下的根**（兼容 GitHub Release 打包时多包一层的情况）。

```
✅ manifest.json
✅ time-plugin-1.0.0/manifest.json
❌ a/b/manifest.json                      （两层，拒绝）
❌ a/manifest.json + b/manifest.json      （多个顶层目录，拒绝）
❌ README.md + a/manifest.json            （根目录有散落文件，拒绝）
```

> **注意**：`src/manifest.json` 与 `time-plugin-1.0.0/manifest.json` 结构完全相同，
> 无法区分，因此**两者都接受**。「两层」指的是 `a/b/manifest.json` 这种真正嵌套两层的情况。
> （早期草稿曾把 `src/manifest.json` 列为拒绝，那是错的，已修正。）

### 1.2 禁止项（安装时强制检查，违反即中止）

| 禁止内容 | 原因 |
|---|---|
| 符号链接（symlink） | 可绕过沙箱路径检查 |
| 条目路径含 `..` 或以 `/`、盘符开头 | Zip Slip 攻击 |
| 原生二进制 `.so` / `.dll` / `.dylib` / `.exe` / `.node` | 绕过 JS 沙箱直接调系统 API |
| `node_modules/` | 体积失控；依赖应打包或走 CDN |
| 单个文件 > 10 MB | 体积控制 |
| 总解压后 > 50 MB | 体积控制 |
| zip bomb（压缩比 > 200:1 且解压后 > 10 MB） | DoS 防护 |

> 上述检查在 `plugin_core/packaging` 中实现并单元测试，见 [12-demo-plan](12-demo-plan.md)。

---

## 2. `manifest.json` 完整 Schema

### 2.1 顶层结构（一次留全，含预留字段）

```jsonc
{
  // ───────── 元信息（必需） ─────────
  "manifestVersion": 1,                    // number，必需。当前固定为 1
  "id": "dev.tsukiro.time",                // string，必需。反向域名风格，全局唯一
  "name": "时间插件",                       // string，必需
  "version": "1.0.0",                      // string，必需。semver

  // ───────── 元信息（可选） ─────────
  "description": "让 AI 知道现在几点",
  "author": {
    "name": "Tsukiro",
    "url": "https://github.com/example",
    "email": "dev@example.com"
  },
  "license": "MIT",
  "homepage": "https://github.com/example/time-plugin",
  "repository": "https://github.com/example/time-plugin",
  "icon": "assets/icon.png",               // 相对路径，限 256KB，PNG/SVG
  "keywords": ["time", "utility"],

  // ───────── 兼容性 ─────────
  "minHostVersion": "0.1.0",               // 宿主低于此版本拒绝安装
  "hostApi": "^1.0.0",                     // 宿主原语 API 版本范围

  // ───────── 运行时（**纯声明式插件可整体省略**） ─────────
  // 美化包 / 人设包 / Skills 这类 L1 插件没有代码，不需要 runtime。
  // 反之：声明了 tools / ui / pages / layout / replaces / harness 就必须有 runtime，
  // 因为那些能力要靠代码实现（控件 onClick 要有人接）。宿主解析器与打包脚本都会强制这一点。
  "runtime": {
    "main": "index.js",                    // 默认 "index.js"
    "type": "module",                      // "module" | "classic"，默认 module
    "autoStart": true                      // 安装后是否立即启动，默认 true
  },

  // ───────── 权限（必需，无权限则为空数组） ─────────
  "permissions": [
    { "name": "sys.time", "reason": "读取系统时间以回答时间问题" }
    // 也接受简写： "sys.time"  （无理由时宿主显示为「未说明用途」，审核会降级）
  ],

  // ───────── 网络白名单（可选；不声明则禁止所有网络） ─────────
  "network": {
    "allow": ["https://api.example.com", "wss://gateway.tsukiro.dev"],
    "maxRequestsPerMinute": 60
  },

  // ───────── 用户可配置项（可选） ─────────
  "config": {
    "schema": {                            // JSON Schema (draft-07 子集)
      "type": "object",
      "properties": {
        "tone":   { "type": "string", "title": "翻译语气", "default": "自然",
                    "enum": ["自然", "正式", "口语"] },
        "target": { "type": "string", "title": "目标语言", "default": "中文" }
      }
    },
    "section": {                           // 在设置页的哪个插槽显示
      "slot": "settings.sections",
      "title": "翻译插件"
    }
  },

  // ───────── 能力声明（核心） ─────────
  "provides": { /* 见 2.2 – 2.9 */ },

  // ───────── 预留：L7 Harness 级 ─────────
  "harness": { /* 见 2.10，本阶段宿主忽略 */ }
}
```

### 2.2 `provides.tools` —— 工具（L2）

模型通过 function calling 触发。这是**最有价值的扩展点**。

```jsonc
"tools": [
  {
    "name": "get_time",                    // 必需。snake_case，插件内唯一
    "description": "获取当前时间。当用户询问现在几点、今天几号时调用。",  // 必需，写给模型看
    "parameters": {                        // 必需。JSON Schema 或简写形式
      "type": "object",
      "properties": {
        "timezone": { "type": "string", "description": "IANA 时区，如 Asia/Shanghai" },
        "format":   { "type": "string", "enum": ["iso", "human"], "default": "human" }
      },
      "required": [],
      "additionalProperties": false
    },
    "handler": "handlers/get_time.js",     // 必需。相对路径，必须存在于包内
    "permissions": ["sys.time"],           // 可选。工具级权限，校验时的并集基线
    "timeoutMs": 10000,                    // 可选，默认 10000，上限 60000
    "dangerous": false,                    // true 时每次调用弹确认
    "returns": "string"                    // 可选。给模型的返回值类型提示
  }
]
```

**`parameters` 简写形式**（为 L1 配置级插件准备，宿主自动展开为 JSON Schema）：

```jsonc
"parameters": { "limit": "number", "keyword": "string" }
// 等价于
"parameters": {
  "type": "object",
  "properties": { "limit": { "type": "number" }, "keyword": { "type": "string" } },
  "required": ["limit", "keyword"]
}
```

支持的类型关键字：`string` / `number` / `integer` / `boolean` / `object` / `array`。

**工具名冲突处理**：两个插件声明同名工具时，宿主保留先安装者并把后者的名字加插件 id 前缀注册（`time_plugin.get_time`），同时在审计日志记录冲突。**不静默覆盖。**

### 2.3 `provides.ui` —— 声明式插槽控件（L3）

**由宿主渲染**，插件只给语义。外观、深浅色、无障碍由宿主统一保证。

```jsonc
"ui": [
  {
    "slot": "chat.toolbar",                // 必需。见 08-ui-slots 的插槽清单
    "id": "translate",                     // 必需。插件内唯一
    "type": "button",                      // 必需。button|toggle|menu-item|text|divider|section|input|select
    "label": "翻译",                        // 必需（divider 除外）
    "icon": "lucide:languages",            // 可选。内置图标集 "lucide:<name>" 或 "asset:assets/x.png"
    "tooltip": "把上一条消息翻译成目标语言",
    "order": 100,                          // 可选，升序排列，默认 100
    "when": { "hasMessages": true },       // 可选。显示条件，宿主求值
    "onClick": { "event": "translate.clicked" },  // 可选。点击时发给插件的事件名
    "permissions": ["model.chat"],         // 可选
    "config": {                            // type 为 input/select/toggle 时
      "key": "tone",                       // 绑定 config.schema 里的字段
      "options": ["自然", "正式"]           // select 用
    }
  }
]
```

**`when` 求值上下文**（宿主提供，只读）：

| 字段 | 类型 | 含义 |
|---|---|---|
| `hasMessages` | bool | 当前会话是否有消息 |
| `hasSelection` | bool | 是否选中了某条消息 |
| `sessionActive` | bool | 是否在会话内 |
| `isStreaming` | bool | 模型是否正在输出 |
| `hasApiKey` | bool | 是否已配置可用模型（插件无法读取 Key 本身） |

### 2.4 `provides.pages` —— 独立页面（L3）

插件自带 HTML，宿主 WebView 容器打开。**这是唯一允许插件自定义外观的形态。**

```jsonc
"pages": [
  {
    "id": "game",                          // 必需，插件内唯一
    "title": "猜数字小游戏",                 // 必需，显示在容器标题栏
    "entry": "pages/game.html",            // 必需，相对路径
    "presentation": "window",              // page | window | sheet | fullscreen
    "icon": "lucide:gamepad-2",
    "size": { "width": 480, "height": 640 }, // window 模式初始尺寸
    "resizable": true,
    "bridge": true,                        // 是否注入 tsukiro.* API，默认 true
    "permissions": ["model.chat", "ui.toast"],
    "openFrom": ["chat.toolbar", "plugin.detail"]  // 可从哪些入口打开
  }
]
```

**可辨识性要求**：容器标题栏必须显示 `插件名 · 页面标题`，且带插件图标。插件 CSS **不得**覆盖宿主标题栏（宿主标题栏在 WebView 之外的原生层）。

### 2.5 `provides.overlays` —— 覆盖层（L3，阶段 5）

叠加在宿主 UI 之上，用于悬浮球、字幕层等。

```jsonc
"overlays": [
  {
    "id": "ball",
    "entry": "pages/ball.html",
    "anchor": "bottom-right",              // top-left|top-right|bottom-left|bottom-right|center
    "offset": { "x": -16, "y": -96 },
    "size": { "width": 56, "height": 56 },
    "draggable": true,
    "clickThrough": false,
    "alwaysOnTop": true,
    "permissions": ["ui.overlay"]
  }
]
```

### 2.6 `provides.skills` —— 提示词包 + 工具白名单（L1）

```jsonc
"skills": [
  {
    "id": "polite",
    "name": "礼貌模式",
    "description": "让 AI 说话更礼貌",
    "systemPrompt": "你说话要礼貌、正式，避免网络用语。",
    "allowedTools": ["get_time"],          // 启用该 skill 时模型可见的工具子集
    "deniedTools": [],
    "injectPosition": "append"             // append | prepend | replace
  }
]
```

### 2.7 `provides.themes` —— 美化包（L1，阶段 9）

```jsonc
"themes": [
  {
    "id": "sakura",
    "name": "樱花",
    "tokens": {                            // 只允许覆盖白名单 token
      "color.primary": "#FF9EC4",
      "color.userBubble": "#FFE3EE",
      "color.assistantBubble": "#F6F6F8",
      "radius.bubble": "16px",
      "font.family": "assets/NotoSansSC-Regular.ttf"
    }
  }
]
```

**安全约束**：`tokens` 只接受**值**，不接受 CSS 片段；禁止 `url()`、`expression()`、`@import`。防止主题包注入任意样式表。

### 2.8 `provides.personas` —— 人设包（L1，阶段 2）

```jsonc
"personas": [
  {
    "id": "yuki",
    "name": "雪",
    "avatar": "assets/yuki.png",
    "description": "冷淡但心软的学姐",
    "systemPrompt": "你是雪……",
    "greeting": "……又是你。",
    "exampleDialogs": [
      { "user": "在吗", "assistant": "在你身后。" }
    ],
    "tags": ["学姐", "冷淡"]
  }
]
```

### 2.9 `provides.mcp` / `provides.memory` —— 预留

```jsonc
"mcp": {
  "servers": [                             // L5 Client，阶段 7
    {
      "id": "weather",
      "transport": "sse",                  // sse | websocket | streamable-http
      "url": "https://mcp.example.com/sse",
      "headers": {},                       // 注意：这里不允许写长期密钥，走 config 让用户填
      "toolPrefix": "weather_",
      "autoConnect": true
    }
  ],
  "serve": {                               // L5 Server，预留，宿主忽略
    "enabled": false,
    "entry": "mcp/server.js",
    "bind": "127.0.0.1",
    "port": 0
  }
},

"memory": {                                // L6，预留，阶段 7
  "provider": "memory/index.js",
  "capabilities": ["store", "retrieve", "summarize", "compact"],
  "priority": 100                          // 多个 provider 时的优先级，高者接管
}
```

### 2.10 `harness` —— L7 预留

**本阶段宿主完全忽略此字段**，但 schema 校验必须放行，插件作者现在就可以写。

```jsonc
"harness": {
  "runtime": "harness/index.js",           // 自定义 Agent 循环入口
  "steps": [                               // 可替换的步骤
    { "id": "pre-think",  "handler": "harness/pre_think.js",  "replace": "beforeModelCall" },
    { "id": "post-tool",  "handler": "harness/post_tool.js",  "replace": "afterToolCall"  }
  ],
  "toolsFromDefaultLoop": true             // 是否仍可使用默认工具表
}
```

宿主内部从第一天起就用「可替换步骤」实现默认 Agent 循环（见 [09](09-agent-and-tools.md)），这样 L7 放开时不需要重构。

---

## 3. 插件生命周期

```
        ┌──────────┐
        │  未安装   │
        └────┬─────┘
             │ 选 zip / 点分享链接
             ▼
     ┌───────────────┐
     │ 校验中 Validating│  schema + Zip Slip + 体积 + 重名
     └───────┬───────┘
             │ 通过
             ▼
     ┌───────────────┐
     │ 等待授权 Pending │  弹权限窗
     └───────┬───────┘
             │ 同意                │ 拒绝 → 回「未安装」，磁盘无残留
             ▼
     ┌───────────────┐
     │ 已安装 Installed │  解压 + 注册注册表
     └───────┬───────┘
             │ autoStart
             ▼
     ┌───────────────┐   onStart()
     │  运行中 Running │◀──────────────┐
     └───┬───────┬───┘                │
         │       │ 用户停用            │ 用户启用
         │       ▼                    │
         │  ┌──────────┐              │
         │  │ 已停用    │──────────────┘
         │  │ Disabled │
         │  └────┬─────┘
         │       │ 卸载
         │       ▼
         │  ┌──────────┐
         └─▶│ 已卸载    │  删沙箱目录 + 从注册表移除
            │ Uninstalled│
            └──────────┘

任意状态 ──崩溃──▶ 自动停用 + 通知用户（不影响宿主）
```

| 事件 | 触发时机 | 可选实现 |
|---|---|---|
| `onInstall` | 解压完成后、首次启动前 | ✅ |
| `onStart` | WebView 就绪、Bridge 建立后 | ✅ |
| `onStop` | 停用 / 卸载 / 宿主退出前 | ✅ |
| `onConfigChange` | 用户改了 `config` | ✅ |
| `onPermissionChange` | 权限被授予/撤销 | ✅ |

插件在 `index.js` 里通过 `tsukiro.lifecycle.on('start', fn)` 注册。

---

## 4. 版本与兼容策略

| 变更类型 | 处理 |
|---|---|
| 新增**可选** manifest 字段 | 不升 `manifestVersion`；旧宿主忽略 |
| 新增**必需**字段 | 升 `manifestVersion`；旧宿主明确拒绝并提示升级 |
| 删除字段 | 升 `manifestVersion`（major） |
| 原语新增 | 不升版本 |
| 原语行为变更 / 删除 | 升 `hostApi` major，旧插件按旧行为兼容运行一段过渡期 |
| 权限新增到插件 | 已有用户需重新确认（只弹新增项） |

**`minHostVersion` 不满足时**：拒绝安装，提示「该插件需要宿主 ≥ x.y.z，当前 a.b.c」。

---

## 5. 打包与发布（阶段 4）

```
作者本地 / CI
  ├─ 目录结构校验（scripts/pack_plugin.mjs）
  ├─ 打 zip → time-plugin-1.0.0.zip
  ├─ 计算 sha256
  ├─ Ed25519 签名（私钥在 GitHub Secrets）
  │    signature = sign(sha256 || id || version)
  └─ 上传 GitHub Release
  
注册表仓库（中心索引）
  └─ registry/index.json
       {
         "plugins": [{
           "id": "dev.tsukiro.time",
           "name": "时间插件",
           "author": "...",
           "latest": "1.0.0",
           "versions": [{
             "version": "1.0.0",
             "url": "https://github.com/example/time-plugin/releases/download/v1.0.0/time-plugin-1.0.0.zip",
             "mirrors": ["jsdelivr:...", "ghproxy:..."],
             "sha256": "...",
             "signature": "...",
             "pubkeyId": "...",
             "minHostVersion": "0.1.0",
             "permissions": ["sys.time"]
           }]
         }]
       }

客户端
  ├─ 拉索引（jsDelivr / Statically / 自建 CDN，测速选最快）
  ├─ 下载 zip（多镜像测速 + 故障转移）
  ├─ 校验 sha256 + Ed25519 签名
  └─ 走与本地安装相同的流程（校验 → 权限 → 解压 → 注册）
```

> **Demo 阶段跳过签名与镜像**，只做本地 zip 安装。但 `pack_plugin.mjs` 从一开始就按最终产物结构打包，避免后续返工。

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：完整 manifest schema、禁用项、生命周期、兼容策略、发布流程 |
