# 12 · Demo 实施计划

> 目标：验证「**能聊 + 插件能跑 + 一键导入能通**」。不做完整功能。
> 验收标准见 [11-roadmap § 3](11-roadmap.md)。

---

## 1. 范围

### 只做三件事

1. **能聊**：发消息 → 模型回复 → 存本地
2. **能装插件**：本地选 zip → 装好 → 生效
3. **插件能干活**：至少一个插件能操作手机或调 AI

### 明确不做

商城 · 注册表 · GitHub 分发 · 支付 · 卡密 · 点数 · MCP · 记忆系统 · 人设导入 · 美化包 · Harness 级插件 · 多模型切换 · 服务器 · 后端网关 · 签名校验

---

## 2. 技术栈

| 模块 | 选型 |
|---|---|
| 宿主 | Flutter + Dart |
| 本地存储 | SQLite（Drift） |
| 网络 | Dio（SSE 流式） |
| WebView | flutter_inappwebview |
| 模型 | OpenAI 兼容 API（用户填 Key） |
| 插件格式 | zip + `manifest.json` + `index.js` |

### 执行策略（重要）

**先做 `packages/plugin_core`（纯 Dart，无 Flutter 依赖），用 `dart test` 测透，再做 Flutter 宿主。**

原因：Demo 的技术风险集中在插件内核（manifest 校验、权限守门、Bridge 编解码、工具循环、Zip Slip），这些全是纯逻辑。先在桌面单测通过，再接 Flutter，可以把调试域从「Flutter + Android + WebView + JS + Dart 五层混合」压缩到「纯 Dart 一层」。

```
阶段 A1  plugin_core 纯 Dart + 单测        ← 当前
阶段 A2  Flutter 宿主：聊天 + SQLite
阶段 A3  Flutter 宿主：WebView + Bridge + 安装流程
阶段 A4  三个测试插件 + 端到端验收
```

---

## 3. 阶段 A1 —— plugin_core（当前任务）

### 3.1 包结构

```
packages/plugin_core/
├─ pubspec.yaml
├─ analysis_options.yaml
├─ lib/
│  ├─ plugin_core.dart                 # 公开 API 出口
│  └─ src/
│     ├─ manifest/
│     │  ├─ manifest.dart              # PluginManifest 数据类
│     │  ├─ parser.dart                # JSON → PluginManifest + 校验
│     │  └─ schema_check.dart          # manifestVersion / 必填字段 / semver
│     ├─ registry/
│     │  ├─ tool_registry.dart         # 工具表 + 冲突处理
│     │  ├─ slot_registry.dart         # UI 插槽表
│     │  ├─ page_registry.dart         # 独立页面表
│     │  └─ plugin_registry.dart       # 总注册表（聚合上面三个）
│     ├─ permission/
│     │  ├─ permission.dart            # 权限常量 + 风险级别表
│     │  └─ gatekeeper.dart            # ⛨ 唯一校验点
│     ├─ primitive/
│     │  ├─ primitive_router.dart      # method 名 → handler
│     │  └─ errors.dart                # 统一错误码与 TsukiroException
│     ├─ bridge/
│     │  ├─ envelope.dart              # req/res/evt/str/inv 消息模型
│     │  └─ codec.dart                 # 编解码 + 大小校验
│     ├─ sandbox/
│     │  └─ path_guard.dart            # 路径规范化 + 穿越检测
│     ├─ packaging/
│     │  ├─ package_inspector.dart     # zip 条目检查（Zip Slip / 类型 / 体积）
│     │  └─ installer.dart             # 安装流程状态机（校验→授权→解压→注册）
│     └─ audit/
│        ├─ audit_entry.dart           # 审计条目模型
│        └─ redactor.dart              # ⛨ 参数脱敏（写库前）
└─ test/
   ├─ manifest_parser_test.dart
   ├─ tool_registry_test.dart
   ├─ gatekeeper_test.dart
   ├─ bridge_codec_test.dart
   ├─ path_guard_test.dart
   ├─ package_inspector_test.dart
   └─ installer_flow_test.dart
```

### 3.2 逐模块要求与单测清单

#### `manifest/parser.dart`

