/// 宿主能力接口 —— 内核定义，宿主实现。
///
/// 为什么放在内核而不是宿主：**原语实现需要调用它们，而原语实现在内核里**。
/// 内核只依赖这些抽象，因此可以在没有 Flutter / Android 的情况下单测整套原语。
/// 宿主在启动时把它们 `services.put<HostClock>(impl)` 注入进去。
///
/// 加一个新的宿主能力 = 加一个抽象类 + `services.put`，
/// **不需要改内核任何容器类**（见 `docs/16-extensibility.md`）。
library;

import '../agent/chat_message.dart';
import '../data/data_query.dart';
import '../ui/ui_node.dart';

// ─────────────────────────── 系统 ───────────────────────────

/// 时钟。`sys.time` 用。
abstract class HostClock {
  /// 当前时间（设备本地时区）。
  DateTime now();

  /// 设备本地 IANA 时区名，如 `Asia/Shanghai`。
  String get timezoneName;

  /// 按 IANA 时区名取当前时间。宿主不支持该时区名时返回 null。
  ///
  /// 宿主实现可用 `timezone` 包；无头测试用固定偏移表即可。
  DateTime? nowIn(String timezoneName);
}

/// 设备与系统信息。`sys.battery` / `sys.network` / `sys.device` / `sys.locale` 用。
abstract class HostSystemInfo {
  Future<Map<String, dynamic>> battery();
  Future<Map<String, dynamic>> network();
  Future<Map<String, dynamic>> device();
  Future<Map<String, dynamic>> locale();
}

// ─────────────────────────── UI ───────────────────────────

/// 一个对话框按钮。
class UiButton {
  const UiButton(this.id, this.label, {this.style = 'default'});

  final String id;
  final String label;

  /// `default` / `primary` / `danger`。
  final String style;
}

/// 宿主 UI 表面。`ui.*` 用。
///
/// 内核只声明"能弹什么"，不管怎么弹 —— Flutter 宿主用原生组件，
/// 无头测试用一个记录型假实现。
abstract class HostUi {
  /// 弹一条轻提示。
  void toast(String text, {Duration duration, String kind});

  /// 弹对话框，返回被点击按钮的 id（用户关闭则返回 null）。
  Future<String?> dialog({
    required String title,
    String? content,
    List<UiButton> buttons,
  });

  /// 打开插件的独立页面。返回是否成功。
  Future<bool> navigate(String pageId, {Map<String, dynamic>? params});

  /// 关闭当前页面。
  Future<void> close();

  /// 设置容器标题。
  Future<void> setTitle(String title);
}

// ─────────────────────────── 文件 ───────────────────────────

/// 真实文件读写。沙箱路径解析由 `fs.*` 的原语实现负责（用 `SandboxPathGuard`），
/// 这里只管"给定绝对路径，读写它"。
abstract class HostFiles {
  Future<String> readText(String absolutePath);
  Future<List<int>> readBytes(String absolutePath);
  Future<void> writeText(String absolutePath, String text, {bool append = false});
  Future<void> writeBytes(String absolutePath, List<int> bytes, {bool append = false});
  Future<bool> exists(String absolutePath);
  Future<int> size(String absolutePath);
  Future<void> delete(String absolutePath, {bool recursive = false});
  Future<List<Map<String, dynamic>>> list(String absoluteDirectory, {bool recursive = false});
}

/// 插件沙箱根目录的提供者。
///
/// `fs.*` 的原语实现必须通过它拿到根目录，**不能自己拼路径** ——
/// 拼错了就是沙箱逃逸。
abstract class SandboxProvider {
  /// 该插件的数据目录绝对路径；未安装返回 null。
  String? dataRootFor(String pluginId);
}

// ─────────────────────────── 模型 ───────────────────────────

/// 一次模型请求。
class ModelRequest {
  const ModelRequest({
    required this.messages,
    this.tools = const <Map<String, dynamic>>[],
    this.model,
    this.temperature,
    this.stream = false,
    this.maxTokens,
    this.extra = const <String, dynamic>{},
  });

  final List<ChatMessage> messages;

  /// OpenAI 格式的工具声明。
  final List<Map<String, dynamic>> tools;

  /// **逻辑模型名**（如 `default` / `fast`），不是上游真实模型名。
  final String? model;

  final double? temperature;
  final bool stream;
  final int? maxTokens;
  final Map<String, dynamic> extra;
}

