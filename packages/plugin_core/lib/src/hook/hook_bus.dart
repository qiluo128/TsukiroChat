/// 钩子总线 —— 插件影响 Agent 循环的**唯一合法入口**。
///
/// 设计见 `docs/16-extensibility.md` §3。四条必须有的性质：
///
/// | 性质 | 为什么 |
/// |---|---|
/// | 优先级 + 确定性排序 | 同优先级按 pluginId 排序。否则插件行为"有时对有时不对"，无法调试 |
/// | **错误隔离** | 一个插件抛异常 → 记审计 + 继续跑后面的钩子。不能让它毁掉整轮对话 |
/// | 超时 | 钩子在关键路径上，单个钩子默认 200ms 预算 |
/// | 变更追踪 | 记下"哪个插件改了什么"，审计与调试都需要 |
library;

import 'dart:async';

import '../agent/chat_message.dart';
import '../audit/audit.dart';
import '../common/errors.dart';

/// 钩子时机。
///
/// 新增时机**不需要改 HookBus** —— 枚举加一项、宿主在合适的地方 `emit` 即可。
/// `onMemoryRetrieve` / `onSessionSwitch` 是 L6 / 阶段 1 的预留。
enum HookPhase {
  /// 组装上下文时（注入提示词、调整历史）。
  contextBuild,

  /// 调模型前（最后一次改动机会）。
  beforeModel,

  /// 模型返回后（读取/改写回复）。
  afterModel,

  /// 工具执行前。
  beforeToolCall,

  /// 工具执行后。
  afterToolCall,

  /// 用户消息发出前（可拦截改写）。
  beforeSend,

  /// 本轮结束。
  afterReply,

  /// 预留：记忆检索时（L6）。
  onMemoryRetrieve,

  /// 预留：切换会话时。
  onSessionSwitch,

  // ─────────────────── 消息操作（撤回 / 编辑 / 重说） ───────────────────
  //
  // 「撤回」会把内容从库里删掉。如果插件想留一份（审计、冷备、分离存储），
  // **它只有 before 这一次机会** —— after 的时候内容已经没了。
  //
  // 所以 before 相位必须拿到被操作消息的**完整内容**，
  // 而不只是一个 id。见 [MessageOpPayload]。

  /// 撤回消息**之前**。
  ///
  /// 用途（用户举的例子）：插件拦截撤回、把内容另存一份。
  /// 这是插件保住内容的唯一时机。
  beforeMessageRetract,

  /// 撤回之后。此时内容已经不在库里，只能拿到 id 与条数。
  afterMessageRetract,

  /// 编辑消息**之前**。载荷里同时有原文与改后的文本 ——
  /// 插件据此可以做版本历史。
  beforeMessageEdit,

  afterMessageEdit,

  /// 重新生成回复**之前**。载荷里带着那条即将被丢弃的回复。
  beforeRegenerate,

  afterRegenerate;

  static HookPhase? parse(String? raw) {
    for (final p in HookPhase.values) {
      if (p.name == raw) return p;
    }
    return null;
  }
}

/// 消息操作的载荷。
///
/// 挂在 [HookContext.vars] 的 `'messageOp'` 键下。
///
/// ## 为什么 before 相位必须带 `content`
///
/// 「撤回」的语义是**把内容从库里删掉**。插件若想留一份
/// （审计、冷备、分离存储），只有 before 那一次机会 ——
/// after 的时候内容已经没了，光给 id 没有用。
///
/// 这是刻意的信息设计：**不假设插件只要知道"发生了什么"，
/// 而是保证它在唯一能行动的时刻拿得到行动所需的东西。**
class MessageOpPayload {
  const MessageOpPayload({
    required this.op,
    required this.messageId,
    this.role,
    this.content,
    this.newText,
    this.deletedCount = 0,
  });

  /// `'retract'` | `'edit'` | `'regenerate'`。
  final String op;

  final String messageId;

  /// user / assistant / system。
  final String? role;

  /// **被操作消息的完整内容。**
  ///
  /// before 相位一定有；afterMessageRetract 时为 null（已经删了）。
  final String? content;

  /// 仅编辑：改后的文本。
  final String? newText;

