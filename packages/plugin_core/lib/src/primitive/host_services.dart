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