| 要求 | 单测 |
|---|---|
| 解析合法 manifest | 三个测试插件的 manifest 都能解析 |
| 拒绝缺失必填字段 | 缺 `id` / `name` / `version` / `runtime.main` 各一例 |
| 校验 `id` 格式（反向域名） | 非法 id（含空格、大写、连续点）被拒 |
| 校验 `version` 为 semver | `1.0` / `v1.0.0` / `1.0.0-beta` 的接受与拒绝 |
| 校验 `permissions[]` 拼写 | 未知权限名被拒（防拼错静默失效） |
| 混合权限声明形式 | 字符串与对象两种写法都能解析为统一结构 |
| `parameters` 简写展开 | `{"limit":"number"}` → 完整 JSON Schema |
| `minHostVersion` 比较 | 宿主 0.1.0 对 `minHostVersion: 0.2.0` → 拒绝 |
| `harness` 字段放行 | 含 `harness` 的 manifest 校验通过但不产生任何注册项 |

#### `permission/gatekeeper.dart`

| 要求 | 单测 |
|---|---|
| 未声明权限 → 拒绝 | 插件调 manifest 未声明的权限 → `PERMISSION_DENIED` |
| 已声明未授权 → 拒绝 | |
| 已声明已授权 → 通过 | |
| 撤销后立即失败 | 授权 → 调用通过 → 撤销 → 再调用 → `PERMISSION_REVOKED` |
| `denied` 级权限 → 安装即失败 | |
| `confirm` 级 → 返回 `CONFIRM_REQUIRED` | 不直接执行 |
| 声明即上限 | 插件 A 授权的权限不能给插件 B 用 |
| 热路径用内存缓存 | 连续 10000 次 check 不查库 |

#### `registry/tool_registry.dart`

| 要求 | 单测 |
|---|---|
| 注册 / 注销 | |
| 重名冲突加前缀，不覆盖 | 两个 get_time → `get_time` + `<prefix>__get_time` |
| 卸载插件后其工具消失 | |
| 按权限过滤 | 权限被撤销 → 工具不可见 |
| 按 Skill 白名单过滤 | |
| 导出 OpenAI 格式 | 字段名映射正确 |

#### `bridge/codec.dart`

| 要求 | 单测 |
|---|---|
| 五种 kind 编解码往返一致 | req/res/err/evt/str |
| 超过 1MB 拒绝 | |
| 未知 `v` 拒绝 | |
| `id` 配对 | 并发 100 个请求能正确配对 |
| 流式 seq 递增校验 | |
| 握手前消息丢弃 | |

#### `sandbox/path_guard.dart`

| 要求 | 单测 |
|---|---|
| 正常相对路径解析 | `notes/a.txt` → `<root>/notes/a.txt` |
| `..` 穿越拒绝 | `../../etc/passwd` → `SANDBOX_VIOLATION` |
| 绝对路径拒绝 | `/etc/passwd`、`C:\Windows\...` |
| 符号链接逃逸拒绝 | 沙箱内 symlink 指向外部 → 拒绝 |
| 大小写与分隔符规范化（Windows） | `..\..\x` 也被拦 |
| URL 编码穿越 | `%2e%2e%2f` 解码后拦截 |

#### `packaging/package_inspector.dart`

| 要求 | 单测 |
|---|---|
| 合法包通过 | 三个测试插件的 zip |
| Zip Slip 拒绝 | 含 `../evil.txt` 条目 |
| 符号链接条目拒绝 | |
| 原生二进制拒绝 | `.so` / `.dll` / `.node` |
| 单文件超限拒绝 | > 10MB |
| 总体积超限拒绝 | > 50MB |
| zip bomb 拒绝 | 压缩比异常 |
| 定位 manifest（根 / 单层目录） | 两种布局都能找到；两层或多份则拒绝 |
| handler 文件存在性校验 | manifest 声明 `handlers/x.js` 但包内没有 → 拒绝 |

#### `packaging/installer.dart`

| 要求 | 单测 |
|---|---|
| 状态机：未安装→校验中→等待授权→已安装 | |
| 授权被拒 → 磁盘无残留 | 校验磁盘状态 |
| 校验失败 → 磁盘无残留 | |
| 重复 id → 返回「已存在」而非静默覆盖 | |
| 原子性：先解压到临时目录再 rename | 中断后无半成品目录 |
| 安装成功 → 注册表出现该插件的工具/插槽/页面 | |

#### `audit/redactor.dart`

| 要求 | 单测 |
|---|---|
| `fs.read` 只留路径不留内容 | |
| `model.chat` 只留条数与 token | |
| `sms.send` 手机号打码、正文只留长度 | |
| `crypto.*` 绝不记录密钥 | |
| `sys.clipboard.*` 只记长度 | |

### 3.3 完成定义（DoD）

