# 16 · 扩展性设计

> **本文回答一个问题**：怎么保证「加一个新原语 / 新钩子 / 新插槽」时，**不需要改宿主核心的任何一行**？

这不是靠"多写点代码预留"，而是靠把手上的**变化点做成数据**。本文说明三个变化轴各怎么做，
以及必须避免的反面模式。

---

## 1. 三个变化轴

插件框架一共有三个地方会长新东西：

| 轴 | 会长出什么 | 如果做错了会怎样 |
|---|---|---|
| **能力轴** | 新原语（`context.*`、`schedule.*`、未来的 `foo.bar`） | 每加一个原语都要改宿主的 `switch`，宿主变成"功能写死的列表" |
| **时机轴** | 新钩子（`onBeforeModel`、未来的 `onMemoryRetrieve`） | 每加一个时机都要改 Agent 循环内部，风险极高（那是核心链路） |
| **位置轴** | 新插槽（`chat.message.after`、未来的 `home.banner`） | 每加一个位置都要改 UI 骨架 |

补充文档提出的 `context.*` / `message.*` / `schedule.*` 三个新域，正好同时压在这三个轴上。
所以先把这个设计定下来，再实现它们。

---

## 2. 能力轴：原语是**数据**，不是代码分支

### 2.1 反面模式（必须避免）

```dart
// ❌ 绝对不要这样
Future<Object?> invoke(String pluginId, String name, Map<String, dynamic> args) {
  switch (name) {
    case 'sys.time':
      return _sysTime(args);
    case 'fs.read':
      return _fsRead(pluginId, args);
    // 每加一个原语都要在这里加一行 —— 宿主核心在无限膨胀
    default:
      throw TsukiroException(TsukiroErrorCode.unsupported, '未实现');
  }
}
```

这个写法有三个致命问题：

1. 加原语要改核心文件 → 冲突率高、回归风险大
2. 无法在运行期知道"宿主支持哪些原语" → 插件只能靠文档猜
3. 权限、参数校验、超时散落在每个 `case` 里 → 迟早不一致

### 2.2 正确做法：注册表

```dart
/// 一条原语的完整声明。加原语 = new 一个 PrimitiveSpec 并 register，不改任何核心文件。
class PrimitiveSpec {
  final String name;                  // 'sys.time'
  final String domain;                // 'sys'
  final String? permission;           // 'sys.time'；null = 无需权限
  final PrimitiveKind kind;           // request | stream | task | event
  final Map<String, dynamic> paramsSchema;
  final PrimitiveHandler handler;
  final int defaultTimeoutMs;
  final bool implemented;             // ★ 关键字段，见 §2.4
  final String since;                 // 引入版本，便于文档生成
  final String? description;
}

class PrimitiveRegistry {
  void register(PrimitiveSpec spec);
  void registerAll(Iterable<PrimitiveSpec> specs);

  PrimitiveSpec? lookup(String name);

  /// 权威调用入口：权限校验 → 参数校验 → 执行 → 审计
  Future<Object?> invoke(String pluginId, String name, Map<String, dynamic> args);

  /// 自省：插件在运行期就能问"宿主支持什么"
  Map<String, dynamic> describe();
}
```

`invoke` 是**唯一的**调用入口，因此下面这件事只需要写一次，且不可能被绕过：

```
invoke(name)
  ├─① lookup(name)  → 找不到 → UNSUPPORTED
  ├─② implemented?  → false  → UNSUPPORTED（带说明）
  ├─③ Gatekeeper.check(pluginId, spec.permission)   ← 权限，宿主侧
  ├─④ 参数对 paramsSchema 校验                       ← 参数
  ├─⑤ 执行 handler（带超时）
  └─⑥ 写审计（脱敏在写入前）
```

**顺序本身就是设计**：权限在参数校验之前 —— 未授权的插件不应该通过"参数报错信息"
探测出宿主的能力细节。

### 2.3 为什么权限跟着原语走

权限名不是独立维护的枚举，而是 `PrimitiveSpec.permission` 字段。
所以 `requiredPermissionFor('context.inject')` 不是一张手写对照表，而是
**从注册表查出来的**。

这样就不会出现「文档说需要 `context.write`，代码里却写成了 `context.write` 的旧名字」
这类漂移 —— 只有一处定义。

> 实现上前期可以保留一份静态对照表（性能与可测性），但**必须有测试断言
> 注册表与对照表一致**。当前 `permission_test.dart` 的「目录里每个权限名映射到自身」
> 就是这个思路。

### 2.4 `implemented: false` —— Demo 只实现 4 个，但注册全部

这是本文档能落地的关键。Demo 阶段：

| | 做法 |
|---|---|
| 注册 | 把 23 个域的**全部**原语都注册进 `PrimitiveRegistry` |
| 实现 | 只有 `sys.time` / `ui.toast` / `fs.read` / `model.chat` 有真实 handler |
| 其余 | `implemented: false`，统一由注册表返回 `UNSUPPORTED` |

这样做的好处：

