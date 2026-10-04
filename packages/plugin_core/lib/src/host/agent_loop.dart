/// Agent 循环 —— 一轮对话从上下文组装到收尾的完整流程。
///
/// 见 `docs/09-agent-and-tools.md`。三条设计约束：
///
/// 1. **有步数上限。** 没有上限的循环遇到「模型反复调同一个工具」会无限烧钱，
///    这是同类产品最常见的线上事故。
/// 2. **工具失败不中断对话。** 错误原样交给模型，让它自己组织语言告诉用户 ——
///    这比宿主直接弹错误框体验好得多，也让模型有机会降级。
/// 3. **拆成可替换步骤。** 现在只开放工具注册，未来放开 harness 级（L7）时
///    不重构 —— 见 `AgentSteps` 与 [AgentLoop.stepOverrides]。
///
/// 这个类**不碰 WebView、不碰 Flutter**：插件调用通过注入的 [ToolInvoker] 完成。
/// 无头测试注入内存实现，Flutter 宿主注入 Bridge 实现，逻辑一模一样。
library;

import 'dart:convert';

import '../agent/chat_message.dart';
import '../audit/audit.dart';
import '../common/errors.dart';
import '../hook/hook_bus.dart';
import '../permission/gatekeeper.dart';
import '../primitive/host_services.dart';
import '../registry/tool_registry.dart';

/// 工具执行结果。
class ToolInvocationResult {
  const ToolInvocationResult.ok(this.result)
      : ok = true,
        errorCode = null,
        errorMessage = null;

  const ToolInvocationResult.failure(String this.errorCode, String this.errorMessage)
      : ok = false,
        result = null;

  final bool ok;
  final Object? result;
  final String? errorCode;
  final String? errorMessage;

  /// 转成给模型看的 JSON —— 失败也照样给，模型会自己处理。
  String toModelContent() => jsonEncode(ok
      ? <String, dynamic>{'ok': true, 'result': result}
      : <String, dynamic>{
          'ok': false,
          'error': <String, dynamic>{'code': errorCode, 'message': errorMessage},
        });
}

/// 调插件执行工具。
///
/// 由宿主注入：无头实现走内存闭包，Flutter 实现走 `BridgeSession.invoke('tool.invoke')`。
typedef ToolInvoker = Future<ToolInvocationResult> Function(
  String pluginId,
  String handler,
  Map<String, dynamic> args,
);

/// 一次工具调用的记录（用于断言、审计、UI 展示）。
class ToolInvocationRecord {
  const ToolInvocationRecord({
    required this.toolName,
    required this.pluginId,
    required this.ok,
    required this.durationMs,
    this.result,
    this.errorCode,
    this.errorMessage,
  });

  final String toolName;
  final String pluginId;
  final bool ok;
  final int durationMs;
  final Object? result;
  final String? errorCode;
  final String? errorMessage;

  @override
  String toString() =>
      'ToolInvocation($toolName @ $pluginId, ${ok ? "ok" : errorCode}, ${durationMs}ms)';
}

/// 一轮对话的结果。
class AgentTurnResult {
  const AgentTurnResult({
    required this.finalText,
    required this.steps,
    required this.toolInvocations,
    required this.hookFailures,
    this.reasoning,
    this.hitStepLimit = false,
  });

  final String finalText;

  /// 思维链（推理模型才有）。
  final String? reasoning;

  /// 模型调用轮数。
  final int steps;

  final List<ToolInvocationRecord> toolInvocations;

  /// 出错的钩子（**不中断对话**，只是被跳过）。
  final List<HookOutcome> hookFailures;

  final bool hitStepLimit;

  bool get usedTools => toolInvocations.isNotEmpty;

  @override
  String toString() =>
      'AgentTurnResult("$finalText", $steps 轮, ${toolInvocations.length} 次工具调用)';
}