/// 一次模型回复。
class ModelReply {
  const ModelReply({
    required this.text,
    this.reasoning,
    this.toolCalls = const <ToolCall>[],
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.finishReason,
    this.extra = const <String, dynamic>{},
  });

  final String text;

  /// 推理模型的思维链（`reasoning_content`）。
  ///
  /// 与 [text] **分开保存**是刻意的：思维链通常很长且不该直接展示给用户，
  /// 但丢掉它又会让"模型为什么这么答"无从排查。UI 可以折叠显示。
  final String? reasoning;

  final List<ToolCall> toolCalls;
  final int promptTokens;
  final int completionTokens;
  final String? finishReason;

  /// 供应商/中转站塞的私有字段（如 `cost_cny`、`trace_id`）。
  ///
  /// 内核不解释，原样带给宿主 —— 中转站的计费与追踪信息对运营有用，
  /// 在解析层丢掉就再也拿不回来了。
  final Map<String, dynamic> extra;

  bool get hasToolCalls => toolCalls.isNotEmpty;

  @override
  String toString() =>
      'ModelReply(${text.length} 字符'
      '${reasoning == null ? '' : ', 思维链 ${reasoning!.length} 字符'}'
      ', ${toolCalls.length} 次工具调用)';
}

/// 模型网关。
///
/// **插件永远拿不到上游凭据** —— 它调用 `model.chat` 原语，宿主用这个接口代发请求，
/// 凭据只存在于宿主（Demo）或网关（正式版）。
///
/// 同一个接口也服务于宿主自己的 Agent 循环，保证"插件调模型"和"用户聊天"
/// 走的是完全一致的路径 —— 包括限流与计费。
abstract class ModelGateway {
  /// 非流式补全。
  Future<ModelReply> complete(ModelRequest request);

  /// 流式补全。分片是纯文本 delta；工具调用在流结束后通过 `complete` 的
  /// 同构返回（宿主负责把分片的 `arguments` 拼接后解析）。
  Stream<String> stream(ModelRequest request);

  /// 当前生效的逻辑模型名。
  String get activeModel;
}

/// 流式增量回调。
///
/// **刻意用两个字符串而不是一个分片对象**：分片的具体形状是**协议细节**
/// （OpenAI 有 `reasoning_content`、Anthropic 有 `thinking_delta`、
/// Google 又是另一套）。内核不该知道这些，只需要"多了一段正文"和"多了一段思维链"。
typedef ModelDeltaCallback = void Function(String? content, String? reasoning);

/// 宿主提供的**流式**模型调用。
///
/// [ModelGateway.complete] 够用但要等整段回完才有动静 —— 界面上就是"发出去
/// 之后界面静止十几秒"。所以宿主可以实现这个可选能力，[AgentLoop] 检测到就走它。
///
/// 传 null 表示宿主不支持流式，循环退回非流式路径。**两条路返回同一个类型**，
/// 因此上层（工具循环、消息落库）不需要分支。
typedef StreamingModelCall = Future<ModelReply> Function(
  ModelRequest request,
  ModelDeltaCallback onDelta,
);

// ─────────────────────────── 消息与上下文 ───────────────────────────

/// 消息读写。`message.*` 与 `context.*` 用。
abstract class MessageStore {
  Future<ChatMessage?> get(String messageId);
  Future<List<Map<String, dynamic>>> list(String sessionId, {int limit = 50});

  /// 打补丁。**只允许白名单字段**，其余忽略并记审计。
  Future<bool> patch(String messageId, Map<String, dynamic> patch);

  Future<bool> delete(String messageId);

  /// 追加一条消息到会话（不触发模型调用）。
  Future<String> append(String sessionId, ChatMessage message);

  /// 主动发消息并**触发模型调用**（消耗点数）。
  Future<String> send(String sessionId, String content);
}

/// 上下文注入的宿主侧实现。
abstract class ContextSink {
  /// 注入一段文本。返回注入 id，用于后续撤销。
  Future<String> inject({
    required String pluginId,
    required String text,
    required String position,
    required int priority,
    String? tag,
    Duration? ttl,
  });

  /// 撤销该插件的全部注入（插件停用 / 崩溃时宿主必须调用）。
  Future<int> clearPlugin(String pluginId);

  /// 当前注入占用的大致字节数（用于上限判断）。
  Future<int> currentBytes(String pluginId);
}