1. **插件开发期就能自省**。`tool.list` 之外再加 `primitive.list`，插件作者能直接问
   「宿主支持 `context.inject` 吗」并按结果切换实现，而不是 try/catch 猜。
2. **加实现不改结构**。把 `implemented` 从 `false` 改成 `true`、换掉 handler，就是"实现了一个新原语"。
3. **文档自动生成**。`registry.describe()` 的输出直接就是 `docs/05-primitives.md` 的表格，
   不会出现文档与代码不一致。

---

## 3. 时机轴：钩子是**公开相位**，不是隐藏回调

### 3.1 反面模式

```dart
// ❌ 在 Agent 循环里写死
Future<void> run() async {
  await pluginA.beforeModel(ctx);     // 插件 A 的钩子
  await pluginB.beforeModel(ctx);     // 插件 B 的钩子
  final res = await model.call(ctx);  // 每加一个插件都要改这里
}
```

问题：循环内部被插件逻辑污染；一个插件抛异常会打断整条链；顺序靠代码位置而非策略。

### 3.2 正确做法：相位 + 优先级 + 错误隔离

```dart
enum HookPhase {
  contextBuild,     // 上下文组装时
  beforeModel,      // 调模型前
  afterModel,       // 模型返回后
  beforeToolCall,
  afterToolCall,
  beforeSend,       // 用户消息发出前（可拦截改写）
  afterReply,       // 本轮结束
  onMemoryRetrieve, // 预留
  onSessionSwitch,  // 预留
}

enum HookMode {
  observe,   // 只读，不能改
  mutate,    // 可改（改动被记录，计入审计）
  replace,   // 可替换整个结果（危险，需 confirm 级权限）
}

class HookBus {
  void register(HookRegistration reg);
  void unregisterPlugin(String pluginId);

  /// 按 phase 取有序钩子表：priority 升序 → pluginId 字典序（保证确定性）
  List<HookRegistration> hooksOf(HookPhase phase);

  /// 执行整条链。**单点失败不中断整条链。**
  Future<HookChainResult> emit(HookPhase phase, MutableContext ctx);
}
```

四条必须有的性质：

| 性质 | 为什么 |
|---|---|
| **优先级 + 确定性排序** | 同一优先级内按 pluginId 排序，保证每次结果一致；否则插件行为"有时对有时不对"，无法调试 |
| **错误隔离** | 一个插件抛异常 → 记审计 + 通知该插件 + **继续执行后续钩子**。否则一个坏插件能搞坏所有人的对话 |
| **超时** | 每个钩子独立超时（默认 200ms）。钩子在关键路径上，不能让它拖慢用户感知 |
| **变更追踪** | 钩子改了上下文 → 记录「哪个插件改了什么字段」。审计与调试都需要 |

### 3.3 一个插件崩溃不该毁掉整轮对话

```
emit(beforeModel, ctx)
  ├─ 插件 A (priority 10)  → 修改了 ctx.systemPrompt  → 记录
  ├─ 插件 B (priority 20)  → 抛异常                   → 记审计，标记 B 有故障，继续
  ├─ 插件 C (priority 30)  → 超时                     → 记审计，继续
  └─ 返回 ctx（A 的修改生效，B/C 的影响被丢弃）
```

这条性质不是"锦上添花"：陪伴类 App 的对话是连续的用户体验，一个插件卡住不能让整轮没反应。

---

## 4. 位置轴：插槽是**字符串**，不是枚举

```dart
// ❌ 枚举：加一个插槽要改核心 + 所有 switch
enum Slot { chatToolbar, chatHeader }   // 加 chatMessageAfter 要改这里

// ✅ 字符串 + 注册表：加插槽 = 宿主 UI 里多挂一个 SlotHost('chat.message.after')
class SlotRegistry {
  void register(UiDeclaration decl);
  void unregisterPlugin(String pluginId);
  List<UiDeclaration> get(String slot);      // 未知插槽 → 空列表，不报错
}
```

宿主 UI 侧只需要在想要的位置写一行：

```dart
SlotHost('chat.message.after', message: msg)   // 就这一行
```

**未知插槽名必须静默忽略**（记一条 warning 审计，不算安装失败）。这样：

- 新宿主 + 旧插件：正常
- 旧宿主 + 新插件：那个插槽的控件不显示，其余功能照常，插件可在详情页看到提示

否则插件作者每用一个新插槽都要配 `minHostVersion`，生态会碎成一片。

---

## 5. 数据轴：manifest 字段一次留全

见 `docs/14-decisions.md` 的 NFR-COMP-01/02。

规则：

| 变更 | 是否需要升 `manifestVersion` |
|---|---|
| 新增**可选**字段（如 `layout`、`replaces`、`harness`） | ❌ 不升。旧宿主忽略 |
| 新增**必需**字段 | ✅ 升 |
| 删除字段 | ✅ 升（major） |
| 原语新增 | ❌ 不升 |
| 原语**行为变更 / 删除** | ✅ 升 `hostApi` major |

