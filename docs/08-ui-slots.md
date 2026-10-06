# 08 · UI 扩展点

> **核心决策**：宿主内的控件由**宿主渲染**（插件只给语义），只有独立页面和覆盖层才允许插件自带 HTML。
> 理由：视觉一致性 + 插件不可伪装宿主 UI + 无 WebView 开销。

---

## 1. 三种形态

| 形态 | 插件提供 | 宿主提供 | 视觉自由度 | 状态 |
|---|---|---|---|---|
| **声明式插槽** | JSON 描述（`provides.ui`） | 原生渲染，统一风格 | 低（仅图标/文案/顺序） | **Demo** |
| **独立页面** | 完整 HTML/JS | WebView 容器 + 标题栏 | 高 | **Demo** |
| **覆盖层** | 完整 HTML/JS | 透明浮层容器 | 高 | 阶段 5 |
| **Interactive Web Surface** | HTML/CSS/JS、富文本、拖拽、输入、动画 | 独立 WebView + CSP + Bridge | 高 | Surface 阶段 |
| **Trusted Flame Surface** | manifest 选择 `gameType`，不上传 Dart | 宿主 FlameGame/GameWidget factory | 高 | Flame 阶段 |

---

## 1.1 Surface 与 Flame 边界

L1 插槽控件仍由宿主渲染。需要拖拽、富文本、自定义输入或动画时，使用独立的 Interactive Web Surface；它拥有自己的 WebView/DOM，但只能通过 Bridge 调用宿主能力。Flame 使用 Trusted Surface：manifest 只选择宿主注册的 `gameType`，普通插件不得上传或执行 Dart/Flutter 代码。

---

## 2. 宿主预埋插槽清单

| 插槽 | 位置 | 典型用途 | 版本 |
|---|---|---|---|
| `chat.header` | 聊天页顶部（标题栏右侧） | 状态指示、快速开关 | Demo |
| `chat.toolbar` | 聊天页工具栏 | 翻译、总结、朗读 | **Demo** |
| `chat.input.actions` | 输入框右侧按钮区 | 附件、语音、快捷提示 | Demo |
| `chat.message.menu` | 长按消息弹出的菜单 | 复制、重新生成、翻译本条 | Demo |
| `chat.message.after` | **消息气泡下方**（富内容区） | 状态条、图表、交互控件 | **Demo** |
| `home.cards` | 首页卡片区 | 快捷入口、状态卡 | 阶段 5 |
| `settings.sections` | 设置页分区 | 插件自己的设置项 | Demo |
| `profile.actions` | 角色页操作区 | 导出、分享、编辑扩展 | 阶段 5 |
| `global.fab` | 全局悬浮按钮 | 快速唤起 | 阶段 5 |
| `plugin.detail` | 插件详情页 | 插件自定义面板 | 阶段 5 |

### 2.1 插槽的稳定性承诺

- 插槽名一旦发布**不重命名**。需要新布局时新增插槽，旧插槽保留。
- 每个插槽声明**容量建议**（如 `chat.toolbar` 建议 ≤ 4 个控件）。超出不报错，但宿主按 `order` 后截断并聚合进「⋯」菜单。
- 插槽不存在于当前版本时，宿主**静默忽略**该声明（不算安装失败），并在插件详情页提示「该插件使用了本版本不支持的插槽」。

---

## 3. 声明式控件

### 3.1 通用字段

```jsonc
{
  "slot": "chat.toolbar",          // 必需
  "id": "translate",               // 必需，插件内唯一
  "type": "button",                // 必需
  "label": "翻译",                  // 必需（divider 除外）
  "icon": "lucide:languages",      // 可选
  "tooltip": "把上一条消息翻译成目标语言",
  "order": 100,                    // 可选，默认 100，升序
  "when": { "hasMessages": true }, // 可选，显示条件
  "permissions": ["model.chat"],   // 可选，权限被撤销时自动隐藏
  "onClick": { "event": "translate.clicked" }   // 可选，默认发 ui.click 事件
}
```

### 3.2 控件类型

#### `button`

```jsonc
{ "slot":"chat.toolbar", "id":"translate", "type":"button", "label":"翻译",
  "icon":"lucide:languages", "style":"default", "onClick":{"event":"translate.clicked"} }
```

`style`：`default` | `primary` | `danger`（danger 会显示为警示色，仍需宿主确认才执行破坏性操作）。

#### `toggle`

```jsonc
{ "slot":"chat.toolbar", "id":"auto-translate", "type":"toggle",
  "label":"自动翻译", "icon":"lucide:wand-2",
  "config": { "key":"autoTranslate" },     // 双向绑定 config 的布尔字段
  "onChange": { "event":"autoTranslate.changed" } }
```

#### `menu-item`