- [ ] `dart analyze` 零 warning
- [ ] `dart test` 全绿
- [ ] 上表所有单测项有对应用例
- [ ] 三个测试插件的 manifest 能被真实解析并注册
- [ ] 恶意插件样本（Zip Slip / 二进制 / 超限）被正确拒绝
- [ ] 公开 API 有 dartdoc 注释

---

## 4. 阶段 A2 —— Flutter 宿主（聊天）

| 任务 | 要点 |
|---|---|
| 项目初始化 | `flutter create --platforms=android` |
| Drift schema | 按 [10-data-model](10-data-model.md) 建 `sessions` / `messages` / `settings` |
| 聊天页 | 消息列表（`ListView.builder` 反向）+ 输入框 |
| 流式渲染 | Riverpod `StreamProvider` + 局部刷新（不整页 setState） |
| Dio + SSE | 跨 chunk 行缓冲、`[DONE]`、`tool_calls` 参数分片拼接 |
| 高级设置 | 隐藏入口，填 Key / Base URL / 模型名 |
| 默认人设 | 首次启动插入 `builtin.default` |

**验收**：发消息 → 逐字出现 → 杀进程重启 → 消息还在。

---

## 5. 阶段 A3 —— WebView + Bridge + 安装

| 任务 | 要点 |
|---|---|
| 插件管理页 | 列表、启用/停用、卸载、权限页 |
| 安装流程 | 文件选择器 → `PackageInspector` → 权限弹窗 → `Installer` |
| 权限弹窗 | 原生组件（非 WebView），列出权限 + 理由 + `confirm` 级高亮 |
| WebView 容器 | 每插件一实例，独立数据目录，CSP 注入 |
| Bridge 绑定 | `addJavaScriptHandler` ↔ plugin_core 的 Codec |
| 原语实现 | `sys.time` / `ui.toast` / `fs.read` / `model.chat` 四个 |
| 未实现原语 | 统一返回 `UNSUPPORTED` |
| 插槽渲染 | `chat.toolbar` / `settings.sections` / `chat.message.menu` |
| 独立页面 | 容器 + 原生标题栏 |
| 工具调用循环 | 按 [09-agent-and-tools](09-agent-and-tools.md)，`maxSteps = 3` |
| 崩溃处理 | 捕获 JS 异常 → 停用 + 提示 |

**验收**：装完插件 → 插槽立即出现控件（无需重启）。

---

## 6. 阶段 A4 —— 三个测试插件

每个插件都放在 `plugins/<name>/`，用 `scripts/pack_plugin.mjs` 打成 zip。

### 6.1 时间插件 `time-plugin`

**验证**：工具调用链路（模型 → 工具 → 插件 → 原语 → 回传）

```jsonc
// manifest.json
{
  "manifestVersion": 1,
  "id": "dev.tsukiro.time",
  "name": "时间插件",
  "version": "1.0.0",
  "description": "让 AI 知道现在几点",
  "runtime": { "main": "index.js" },
  "permissions": [
    { "name": "sys.time", "reason": "读取系统时间以回答时间问题" }
  ],
  "provides": {
    "tools": [{
      "name": "get_time",
      "description": "获取当前时间。当用户询问现在几点、今天几号、距离某时刻多久时调用。",
      "parameters": {
        "type": "object",
        "properties": {
          "timezone": { "type": "string", "description": "IANA 时区，如 Asia/Shanghai，默认本机" },
          "format": { "type": "string", "enum": ["iso", "human"], "default": "human" }
        },
        "required": []
      },
      "handler": "handlers/get_time.js",
      "permissions": ["sys.time"]
    }]
  }
}
```

```js
// handlers/get_time.js
export default async function get_time(args) {
  const t = await tsukiro.sys.time({ tz: args.timezone });
  return {
    time: t.iso,
    human: t.human,
    timezone: t.tz,
    hint: '请用自然语言把时间告诉用户，不要输出原始 JSON'
  };
}
```

**测试用例**：

| 输入 | 期望 |
|---|---|
| 「现在几点」 | 模型调 `get_time` → 返回真实时间 |
| 「东京现在几点」 | 模型传 `timezone: "Asia/Tokyo"` → 时区正确 |
| 撤销 `sys.time` 后问时间 | 工具返回 `PERMISSION_DENIED`，模型在回复中说明需要权限 |

### 6.2 翻译按钮 `translate-button`

**验证**：UI 插槽 + 插件调 AI（且插件拿不到 Key）