/// 步骤 id —— 与 `docs/09-agent-and-tools.md` §3.2 的表格一一对应。
///
/// **新增步骤不需要改循环结构**：加一个常量、在合适位置 `_runStep` 即可。
abstract final class AgentSteps {
  /// 组装 person + skill + 历史。
  static const String contextBuild = 'context.build';

  /// 调模型前（钩子相位）。
  static const String beforeModel = 'pre.model';

  /// 发起模型请求。
  static const String modelCall = 'model.call';

  /// 模型返回后（钩子相位）。
  static const String afterModel = 'post.model';

  /// 校验权限并分发工具。
  static const String toolDispatch = 'tool.dispatch';

  /// 落库、发事件。
  static const String finish = 'finish';

  static const List<String> all = <String>[
    contextBuild,
    beforeModel,
    modelCall,
    afterModel,
    toolDispatch,
    finish,
  ];
}

/// 循环运行时可变的上下文。
class AgentRunContext {
  AgentRunContext({
    required this.sessionId,
    required this.systemPrompt,
    required List<ChatMessage> messages,
    Map<String, dynamic>? vars,
    this.onDelta,
  })  : messages = List<ChatMessage>.from(messages),
        // 必须是可变 map：循环会往里写 hitStepLimit 等标记。
        // 用 const {} 当默认值会在写的时候抛 "Cannot modify unmodifiable map"。
        vars = vars ?? <String, dynamic>{};

  final String sessionId;
  String systemPrompt;
  List<ChatMessage> messages;
  final Map<String, dynamic> vars;

  /// 流式增量回调（界面上"边收边显示"用）。为 null 表示不需要流式。
  final ModelDeltaCallback? onDelta;

  /// 当前轮次（从 1 开始）。
  int round = 0;

  /// 是否已结束。
  bool finished = false;

  ModelReply? reply;
  final List<ToolInvocationRecord> toolInvocations = <ToolInvocationRecord>[];
  final List<HookOutcome> hookFailures = <HookOutcome>[];
}

/// 一个可替换步骤。
///
/// **本阶段宿主不对外暴露它**（L7 预留）。内部用它把循环拆开，是为了未来
/// 放开 `registerStep` 时不必重写循环 —— 那时只需把 `stepOverrides` 暴露给插件。
abstract class AgentStep {
  String get id;

  /// 返回 false 表示"停止循环"（如模型已给出最终回答）。
  Future<bool> run(AgentRunContext ctx);
}

/// Agent 循环。
class AgentLoop {
  AgentLoop({
    required this.gatekeeper,
    required this.tools,
    required this.hooks,
    required this.gateway,
    required this.invokeTool,
    this.persona = '你是一个有用、简洁的助手。',
    this.maxSteps = 8,
    this.contextAssembler,
    this.streamingCall,
    AuditSink? audit,
    Map<String, AgentStep> stepOverrides = const <String, AgentStep>{},
  })  : audit = audit ?? const NullAuditSink(),
        _overrides = Map<String, AgentStep>.from(stepOverrides);

  final Gatekeeper gatekeeper;
  final ToolRegistry tools;
  final HookBus hooks;
  final ModelGateway gateway;
  final ToolInvoker invokeTool;
  final AuditSink audit;
  final String persona;

  /// 宿主注入的上下文组装源（插件通过 `context.inject` 写进去的东西）。
  ///
  /// 为 null 时不注入任何额外文本 —— 循环本身不关心注入是怎么存的。
  final ContextAssembler? contextAssembler;

  /// 宿主提供的流式调用能力。为 null 时退回 [ModelGateway.complete]。
  ///
  /// 有它界面上才能"边收边显示"；没有的话发出去之后要等整段回完才有动静，
  /// 而推理模型一次要 20–30 秒（实测）。
  final StreamingModelCall? streamingCall;

  /// **必须有上限。** 默认 8 轮。
  final int maxSteps;