```jsonc
{ "slot":"chat.message.menu", "id":"translate-msg", "type":"menu-item",
  "label":"翻译这条消息", "icon":"lucide:languages",
  "when": { "hasSelection": true },
  "onClick": { "event":"message.translate.clicked" } }
```

> 宿主在事件载荷中自动附带 `messageId`（来自触发时的选中消息），插件不需要自己去找：
> `{ slot, id, messageId, messageText }`。

#### `divider`

```jsonc
{ "slot":"chat.toolbar", "id":"sep1", "type":"divider", "order":99 }
```

#### `section`（`settings.sections` 专用）

```jsonc
{
  "slot": "settings.sections",
  "id": "main", "type": "section",
  "label": "翻译插件",
  "icon": "lucide:languages",
  "children": [                            // 宿主渲染的配置表单
    { "type":"select", "key":"target", "label":"目标语言",
      "options":["中文","English","日本語"], "default":"中文" },
    { "type":"input",  "key":"customPrompt", "label":"自定义提示词",
      "placeholder":"留空使用默认", "multiline": true },
    { "type":"toggle", "key":"autoTranslate", "label":"发送时自动翻译" },
    { "type":"button", "label":"测试连接", "onClick":{"event":"test.clicked"} }
  ]
}
```

#### 表单控件（仅在 `section.children` 内合法）

| `type` | 字段 | 说明 |
|---|---|---|
| `input` | `key` `label` `placeholder` `multiline` `maxLength` | 文本输入 |
| `number` | `key` `label` `min` `max` `step` | 数字输入 |
| `select` | `key` `label` `options[]` | 下拉选择 |
| `toggle` | `key` `label` | 开关 |
| `slider` | `key` `label` `min` `max` `step` | 滑块 |
| `text` | `label` | 只读说明文字（不可绑定 key） |
| `button` | `label` `onClick` | 触发事件 |
| `divider` | — | 分隔线 |

**表单值自动持久化**到插件的 `config`，并触发 `config.change` 事件。插件不需要自己存。

### 3.3 `when` 求值

宿主在渲染前求值，全部条件为 AND。

| 条件 | 类型 | 语义 |
|---|---|---|
| `hasMessages` | bool | 当前会话有消息 |
| `hasSelection` | bool | 有选中的消息 |
| `sessionActive` | bool | 在会话内（非首页） |
| `isStreaming` | bool | 模型正在输出 |
| `hasModel` | bool | 已配置可用模型 |
| `config.<key>` | any | 配置项等于该值 |
| `permission.<name>` | bool | 是否已授予该权限 |

```jsonc
"when": { "hasMessages": true, "isStreaming": false, "config.target": "中文" }
```

> **不提供表达式语言**。只有键值比较，避免在渲染路径上执行插件提供的逻辑。

### 3.4 图标

| 写法 | 说明 |
|---|---|
| `lucide:<name>` | 内置图标集（Lucide），宿主保证存在；未知名字降级为 `lucide:puzzle` |
| `asset:<path>` | 插件包内图片，PNG/SVG，建议 24×24，≤ 64KB |

**插件不能用 `asset:` 提供可点击的任意内容** —— 图标会被宿主当作图片渲染，不接受内联 SVG（防 XSS）。

---

## 4. 独立页面

### 4.1 声明

```jsonc
"pages": [{
  "id": "game",
  "title": "猜数字",
  "entry": "pages/game.html",
  "presentation": "window",
  "icon": "lucide:gamepad-2",
  "size": { "width": 480, "height": 640 },
  "resizable": true,
  "bridge": true,
  "permissions": ["model.chat", "ui.toast"],
  "openFrom": ["chat.toolbar"]
}]
```

`presentation`：

| 值 | 表现 |
|---|---|
| `page` | 全屏推入导航栈（有返回按钮） |
| `window` | 可拖动/缩放的浮窗（桌面端；移动端降级为全屏） |
| `sheet` | 从底部弹出的半屏面板 |
| `fullscreen` | 全屏且隐藏宿主导航（游戏用） |

### 4.2 容器规范

```
┌─────────────────────────────────────────┐
│  🧩 时间插件 · 猜数字            ✕      │  ← 宿主原生标题栏（WebView 之外）
├─────────────────────────────────────────┤
│                                         │
│        插件自带 HTML 渲染区              │
│        （唯一允许自定义外观的区域）        │
│                                         │
└─────────────────────────────────────────┘
```

**硬性要求**：

1. 标题栏显示 `插件名 · 页面标题` + 插件图标。插件**无法**修改或隐藏它。
2. 标题栏是原生层，插件 CSS 无法触及。
3. 页面顶部预留安全区内边距（刘海屏）。

### 4.3 页面内的 Bridge

插件页面加载时，宿主注入 `tsukiro` 对象（与 `index.js` 同一个）。页面里可以直接：