因此 `provides.layout` / `provides.replaces` / `provides.theme` / `harness` **现在就写进 schema 并校验**，
只是宿主**不执行**。这样插件作者今天写的 manifest，未来宿主升级后不用改一个字。

当前状态：

| 字段 | schema | 解析为强类型 | 宿主执行 |
|---|---|---|---|
| `provides.tools` | ✅ | ✅ | Demo 执行 |
| `provides.ui` | ✅ | ✅ | Demo 执行 |
| `provides.pages` | ✅ | ✅ | Demo 执行 |
| `provides.theme` | ✅ | ⬜ 待做 | ⬜ L1 阶段 |
| `provides.overlays` / `skills` / `personas` / `mcp` / `memory` | ✅ | ⬜ 待做 | ⬜ |
| `layout` / `replaces` | ⬜ 待加 | ⬜ | ⬜ L2 / L3 |
| `harness` | ✅ | ⬜ 保留原始 | `implemented: false` |

---

## 6. 自省接口：让插件在运行期问宿主

这是"可扩展性"最容易被忽略但对生态最重要的一环。宿主必须能回答：

```dart
// 插件侧（通过 Bridge）
await tsukiro.primitive.list();      // [{ name, permission, implemented, since }]
await tsukiro.hook.phases();         // 当前宿主支持哪些时机
await tsukiro.slot.list();           // 当前宿主预埋了哪些插槽
await tsukiro.host.capabilities();   // 综合能力清单
```

有了它，插件可以这样写：

```js
const caps = await tsukiro.host.capabilities();
if (caps.primitives['context.inject']?.implemented) {
  await tsukiro.context.inject({ text: `当前好感度 ${mood}` });
} else {
  // 降级：贴到消息末尾
  await tsukiro.message.append({ messageId, content: `（好感度 ${mood}）` });
}
```

**没有自省接口，插件只能靠版本号猜。** 这会让插件作者要么写死 `minHostVersion`
（生态碎片化），要么 try/catch 探测（代码丑陋且掩盖真错误）。

---

## 7. Surface 与 Flame 扩展轴

复杂交互不应继续堆叠到 `provides.ui` 的控件类型中。Surface 采用独立注册表：

- `kind:web`：插件自有 HTML/CSS/JS WebView，受 CSP、导航、尺寸和 Bridge 限制；
- `kind:flame`：manifest 只选择宿主编译期注册的 `gameType`，由 `GameWidget` 承载；
- capability（dragDrop、richText、animation、canvas）只描述 UI 技术能力，不自动授予文件、网络、模型或剪贴板权限；
- Surface 实例绑定 `pluginId + instanceId + surfaceId`，重装/停用/卸载必须销毁旧实例。

普通插件不得上传 Dart、Flutter snapshot、native library 或动态 Flame runtime。这样可以支持游戏和复杂 UI，同时保持 `plugin_core` 纯 Dart、权限集中在宿主和 Bridge。

## 8. 必须避免的反面模式清单

| 反面模式 | 为什么不行 | 正确做法 |
|---|---|---|
| `switch (primitiveName)` 分发 | 加原语改核心 | `PrimitiveRegistry` |
| 权限名硬编码在调用点 | 迟早与文档漂移 | 权限是 `PrimitiveSpec` 的字段 |
| 在 Agent 循环里直接调插件 | 一个插件拖慢/搞崩整轮 | `HookBus` 的相位 + 隔离 + 超时 |
| 插槽用枚举 | 加位置改核心 | 插槽名字符串 + 空结果兜底 |
| manifest 字段"用到再加" | 旧插件必须改 | 一次留全，只解析不执行 |
| 插件能力靠版本号猜 | 生态碎片化 | `describe()` 自省 |
| Demo 只硬编码 4 个原语 | 框架退化成写死的功能表 | 全量注册 + `implemented: false` |
| 钩子同步执行 | 慢钩子直接卡 UI | 异步 + 超时 + 关键路径预算 |

---

## 8. 落地顺序

| # | 事项 | 状态 |
|---|---|---|
| 1 | 权限目录扩展（`context.*` / `message.*` / `schedule.*` / `sys.intervene` / `sys.overlay`） | 本文档同批 |
| 2 | `PrimitiveRegistry` + `PrimitiveSpec` + 全量注册（含 `implemented: false`） | 本文档同批 |
| 3 | `HookBus` + `HookPhase` + `HookMode` + 错误隔离/超时 | 本文档同批 |
| 4 | `BridgeSession`：握手门禁 + 把 `req` 路由到 `PrimitiveRegistry` | 本文档同批 |
| 5 | `provides.theme` 解析为强类型（L1） | 待做 |
| 6 | `layout` / `replaces` 写进 schema（不执行） | 待做 |
| 7 | 无头 demo 验证程序：安装 → 注册 → 工具调用 → 原语 → 回传 | 待做 |
| 8 | `installer` 状态机与磁盘原子性 | 待做 |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-02 | 初版：三个变化轴、注册表 / 钩子总线 / 字符串插槽、自省接口、反面模式清单 |