  /// L7 预留：替换某个步骤。
  ///
  /// 现在只有宿主内部能填它。未来 `registerStep` 放开后，插件通过
  /// `harness.steps` 声明，宿主构造 AgentLoop 时把对应实现塞进来即可 ——
  /// 循环本身一行不改。
  Map<String, AgentStep> get stepOverrides => Map<String, AgentStep>.unmodifiable(_overrides);

  final Map<String, AgentStep> _overrides;

  /// 跑一轮。
  Future<AgentTurnResult> run({
    required String sessionId,
    required String userText,
    List<ChatMessage> history = const <ChatMessage>[],
    HookPhase donePhase = HookPhase.afterReply,
    ModelDeltaCallback? onDelta,
  }) async {
    final ctx = AgentRunContext(
      sessionId: sessionId,
      systemPrompt: persona,
      messages: <ChatMessage>[...history, ChatMessage.user(userText)],
      onDelta: onDelta,
    );

    await _runStep(AgentSteps.contextBuild, ctx);

    while (!ctx.finished && ctx.round < maxSteps) {
      ctx.round++;
      final shouldContinue = await _runStep(AgentSteps.modelCall, ctx);
      if (!shouldContinue || ctx.finished) break;
    }

    if (!ctx.finished) {
      // 撞上步数上限：把已有内容作为回复，并明确标注
      ctx.vars['hitStepLimit'] = true;
    }

    await _runStep(AgentSteps.finish, ctx);
    await hooks.emit(
      donePhase,
      HookContext(
        phase: donePhase,
        sessionId: sessionId,
        systemPrompt: ctx.systemPrompt,
        messages: ctx.messages,
        vars: <String, dynamic>{'reply': ctx.reply?.text ?? ''},
      ),
    );

    return AgentTurnResult(
      finalText: ctx.reply?.text ?? '',
      reasoning: ctx.reply?.reasoning,
      steps: ctx.round,
      toolInvocations: List<ToolInvocationRecord>.unmodifiable(ctx.toolInvocations),
      hookFailures: List<HookOutcome>.unmodifiable(ctx.hookFailures),
      hitStepLimit: ctx.vars['hitStepLimit'] == true,
    );
  }

  /// 执行一个步骤（优先用覆盖实现）。
  Future<bool> _runStep(String id, AgentRunContext ctx) async {
    final override = _overrides[id];
    if (override != null) return override.run(ctx);

    switch (id) {
      case AgentSteps.contextBuild:
        return _contextBuild(ctx);
      case AgentSteps.modelCall:
        return _modelCall(ctx);
      case AgentSteps.toolDispatch:
        return _toolDispatch(ctx);
      case AgentSteps.beforeModel:
      case AgentSteps.afterModel:
        return true; // 纯钩子相位，由 _modelCall 内部触发
      case AgentSteps.finish:
        return _finish(ctx);
      default:
        throw ArgumentError('未知的 Agent 步骤 "$id"');
    }
  }

  // ─────────────────────────── 步骤实现 ───────────────────────────

  Future<bool> _contextBuild(AgentRunContext ctx) async {
    final hookCtx = HookContext(
      phase: HookPhase.contextBuild,
      sessionId: ctx.sessionId,
      systemPrompt: ctx.systemPrompt,
      messages: ctx.messages,
    );
    final result = await hooks.emit(HookPhase.contextBuild, hookCtx);
    ctx.hookFailures.addAll(result.failures);

    // 插件注入的提示词 + 宿主注入的上下文一起进 system prompt。
    // 宿主完全不知道插件注入的内容是什么业务概念 —— 这是刻意的。
    ctx.systemPrompt = hookCtx.systemPrompt;
    ctx.messages = hookCtx.mutableMessages;

    final injection = contextAssembler?.buildInjection() ?? '';
    if (injection.trim().isNotEmpty) {
      ctx.systemPrompt = '${ctx.systemPrompt}\n\n$injection';
    }
    return true;
  }