```html
<script type="module">
  document.getElementById('ask').onclick = async () => {
    const q = document.getElementById('q').value;
    const res = await tsukiro.model.chat({
      messages: [
        { role:'system', content:'你是猜数字游戏的裁判，只回答「大了」「小了」或「猜中了」。' },
        { role:'user',   content:q }
      ]
    });
    document.getElementById('log').textContent += res.text + '\n';
    tsukiro.ui.toast({ text: '已询问 AI' });
  };
</script>
```

**注意**：页面里的 `fetch` 依然被 CSP 拦死，只能走 `tsukiro.*`。

---

## 5. 覆盖层（阶段 5）

```jsonc
"overlays": [{
  "id": "ball",
  "entry": "pages/ball.html",
  "anchor": "bottom-right",
  "offset": { "x": -16, "y": -96 },
  "size": { "width": 56, "height": 56 },
  "draggable": true,
  "clickThrough": false,
  "alwaysOnTop": true,
  "permissions": ["ui.overlay"]
}]
```

| 字段 | 说明 |
|---|---|
| `anchor` | 初次定位；`draggable` 为 true 时用户拖动后位置持久化 |
| `clickThrough` | true 时除插件元素外的区域穿透到宿主（字幕层用） |
| `alwaysOnTop` | 是否覆盖在模态框之上（默认 false） |

**限制**：同时最多 **2 个**覆盖层。超出时新的覆盖层创建失败并返回 `RATE_LIMITED`。

**可见性要求**：覆盖层必须有可见边界（宿主给 1px 描边 + 阴影），不能做成全透明隐形层。

---

## 7. 消息富内容（`chat.message.after`）

AI 气泡正下方的一块区域，插件可以在那里渲染富内容（SVG 图表、按钮、交互控件）。
这是「AI 说的话」和「围绕这句话的可操作内容」之间的连接点，也是两个示例验证里的关键。

### 7.1 数据从哪来

两条路径，都走同一条渲染管线：

```
① 工具返回时
   插件工具 handler 返回 { text, richContent: {...} }
   └─ 宿主把 richContent 挂到本轮 assistant 消息上（meta.<pluginId>.richContent）
   └─ 该消息渲染时，chat.message.after 插槽被激活

② 插件主动追加时
   插件调 message.update({ messageId, patch: { richContent: {...} } })
   └─ 同样挂到消息上
```

**`richContent` 是插件的私有数据**，宿主不理解它的结构，只负责：
1. 存到 `message.meta.<pluginId>.richContent`
2. 在渲染该消息时，把对应插件的 `chat.message.after` 组件挂载起来
3. 通过 Bridge 把 `richContent` 交给该插件自己的页面/组件

### 7.2 声明

```jsonc
"ui": [
  {
    "slot": "chat.message.after",
    "id": "status-card",
    "type": "webview",
    "entry": "components/status.html",
    "label": "状态卡",
    "height": { "mode": "auto", "max": 240 },
    "when": { "hasRichContent": true },
    "permissions": ["ui"]
  }
]
```

| 字段 | 说明 |
|---|---|
| `type: "webview"` | 这是插槽控件里**唯一**允许插件自带 HTML 的类型（其余由宿主渲染） |
| `height.mode` | `auto`（由插件上报高度）/ `fixed` / `max` |
| `when.hasRichContent` | 该消息上有没有本插件的 `richContent`；没有就不渲染，避免空白占位 |

### 7.3 为什么这里破例允许 WebView

`chat.message.after` 的用途就是「每个插件长得不一样」—— 状态条、雷达图、任务清单，
用声明式控件描述不了。所以破例，但用三条约束兜住：

1. **必须挂在具体消息上**。没有 `richContent` 就不渲染，不会出现悬浮在整个聊天页上的插件 UI。
2. **高度由宿主控制上限**（`height.max`）。默认 240px，防止插件用一块超长内容把聊天流冲垮。
3. **必须可折叠 + 带来源标记**。宿主在区块左上角显示插件图标与名称，用户可折叠。
   这满足了「插件 UI 必须可辨识」的硬约束。

### 7.4 交互回流

富内容里的交互（点按钮、拖滑块）通过 Bridge 回插件，插件再决定下一步：

```js
// components/status.html
document.getElementById('boost').onclick = async () => {
  const r = await tsukiro.tool.call({ name: 'adjust_mood', args: { delta: 5 } });
  await tsukiro.message.update({
    messageId: tsukiro.context.messageId,
    patch: { richContent: r.richContent },   // 重新渲染同一块
  });
};
```

也可选择「发一条新消息」：`message.send({ content })`。

---

## 8. 三层 UI 扩展点

补充文档给出的 L1 / L2 / L3 三层。**manifest 字段一次留全，宿主现在只解析 L1。**

