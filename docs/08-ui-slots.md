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

---

## 2. 宿主预埋插槽清单

| 插槽 | 位置 | 典型用途 | 版本 |
|---|---|---|---|
| `chat.header` | 聊天页顶部（标题栏右侧） | 状态指示、快速开关 | Demo |
| `chat.toolbar` | 聊天页工具栏 | 翻译、总结、朗读 | **Demo** |
| `chat.input.actions` | 输入框右侧按钮区 | 附件、语音、快捷提示 | Demo |
| `chat.message.menu` | 长按消息弹出的菜单 | 复制、重新生成、翻译本条 | Demo |
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

## 6. 渲染与刷新时机

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
```

---

## 7. 安全约束汇总

| 约束 | 原因 |
|---|---|
| 插槽控件必须由宿主渲染 | 视觉一致性 + 不可伪装 |
| `asset:` 图标只接受位图，不接受内联 SVG | 防 XSS |
| `tokens`（主题）只接受值，不接受 CSS 片段 | 防注入任意样式 |
| 独立页面标题栏为原生层 | 插件不能伪装成宿主页面 |
| 覆盖层必须有可见边界 | 防隐形点击劫持 |
| `when` 无表达式语言 | 渲染路径不执行插件逻辑 |
| 页面 CSP `connect-src 'none'` | 强制网络走原语白名单 |
| 同时最多 2 个覆盖层 | 防遮挡宿主 UI 到不可用 |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：三种形态、9 个插槽、完整控件 schema、容器规范、安全约束 |