/// 能把注入组装成最终文本的上下文源。
///
/// 与 [ContextSink] 分开是因为职责不同：前者是**写入接口**（原语用），
/// 后者是**读取接口**（Agent 循环用）。Flutter 宿主可以用同一个对象实现两者，
/// 但循环只依赖这一个方法，因此不必知道注入是怎么存的。
abstract class ContextAssembler {
  /// 组装最终要拼进 system prompt 的文本；没有注入时返回空串。
  String buildInjection();
}

// ─────────────────────────── 调度 ───────────────────────────

/// 后台任务调度。`schedule.*` 用。
///
/// **实现必须保证：任务触发时重新校验权限**，而不是创建时校验一次。
/// 否则调度就成了绕过权限的通道（见 `docs/05-primitives.md` §3.22）。
abstract class HostScheduler {
  static const Duration minPeriod = Duration(seconds: 60);
  static const int maxTasksPerPlugin = 16;

  /// 延迟执行一次。返回任务 id。
  Future<String> once({
    required String pluginId,
    required Duration delay,
    required String handler,
    String? tag,
  });

  /// 周期执行。返回任务 id。`period < minPeriod` 应被拒绝。
  Future<String> interval({
    required String pluginId,
    required Duration period,
    required String handler,
    String? tag,
    bool immediate = false,
  });

  Future<bool> cancel(String taskId);

  Future<List<Map<String, dynamic>>> list({String? pluginId});

  /// 插件停用 / 卸载时清除其全部任务。
  Future<int> clearPlugin(String pluginId);
}

// ─────────────────────────── 对话上下文 ───────────────────────────

/// 当前对话上下文。`chat.*` 用。
///
/// ## 为什么需要"当前对话"这个概念
///
/// 插件调 `chat.lastMessage()` 时**不带会话 id** —— 它的语义是
/// "用户现在看的这个对话里最近一条消息"，就像用户说"翻译这条"。
///
/// 要求插件自己传会话 id 会很难用：插件根本不知道宿主界面上开着哪个对话，
/// 而且它在按钮被点的那一刻也拿不到。所以由宿主维护"当前对话"。
/// 数据访问。宿主实现；插件通过 `data.*` 原语使用。
///
/// 接口收 [DataQuery] + [DataScope] 而不是 SQL ——
/// **宿主自己也不知道插件想要什么 SQL**，它只知道插件想要什么数据。
/// 编译（拼 SQL）在内核里做，见 [DataQueryCompiler]。
/// 原生窗口：宿主用 Flutter 渲染插件描述的界面。
///
/// **插件拿不到 Flutter** —— 它只能送来一棵 [UiNode] 树。
/// 这是主题一致性的来源：因为宿主画，颜色圆角间距全自动跟着 token 走。
///
/// 窗口是**有状态**的：`open` 之后可以用 `update` 换内容，
/// 所以宿主需要持有当前树（而不是每次重建）。
/// 插件自己的键值存储。
///
/// **按插件分区**：插件 A 读不到插件 B 的键。
/// 键名由插件自己定，宿主不做语义解释 —— 那部分是插件的自由。
///
/// 等 docs/20 的 per-agent 安装落地后，分区键会变成
/// (pluginId, agentId)，接口签名不变。
abstract class HostPluginState {
  /// 读。键不存在返回 null（**不是错误** —— 首次运行时读一个
  /// 还没写过的键是正常的）。
  Future<Object?> get(String pluginId, String key);

  /// 写。值是任意 JSON 可序列化的东西。
  ///
  /// 宿主会限制单个值的大小 —— 插件存储不是文件系统。
  Future<void> set(String pluginId, String key, Object? value);

  /// 删。键不存在返回 false。
  Future<bool> delete(String pluginId, String key);

  /// 列出键名（不含值）。[prefix] 可选。
  Future<List<String>> keys(String pluginId, {String? prefix});
}

abstract class HostNativeWindow {
  /// 打开一个窗口。同一个 pluginId 下 windowId 唯一。
  ///
  /// 已经开着时**替换内容**并返回 true，不报错 ——
  /// 插件重开自己的窗口是正常操作，不该让它先 close。
  Future<bool> open(
    String pluginId,
    String windowId, {
    String? title,
    required UiNode root,
  });

  /// 更新内容与标题。窗口没开着时返回 false。
  Future<bool> update(
    String pluginId,
    String windowId, {
    String? title,
    UiNode? root,
  });