### 8.1 L1 样式级（现在做）

宿主把所有视觉变量抽成**设计令牌（design tokens）**，美化包只覆盖令牌值。

| 令牌组 | 示例 |
|---|---|
| `color.*` | `color.primary` `color.userBubble` `color.assistantBubble` |
| `font.*` | `font.family` `font.size.body` `font.weight.bold` |
| `radius.*` | `radius.bubble` `radius.card` `radius.button` |
| `spacing.*` | `spacing.page` `spacing.messageGap` |
| `shadow.*` | `shadow.card` `shadow.fab` |
| `animation.*` | `animation.duration.fast` `animation.easing.standard` |
| `icon.*` | `icon.send` `icon.regenerate` |

```jsonc
{
  "provides": {
    "theme": {
      "id": "sakura",
      "name": "樱花",
      "tokens": {
        "color.primary": "#FF6B9D",
        "font.size.body": 16,
        "radius.bubble": 18
      }
    }
  }
}
```

**为什么令牌必须是白名单**：令牌是「值」不是「CSS」。宿主拿到 `#FF6B9D` 或 `16` 后
自己拼装样式，因此 `url(...)` / `expression(...)` / `@import` 这类注入无从下手。
未知令牌名直接拒绝（拼错要报错，不能静默忽略 —— 与权限名同一原则）。

### 8.2 L2 布局级（预留，不解析）

```jsonc
"layout": {
  "mode": "compact",              // 预设布局模式
  "slots": {                      // 插槽重排 / 显隐 / 顺序
    "chat.toolbar": { "order": ["translate", "summarize"], "hidden": ["builtin.copy"] }
  },
  "stack": [], "grid": [], "absolute": [], "scroll": [], "tabs": []
}
```

**为什么现在不解析**：布局是最容易让宿主 UI 崩掉的一层 —— 一个插件把 `chat.toolbar`
顺序改乱，用户体验就毁了。等 L1 跑稳、有了真实美化包作者，再按实际需求放开子集。

### 8.3 L3 替换级（预留，不解析）

```jsonc
"replaces": { "ui.components": ["messageBubble"], "ui.pages": ["chat.main"] },
"data": { "messages": true, "contacts": true, "session": true, "model": true }
```

**为什么现在不解析**：整页接管意味着插件可以实现出一个和宿主一模一样的界面 ——
这与「插件不可伪装宿主 UI」直接冲突。真要放开，需要先设计一套「接管时必须显示来源水印」
的机制。能力上不缺：独立页面（`provides.pages`）已经能给出完全自定义的界面。

---

## 9. 渲染与刷新时机

```
插件安装完成
   └─▶ SlotRegistry.register() → 通知 UI 层（ChangeNotifier / Riverpod）
                                    └─▶ 相关插槽立即重绘（无需重启）

插件停用
   └─▶ SlotRegistry.unregister(pluginId) → 插槽控件消失

权限被撤销
   └─▶ 遍历该插件控件，permissions 命中的 → 隐藏

插件崩溃
   └─▶ 控件置灰 + 点击提示「插件已停止，是否重启？」

配置变更
   └─▶ 只重绘受影响的控件（按 config key 订阅）

插件注入上下文失效（context.* 的 ttl 到期 / 插件停用）
   └─▶ 宿主清空该插件的全部注入，并重绘相关消息的富内容区
```

---

## 10. 安全约束汇总

| 约束 | 原因 |
|---|---|
| 插槽控件必须由宿主渲染 | 视觉一致性 + 不可伪装 |
| `chat.message.after` 是唯一允许插件自带 HTML 的插槽 | 富内容天然需要各自的外观，用高度上限 + 来源标记 + 可折叠兜住 |
| `asset:` 图标只接受位图，不接受内联 SVG | 防 XSS |
| `tokens`（主题）只接受**值**，不接受 CSS 片段；未知令牌名拒绝 | 防注入任意样式 |
| 独立页面标题栏为原生层 | 插件不能伪装成宿主页面 |
| 覆盖层必须有可见边界 | 防隐形点击劫持 |
| `when` 无表达式语言 | 渲染路径不执行插件逻辑 |
| 页面 CSP `connect-src 'none'` | 强制网络走原语白名单 |
| 同时最多 2 个覆盖层 | 防遮挡宿主 UI 到不可用 |
| L2 布局 / L3 接管本阶段**只解析不执行** | 这两层最容易让宿主 UI 崩掉或让插件伪装宿主，需要先有 L1 的真实使用反馈 |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：三种形态、9 个插槽、完整控件 schema、容器规范、安全约束 |
| 2026-02 | 补 `chat.message.after` 富内容插槽；补 L1 设计令牌 / L2 布局 / L3 接管三层扩展点 |