  /// 仅 after 相位：这次操作实际影响了多少条消息。
  ///
  /// 撤回用户消息会连带删掉它的回复，所以往往不止一条。
  final int deletedCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'op': op,
        'messageId': messageId,
        if (role != null) 'role': role,
        if (content != null) 'content': content,
        if (newText != null) 'newText': newText,
        'deletedCount': deletedCount,
      };

  static MessageOpPayload? fromVars(Map<String, dynamic> vars) {
    final raw = vars['messageOp'];
    if (raw is! Map) return null;
    return MessageOpPayload(
      op: raw['op']?.toString() ?? '',
      messageId: raw['messageId']?.toString() ?? '',
      role: raw['role']?.toString(),
      content: raw['content']?.toString(),
      newText: raw['newText']?.toString(),
      deletedCount: (raw['deletedCount'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'MessageOpPayload($op $messageId, content=${content?.length ?? 0} 字)';
}

/// 钩子对上下文的影响方式。
enum HookMode {
  /// 只读。返回值被忽略。
  observe,

  /// 可改上下文。
  mutate,

  /// 可替换整个上下文的关键部分（危险，需要 `context.hook` + confirm 级确认）。
  replace,
}

/// 一条钩子注册。
class HookRegistration {
  const HookRegistration({
    required this.id,
    required this.pluginId,
    required this.phase,
    required this.handler,
    this.priority = 100,
    this.mode = HookMode.mutate,
    this.timeoutMs = 200,
    this.tag,
  });

  /// 全局唯一（宿主生成）。
  final String id;

  final String pluginId;
  final HookPhase phase;

  /// 插件包内相对路径，宿主通过 Bridge `inv hook.invoke` 调用它。
  final String handler;

  /// 越小越先执行。
  final int priority;

  final HookMode mode;
  final int timeoutMs;
  final String? tag;

  @override
  String toString() => 'HookRegistration($phase/$pluginId#$id, p$priority)';
}

/// 钩子执行时可见的上下文。
///
/// 用**可变对象**而不是"返回新对象"，因为一条链上多个钩子要依次叠加影响。
/// 代价是需要追踪谁改了什么 —— 见 [changedFields]。
class HookContext {
  HookContext({
    required this.phase,
    required this.sessionId,
    required String systemPrompt,
    required List<ChatMessage> messages,
    Map<String, dynamic>? vars,
  })  : _systemPrompt = systemPrompt,
        _messages = List<ChatMessage>.from(messages),
        vars = vars ?? <String, dynamic>{};

  final HookPhase phase;
  final String sessionId;

  String _systemPrompt;
  List<ChatMessage> _messages;

  /// 自由变量（当前消息、工具调用等），宿主按 phase 填充。
  final Map<String, dynamic> vars;

  /// 被改动过的字段名，按发生顺序。
  final List<String> changedFields = <String>[];

  String get systemPrompt => _systemPrompt;

  set systemPrompt(String value) {
    if (value == _systemPrompt) return;
    _systemPrompt = value;
    changedFields.add('systemPrompt');
  }

  /// 只读视图。要改请用 [replaceMessages] / [appendMessage]。
  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  void replaceMessages(List<ChatMessage> next) {
    _messages = List<ChatMessage>.from(next);
    changedFields.add('messages');
  }

  void appendMessage(ChatMessage message) {
    _messages.add(message);
    changedFields.add('messages');
  }

  /// 工作副本，供宿主在链执行完后落地。
  List<ChatMessage> get mutableMessages => _messages;

  bool get wasMutated => changedFields.isNotEmpty;
}

/// 调用插件钩子的分发器。
///
/// 宿主注入具体实现（走 Bridge）。返回 null 表示插件无改动；
/// 返回非 null 时宿主**自行决定**如何应用（HookBus 不解释返回结构，
/// 因为不同 phase 的语义不同）。
typedef HookDispatcher = Future<Map<String, dynamic>?> Function(
  HookRegistration registration,
  HookContext context,
);

/// 单个钩子的执行结果。
class HookOutcome {
  const HookOutcome({
    required this.registration,
    required this.ok,
    required this.durationMs,
    this.errorCode,
    this.errorMessage,
    this.changedFields = const <String>[],
  });

  final HookRegistration registration;
  final bool ok;
  final int durationMs;
  final String? errorCode;
  final String? errorMessage;

  /// 这个钩子改动了哪些字段。
  final List<String> changedFields;

  bool get timedOut => errorCode == errorCodeToString(TsukiroErrorCode.timeout);
}

/// 整条链的执行结果。
class HookChainResult {
  const HookChainResult({
    required this.phase,
    required this.outcomes,
    required this.context,
  });

  final HookPhase phase;
  final List<HookOutcome> outcomes;
  final HookContext context;

  bool get allOk => outcomes.every((o) => o.ok);

  bool get anyFailed => outcomes.any((o) => !o.ok);

  /// 本次链上有故障的插件（宿主可据此给用户提示 / 降级）。
  Set<String> get faultyPlugins => outcomes
      .where((o) => !o.ok)
      .map((o) => o.registration.pluginId)
      .toSet();

  /// 出错的钩子（**不中断链**，只是被跳过）。
  List<HookOutcome> get failures =>
      outcomes.where((o) => !o.ok).toList(growable: false);

  @override
  String toString() =>
      'HookChainResult(${phase.name}, ${outcomes.length} hooks, '
      '${failures.length} failed)';
}

/// 钩子总线。
class HookBus {
  HookBus({
    required this.dispatcher,
    AuditSink? audit,
    this.defaultTimeoutMs = 200,
  }) : audit = audit ?? const NullAuditSink();

  final HookDispatcher dispatcher;
  final AuditSink audit;

  /// 单个钩子的默认超时预算。
  final int defaultTimeoutMs;

  final Map<HookPhase, List<HookRegistration>> _byPhase =
      <HookPhase, List<HookRegistration>>{};
  final Map<String, String> _pluginVersion = <String, String>{};

  /// 注册一条钩子。
  void register(HookRegistration registration, {String? pluginVersion}) {
    final list = _byPhase.putIfAbsent(registration.phase, () => <HookRegistration>[]);
    if (list.any((r) => r.id == registration.id)) {
      throw StateError('钩子 id "${registration.id}" 重复注册');
    }
    list.add(registration);
    if (pluginVersion != null) {
      _pluginVersion[registration.pluginId] = pluginVersion;
    }
    // 保持有序：priority 升序 → pluginId 字典序 → id 字典序（保证完全确定）
    list.sort(_compare);
  }

  void registerAll(Iterable<HookRegistration> registrations) {
    for (final r in registrations) {
      register(r);
    }
  }

  static int _compare(HookRegistration a, HookRegistration b) {
    if (a.priority != b.priority) return a.priority.compareTo(b.priority);
    final byPlugin = a.pluginId.compareTo(b.pluginId);
    if (byPlugin != 0) return byPlugin;
    return a.id.compareTo(b.id);
  }

  /// 注销某插件的全部钩子（停用 / 卸载 / 崩溃时调用）。
  ///
  /// **必须调用**：否则插件卸载后它的钩子还会被调用，轻则报错，重则
  /// 「插件已卸载但仍在影响 AI 上下文」。
  int unregisterPlugin(String pluginId) {
    var removed = 0;
    for (final list in _byPhase.values) {
      final before = list.length;
      list.removeWhere((r) => r.pluginId == pluginId);
      removed += before - list.length;
    }
    _pluginVersion.remove(pluginId);
    return removed;
  }

  /// 某相位的有序钩子表。
  List<HookRegistration> hooksOf(HookPhase phase) =>
      List<HookRegistration>.unmodifiable(_byPhase[phase] ?? const <HookRegistration>[]);

  int get length =>
      _byPhase.values.fold(0, (sum, list) => sum + list.length);

  /// 清空（测试用）。
  void clear() {
    _byPhase.clear();
    _pluginVersion.clear();
  }

  /// 执行一个相位的整条链。
  ///
  /// **单点失败不中断整条链。** 每个钩子独立超时、独立捕获异常。
  Future<HookChainResult> emit(HookPhase phase, HookContext context) async {
    if (context.phase != phase) {
      throw ArgumentError(
        'HookContext.phase 是 ${context.phase.name}，与 emit 的 ${phase.name} 不一致',
      );
    }

    final hooks = _byPhase[phase] ?? const <HookRegistration>[];
    if (hooks.isEmpty) {
      return HookChainResult(phase: phase, outcomes: const <HookOutcome>[], context: context);
    }

    final outcomes = <HookOutcome>[];

    for (final reg in hooks) {
      final before = List<String>.from(context.changedFields);
      final sw = Stopwatch()..start();

      try {
        await dispatcher(reg, context)
            .timeout(Duration(milliseconds: reg.timeoutMs > 0 ? reg.timeoutMs : defaultTimeoutMs));
        sw.stop();

        final changed = _diff(before, context.changedFields);

        // observe 模式不许改上下文 —— 改了就是插件违约，回滚不了，
        // 但必须记下来（observe 是插件声明"我只看看"，违约要能被发现）
        if (reg.mode == HookMode.observe && changed.isNotEmpty) {
          outcomes.add(HookOutcome(
            registration: reg,
            ok: false,
            durationMs: sw.elapsedMilliseconds,
            errorCode: errorCodeToString(TsukiroErrorCode.pluginError),
            errorMessage: '钩子声明为 observe 却修改了上下文：${changed.join(", ")}',
            changedFields: changed,
          ));
          _audit(context, reg, 'error', 'OBSERVE_VIOLATION', sw.elapsedMilliseconds, changed);
          continue;
        }

        outcomes.add(HookOutcome(
          registration: reg,
          ok: true,
          durationMs: sw.elapsedMilliseconds,
          changedFields: changed,
        ));
        if (changed.isNotEmpty) {
          _audit(context, reg, 'ok', null, sw.elapsedMilliseconds, changed);
        }
      } on TimeoutException {
        sw.stop();
        outcomes.add(HookOutcome(
          registration: reg,
          ok: false,
          durationMs: sw.elapsedMilliseconds,
          errorCode: errorCodeToString(TsukiroErrorCode.timeout),
          errorMessage: '钩子超时（${reg.timeoutMs}ms）',
        ));
        _audit(context, reg, 'error', 'TIMEOUT', sw.elapsedMilliseconds, const <String>[]);
      } on TsukiroException catch (e) {
        sw.stop();
        outcomes.add(HookOutcome(
          registration: reg,
          ok: false,
          durationMs: sw.elapsedMilliseconds,
          errorCode: errorCodeToString(e.code),
          errorMessage: e.message,
        ));
        _audit(context, reg, 'error', errorCodeToString(e.code), sw.elapsedMilliseconds,
            const <String>[]);
      } catch (e) {
        sw.stop();
        outcomes.add(HookOutcome(
          registration: reg,
          ok: false,
          durationMs: sw.elapsedMilliseconds,
          errorCode: errorCodeToString(TsukiroErrorCode.pluginError),
          errorMessage: '$e',
        ));
        _audit(context, reg, 'error', 'PLUGIN_ERROR', sw.elapsedMilliseconds, const <String>[]);
      }
    }

    return HookChainResult(phase: phase, outcomes: outcomes, context: context);
  }

  static List<String> _diff(List<String> before, List<String> after) {
    if (after.length <= before.length) return const <String>[];
    return after.sublist(before.length).toSet().toList(growable: false);
  }

  void _audit(
    HookContext context,
    HookRegistration reg,
    String result,
    String? errorCode,
    int durationMs,
    List<String> changed,
  ) {
    audit.write(AuditEntry(
      pluginId: reg.pluginId,
      pluginVersion: _pluginVersion[reg.pluginId],
      kind: 'hook',
      primitive: 'hook.${reg.phase.name}',
      argsDigest: <String, dynamic>{
        'hookId': reg.id,
        if (reg.tag != null) 'tag': reg.tag,
        if (changed.isNotEmpty) 'changed': changed,
      },
      result: result,
      errorCode: errorCode,
      durationMs: durationMs,
    ));
  }

  /// 自省：宿主支持哪些时机、各有多少钩子。
  Map<String, dynamic> describe() => <String, dynamic>{
        'phases': HookPhase.values.map((p) => p.name).toList(growable: false),
        'registered': <String, int>{
          for (final entry in _byPhase.entries)
            if (entry.value.isNotEmpty) entry.key.name: entry.value.length,
        },
        'total': length,
      };
}