  /// 关闭。没开着时返回 false（**不是错误** —— 关一个已经关了的窗口
  /// 是幂等的正常情况）。
  Future<bool> close(String pluginId, String windowId);

  /// 这个插件当前有没有开着的窗口。
  bool isOpen(String pluginId, String windowId);
}

abstract class HostDataAccess {
  /// 执行查询。
  ///
  /// **[pluginId] 是必需的** —— 作用域与权限由宿主按调用方解析，
  /// 插件自己指定不了。这是刻意的：
  /// 作用域是**安全决定**，而安全决定不该由被检查的一方提供参数。
  ///
  /// 返回 `{rows: [...], scope: 'ownAgent'|'all'|'none', limit: n}`。
  /// `scope` 让插件能分清"没有数据"和"没有权限"。
  /// [crossAgent] 由内核按**原语名**给出 —— 门禁已经判定过对应权限。
  Future<Map<String, dynamic>> query(
    String pluginId,
    DataQuery query, {
    bool crossAgent = false,
  });

  /// 自省：可查询的实体与列。
  ///
  /// 有了它，插件不必靠文档猜 —— 宿主加了实体它立刻能用。
  List<Map<String, dynamic>> describeEntities();
}

abstract class HostSurfaceController {
  Future<bool> open(String pluginId, String surfaceId);
  Future<bool> update(String pluginId, String surfaceId, Map<String, dynamic> state);
  Future<bool> close(String pluginId, String surfaceId);
  Future<bool> event(String pluginId, String surfaceId, Map<String, dynamic> event);
}

/// 当前智能体与插件状态/记忆的受控宿主服务。
///
/// 插件不能传入任意 agentId 或 conversationId；宿主实现负责绑定当前界面上下文。
abstract class HostAgentState {
  String? get activeAgentId;
  String? get activeConversationId;

  Future<Map<String, dynamic>> getState(String pluginId);
  Future<Map<String, dynamic>> setState(
    String pluginId,
    Map<String, dynamic> patch,
  );

  Future<String> greet(String pluginId);

  /// 使用当前智能体配置的模型，不暴露凭据。
  Future<Map<String, dynamic>> modelChat(
    String pluginId,
    List<Map<String, dynamic>> messages,
  );

  /// 只允许向当前对话追加 assistant 评价，不触发再次模型调用。
  Future<String> appendAssistantMessage(String pluginId, String content);

  Future<bool> openSurface(String pluginId, String surfaceId);
  Future<bool> updateSurface(String pluginId, String surfaceId, Map<String, dynamic> state);
  Future<bool> closeSurface(String pluginId, String surfaceId);
  Future<bool> surfaceEvent(String pluginId, String surfaceId, Map<String, dynamic> event);
  Future<Map<String, dynamic>?> surfaceState(String pluginId, String surfaceId);

  Future<List<Map<String, dynamic>>> listMemories(
    String pluginId, {
    String? keyword,
    int limit = 20,
  });

  Future<String> addMemory(
    String pluginId, {
    required String content,
    String kind = 'custom',
    Map<String, dynamic>? metadata,
  });
}

abstract class HostChatContext {
  /// 用户当前打开的对话 id；不在对话页时为 null。
  ///
  /// 插件据此可以给出"你现在没在对话里"这种准确提示，
  /// 而不是笼统的"取不到消息"。
  String? get activeConversationId;

  /// 取某个对话里最近一条消息（可按角色过滤）。
  ///
  /// 返回 `{id, role, text, createdAt}`；没有消息时返回 null。
  Future<Map<String, dynamic>?> lastMessage(
    String conversationId, {
    String? role,
  });
}

// ─────────────────────────── 插件配置 ───────────────────────────

/// 插件自己的配置。`config.*` 用。
///
/// 配置项在清单的 `config.schema` 里声明（带默认值），
/// 用户改过的值存在宿主侧。**插件只看到键值，看不到存储细节** ——
/// 这样宿主换存储实现（内存 → SQLite → 同步服务）不影响插件。
abstract class HostPluginConfig {
  /// 读一个配置项。没设置过时返回 [fallback]（通常是 schema 里的默认值）。
  Future<Object?> get(String pluginId, String key, {Object? fallback});

  /// 写一个配置项。
  Future<void> set(String pluginId, String key, Object? value);

  /// 取该插件的全部配置（含 schema 默认值）。
  Future<Map<String, Object?>> all(String pluginId);
}