```jsonc
// manifest.json（节选）
{
  "id": "dev.tsukiro.translate",
  "name": "翻译按钮",
  "version": "1.0.0",
  "permissions": [
    { "name": "model.chat", "reason": "调用模型进行翻译" },
    { "name": "ui", "reason": "显示翻译结果提示" }
  ],
  "config": {
    "schema": {
      "type": "object",
      "properties": {
        "target": { "type": "string", "title": "目标语言", "default": "中文",
                    "enum": ["中文", "English", "日本語", "한국어"] }
      }
    },
    "section": { "slot": "settings.sections", "title": "翻译插件" }
  },
  "provides": {
    "ui": [
      {
        "slot": "chat.toolbar",
        "id": "translate",
        "type": "button",
        "label": "翻译",
        "icon": "lucide:languages",
        "tooltip": "翻译上一条消息",
        "order": 10,
        "when": { "hasMessages": true },
        "onClick": { "event": "translate.clicked" },
        "permissions": ["model.chat"]
      }
    ]
  }
}
```

```js
// index.js
tsukiro.event.on('ui.click', async (e) => {
  if (e.id !== 'translate') return;

  const last = await tsukiro.chat.lastMessage({ role: 'assistant' });  // 宿主提供
  if (!last) return tsukiro.ui.toast({ text: '还没有可翻译的消息' });

  const target = (await tsukiro.config.get('target')) ?? '中文';
  tsukiro.ui.toast({ text: '翻译中…' });

  const res = await tsukiro.model.chat({
    messages: [
      { role: 'system', content: '你是翻译引擎。只输出译文，不要解释，不要引号。' },
      { role: 'user',   content: `翻译成${target}：\n${last.text}` }
    ],
    stream: false
  });

  await tsukiro.ui.dialog({
    title: `翻译（${target}）`,
    content: res.text,
    buttons: [{ id: 'copy', label: '复制' }, { id: 'close', label: '关闭' }]
  });
});
```

**测试用例**：

| 场景 | 期望 |
|---|---|
| 聊天页工具栏出现「翻译」 | 装完立即出现，无需重启 |
| 无消息时 | 按钮隐藏（`when.hasMessages`） |
| 点击 | 弹「翻译中」→ 弹出译文 |
| 改设置为 English | 译文变英文 |
| 插件能否拿到 Key | **不能** —— 参数 schema 里没有 Key 字段，插件代码无从构造 |

### 6.3 小游戏窗口 `mini-game`

**验证**：独立页面 + WebView 内跑 JS + Bridge 调 AI

```jsonc
// manifest.json（节选）
{
  "id": "dev.tsukiro.guess-number",
  "name": "猜数字",
  "version": "1.0.0",
  "permissions": [
    { "name": "model.chat", "reason": "让 AI 充当游戏裁判" },
    { "name": "ui", "reason": "显示提示" }
  ],
  "provides": {
    "ui": [{
      "slot": "chat.toolbar", "id": "open-game", "type": "button",
      "label": "猜数字", "icon": "lucide:gamepad-2", "order": 20,
      "onClick": { "event": "game.open" }
    }],
    "pages": [{
      "id": "game", "title": "猜数字", "entry": "pages/game.html",
      "presentation": "window", "size": { "width": 420, "height": 560 },
      "permissions": ["model.chat", "ui"]
    }]
  }
}
```

```js
// index.js
tsukiro.event.on('ui.click', async (e) => {
  if (e.id === 'open-game') await tsukiro.ui.navigate({ pageId: 'game' });
});
```

```html
<!-- pages/game.html -->
<!doctype html>
<html><head><meta charset="utf-8"><title>猜数字</title>
<style>
  body { font-family: system-ui; padding: 16px; }
  #log { height: 300px; overflow-y: auto; border: 1px solid #ddd;
         border-radius: 8px; padding: 8px; font-size: 14px; }
  input, button { font-size: 15px; padding: 6px 10px; }
</style></head>
<body>
  <h3>猜数字（1–100）</h3>
  <div id="log"></div>
  <p><input id="q" placeholder="输入你的猜测" /><button id="send">发送</button></p>

<script type="module">
  const log = document.getElementById('log');
  const say = (who, text) => {
    log.innerHTML += `<p><b>${who}:</b> ${text}</p>`;
    log.scrollTop = log.scrollHeight;
  };

  say('系统', 'AI 已经想好了一个 1–100 的数字，开始猜吧。');

  document.getElementById('send').onclick = async () => {
    const q = document.getElementById('q').value.trim();
    if (!q) return;
    document.getElementById('q').value = '';
    say('你', q);

    // 关键：这里没有 fetch，也拿不到任何 API Key
    // 只能通过 Bridge 走宿主原语
    const res = await tsukiro.model.chat({
      messages: [
        { role: 'system', content:
            '你是猜数字游戏的裁判。心里想一个 1-100 的整数（固定用 42）。' +
            '玩家猜数时只回答「大了」「小了」或「猜中了」。不要多说。' },
        { role: 'user', content: q }
      ],
      stream: false
    });
    say('AI', res.text);
  };
</script>
</body></html>
```