  Future<bool> _modelCall(AgentRunContext ctx) async {
    // 钩子：调模型前
    final beforeCtx = HookContext(
      phase: HookPhase.beforeModel,
      sessionId: ctx.sessionId,
      systemPrompt: ctx.systemPrompt,
      messages: ctx.messages,
    );
    ctx.hookFailures.addAll((await hooks.emit(HookPhase.beforeModel, beforeCtx)).failures);

    // **人设为空时不注入 system 消息**，而不是塞一个空串或一句
    // "你是一个助手"。用户没设人设，就是想让模型用自己默认的行为 ——
    // 宿主替他写一句系统提示词，等于替他做了决定（见 docs/18 §6）。
    //
    // 注意：钩子有机会改 systemPrompt，所以判断要放在钩子之后。
    final systemPrompt = beforeCtx.systemPrompt.trim();
    final wire = <ChatMessage>[
      if (systemPrompt.isNotEmpty) ChatMessage.system(systemPrompt),
      ...beforeCtx.mutableMessages,
    ];

    final visibleTools = tools.toOpenAiTools(
      gatekeeper: gatekeeper,
      skillAllowList: null,
      userToggles: null,
    );

    // **宿主自己的模型调用也要写审计。**
    //
    // 这一条很容易漏：宿主的调用不经过 PrimitiveRegistry，于是很容易被当成
    // "内部操作"而不记账。但它是**真的在消耗用户的点数**的，
    // 漏了它，账单就无法与网关对账，出问题也查不到"钱花在哪一轮"。
    // 按 docs/06-permissions.md §8.3 的约定，宿主调用记 pluginId = '__host__'。
    final sw = Stopwatch()..start();
    final ModelReply reply;
    try {
      final request = ModelRequest(messages: wire, tools: visibleTools);

      // 有流式能力就走流式 —— 推理模型一次要 20–30 秒，
      // 非流式意味着用户对着静止的界面等半分钟。
      final streamer = streamingCall;
      final callback = ctx.onDelta;
      reply = (streamer != null && callback != null)
          ? await streamer(request, callback)
          : await gateway.complete(request);

      sw.stop();
      audit.write(AuditEntry(
        pluginId: '__host__',
        kind: 'model',
        primitive: 'model.chat',
        argsDigest: <String, dynamic>{
          'messageCount': wire.length,
          'toolCount': visibleTools.length,
          'stream': false,
        },
        result: 'ok',
        durationMs: sw.elapsedMilliseconds,
      ));
    } catch (e) {
      sw.stop();
      audit.write(AuditEntry(
        pluginId: '__host__',
        kind: 'model',
        primitive: 'model.chat',
        argsDigest: <String, dynamic>{'messageCount': wire.length},
        result: 'error',
        errorCode: e is TsukiroException ? errorCodeToString(e.code) : 'INTERNAL',
        durationMs: sw.elapsedMilliseconds,
      ));
      rethrow;
    }

    ctx.reply = reply;

    // 钩子：模型返回后
    final afterCtx = HookContext(
      phase: HookPhase.afterModel,
      sessionId: ctx.sessionId,
      systemPrompt: ctx.systemPrompt,
      messages: ctx.messages,
      vars: <String, dynamic>{'reply': reply.text, 'reasoning': reply.reasoning},
    );
    ctx.hookFailures.addAll((await hooks.emit(HookPhase.afterModel, afterCtx)).failures);

    if (!reply.hasToolCalls) {
      ctx.finished = true;
      return false;
    }

    // 把带工具调用的助手消息记进历史
    ctx.messages.add(ChatMessage(
      role: ChatRole.assistant,
      content: reply.text.isEmpty ? null : reply.text,
      toolCalls: reply.toolCalls,
    ));

    await _runStep(AgentSteps.toolDispatch, ctx);
    return true;
  }