**测试用例**：

| 场景 | 期望 |
|---|---|
| 点工具栏「猜数字」 | 打开独立窗口，标题为「猜数字 · 猜数字」带插件图标 |
| 窗口内输入 50 | 显示 AI 回复「小了」 |
| 插件页面尝试 `fetch(...)` | 被 CSP 拦死（证明网络必须走原语） |
| 页面里 `tsukiro.model.chat` | 正常工作 |

---

## 7. 端到端验收脚本

```
【准备】
  1. 装 App（Android 真机或模拟器）
  2. 高级设置填 OpenAI 兼容 Key + Base URL + 模型名
  3. 确认能聊天

【流程 1 · 聊天 + 持久化】
  4. 发「你好」→ 逐字出现回复
  5. 杀进程 → 重开 → 消息还在                    ✅/❌

【流程 2 · 时间插件】
  6. 安装 time-plugin.zip → 弹权限（sys.time）→ 同意
  7. 发「现在几点」→ 观察是否调用了 get_time
  8. 回复中的时间与实际时间一致                    ✅/❌
  9. 设置→插件→时间插件→撤销 sys.time
 10. 再问「现在几点」→ 回复说明需要权限，不崩溃      ✅/❌

【流程 3 · 翻译按钮】
 11. 安装 translate-button.zip → 弹权限（model.chat, ui）→ 同意
 12. 聊天页工具栏出现「翻译」按钮（无需重启）       ✅/❌
 13. 点按钮 → 弹出译文                            ✅/❌
 14. 设置里把目标语言改成 English → 再点 → 英文译文  ✅/❌

【流程 4 · 小游戏】
 15. 安装 mini-game.zip → 同意
 16. 点工具栏「猜数字」→ 打开独立窗口              ✅/❌
 17. 窗口内输入 50 → 显示 AI 回复                 ✅/❌

【安全验证】
 18. 构造含 ../evil.txt 的 zip → 安装被拒           ✅/❌
 19. 插件内调 fs.read({path:'../../x'}) → SANDBOX_VIOLATION  ✅/❌
 20. 插件内调 media.listPhotos → UNSUPPORTED，不崩溃 ✅/❌
 21. 让插件抛未捕获异常 → 宿主正常，插件被停用       ✅/❌
```

**21 项全过 = Demo 完成。**

---

## 8. 任务拆解与顺序

| # | 任务 | 依赖 | 可并行 |
|---|---|---|---|
| 1 | `plugin_core` 骨架 + pubspec | — | — |
| 2 | `manifest` 解析与校验 + 单测 | 1 | ✅ |
| 3 | `permission` + Gatekeeper + 单测 | 1 | ✅ |
| 4 | `registry`（工具/插槽/页面）+ 单测 | 2 | ✅ |
| 5 | `sandbox/path_guard` + 单测 | 1 | ✅ |
| 6 | `packaging`（inspector + installer）+ 单测 | 2, 3, 5 | ✅ |
| 7 | `bridge/codec` + 单测 | 4 | ✅ |
| 8 | `audit` + redactor + 单测 | 1 | ✅ |
| 9 | 三个测试插件源码 + `pack_plugin.mjs` | 2 | ✅ |
| 10 | Flutter 项目初始化 + Drift schema | — | 与 1–9 并行 |
| 11 | 聊天页 + 流式 + 高级设置 | 10 | — |
| 12 | WebView 容器 + Bridge 绑定 | 7, 11 | — |
| 13 | 四个原语实现 | 3, 12 | — |
| 14 | 安装流程 UI + 权限弹窗 | 6, 10 | — |
| 15 | 插槽渲染 | 4, 11 | — |
| 16 | 独立页面容器 | 12 | — |
| 17 | 工具调用循环 | 4, 13 | — |
| 18 | 端到端验收（21 项） | 全部 | — |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：四阶段拆分、plugin_core 完整模块与单测清单、三个插件的完整代码、21 项验收脚本 |