  Future<bool> _toolDispatch(AgentRunContext ctx) async {
    final reply = ctx.reply;
    if (reply == null || !reply.hasToolCalls) return false;

    for (final call in reply.toolCalls) {
      final record = await dispatchTool(ctx.sessionId, call);
      ctx.toolInvocations.add(record);

      // 工具结果回填。**失败也回填** —— 模型会看到错误并自行组织语言。
      ctx.messages.add(ChatMessage.toolResult(
        toolCallId: call.id,
        content: record.ok
            ? jsonEncode(<String, dynamic>{'ok': true, 'result': record.result})
            : jsonEncode(<String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': record.errorCode,
                  'message': record.errorMessage,
                },
              }),
      ));
    }
    return true;
  }

  Future<bool> _finish(AgentRunContext ctx) async {
    audit.write(AuditEntry(
      pluginId: '__host__',
      kind: 'agent',
      primitive: 'agent.turn',
      argsDigest: <String, dynamic>{
        'sessionId': ctx.sessionId,
        'rounds': ctx.round,
        'toolCalls': ctx.toolInvocations.length,
        'promptTokens': ctx.reply?.promptTokens ?? 0,
        'completionTokens': ctx.reply?.completionTokens ?? 0,
      },
      result: ctx.vars['hitStepLimit'] == true ? 'error' : 'ok',
      errorCode: ctx.vars['hitStepLimit'] == true ? 'STEP_LIMIT' : null,
    ));
    return true;
  }

  // ─────────────────────────── 工具分发 ───────────────────────────

  /// 分发一次工具调用。
  ///
  /// **失败一律转成 [ToolInvocationRecord]，不抛异常** —— 让调用方
  ///（以及模型）能把失败当作正常结果处理。
  Future<ToolInvocationRecord> dispatchTool(String sessionId, ToolCall call) async {
    final sw = Stopwatch()..start();

    final tool = tools.lookup(call.name);
    if (tool == null) {
      sw.stop();
      return ToolInvocationRecord(
        toolName: call.name,
        pluginId: '',
        ok: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'UNKNOWN_TOOL',
        errorMessage: '宿主没有注册名为 "${call.name}" 的工具',
      );
    }

    // 钩子：工具执行前
    await hooks.emit(
      HookPhase.beforeToolCall,
      HookContext(
        phase: HookPhase.beforeToolCall,
        sessionId: sessionId,
        systemPrompt: '',
        messages: const <ChatMessage>[],
        vars: <String, dynamic>{'tool': call.name, 'args': call.arguments},
      ),
    );

    // 权限：工具级权限也要过守门人。**调度与钩子都不构成绕过权限的通道。**
    for (final permission in tool.permissions) {
      final gate = gatekeeper.check(tool.pluginId, permission);
      if (!gate.isAllowed) {
        sw.stop();
        return ToolInvocationRecord(
          toolName: call.name,
          pluginId: tool.pluginId,
          ok: false,
          durationMs: sw.elapsedMilliseconds,
          errorCode: errorCodeToString(gate.decision == GateDecision.confirmRequired
              ? TsukiroErrorCode.confirmRequired
              : TsukiroErrorCode.permissionDenied),
          errorMessage: '插件未获得 $permission 权限',
        );
      }
    }

    ToolInvocationResult outcome;
    try {
      outcome = await invokeTool(tool.pluginId, tool.handler, call.arguments);
    } on TsukiroException catch (e) {
      outcome = ToolInvocationResult.failure(errorCodeToString(e.code), e.message);
    } catch (e) {
      outcome = ToolInvocationResult.failure('PLUGIN_ERROR', '$e');
    }
    sw.stop();

    // 钩子：工具执行后
    await hooks.emit(
      HookPhase.afterToolCall,
      HookContext(
        phase: HookPhase.afterToolCall,
        sessionId: sessionId,
        systemPrompt: '',
        messages: const <ChatMessage>[],
        vars: <String, dynamic>{'tool': call.name, 'result': outcome.result},
      ),
    );

    return ToolInvocationRecord(
      toolName: call.name,
      pluginId: tool.pluginId,
      ok: outcome.ok,
      durationMs: sw.elapsedMilliseconds,
      result: outcome.result,
      errorCode: outcome.errorCode,
      errorMessage: outcome.errorMessage,
    );
  }
}
