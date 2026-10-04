/// 聊天状态机。
///
/// 关键设计：**走 plugin_core 的 [AgentLoop]，不另起一套循环**。
/// 将来接入插件（工具调用、钩子、上下文注入）时，这个文件几乎不用改 ——
/// 只是 `tools` / `gatekeeper` 里开始有东西。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../services/utility_model.dart';
import 'app_providers.dart';

/// 流式输出中的临时缓冲。
///
/// **为什么不直接改数据库再刷新列表**：流式每秒几十个分片，
/// 每个分片都写库 + 重建整列表，滚动会卡。这里只让**当前那一个气泡**重建。
class StreamingBuffer {
  const StreamingBuffer({
    required this.messageId,
    this.text = '',
    this.reasoning = '',
  });

  final String messageId;
  final String text;
  final String? reasoning;

  bool get hasText => text.trim().isNotEmpty;

  /// 收到过思维链但还没正文 —— 推理模型的"思考中"阶段。
  bool get isThinkingOnly => !hasText && (reasoning?.isNotEmpty ?? false);

  StreamingBuffer append(String? content, String? reasoning) => StreamingBuffer(
        messageId: messageId,
        text: text + (content ?? ''),
        reasoning: (reasoning == null || reasoning.isEmpty)
            ? this.reasoning
            : '${this.reasoning ?? ''}$reasoning',
      );
}

/// 当前正在流式输出的消息。null = 没有在输出。
final streamingBufferProvider = StateProvider<StreamingBuffer?>((ref) => null);

/// 发送中的标记（含工具调用阶段 —— 那时还没有正文流）。
final sendingProvider = StateProvider<bool>((ref) => false);

/// 用户主动取消。
class _Cancelled implements Exception {
  const _Cancelled();
}

/// 聊天控制器。
class ChatController {
  ChatController(this._ref);

  final Ref _ref;
  bool _cancelled = false;

  /// 是否有一轮正在跑。**不用 provider 读** —— 那是异步的，
  /// 两次快速点击可能都读到 false。
  bool _sending = false;

  /// 取消当前这一轮。
  ///
  /// 实现方式是在流式回调里抛异常 —— 那会取消 `await for` 的订阅，
  /// 从而**真正断掉 HTTP 流**，而不只是"界面上不显示了"。
  void cancel() => _cancelled = true;

  /// 发一条消息并等模型回完。
  ///
  /// 同一时间只允许一轮。重复调用会抛 [StateError] —— 界面上表现为
  /// 「已有一轮对话正在发送，请先等待或取消」。
  Future<void> send({required String conversationId, required String text}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // ── 并发保护 ──
    // 拦在这里而不是靠界面禁用按钮：工具调用期间没有正文流，
    // 按钮状态和真实状态会脱节，只有控制器自己知道有没有在跑。
    if (_sending) {
      throw StateError('已有一轮对话正在发送');
    }
    _sending = true;

    try {
      await _send(conversationId: conversationId, text: trimmed);
    } finally {
      _sending = false;
    }
  }

  Future<void> _send({required String conversationId, required String text}) async {
    final repos = await _ref.read(reposProvider.future);

    // ── 解析这轮要用的人设与模型 ──
    final conversation = await repos.conversations.get(conversationId);
    if (conversation == null) {
      throw StateError('对话不存在（可能已被删除）');
    }
    final agent = await repos.agents.get(conversation.agentId);
    if (agent == null) {
      throw StateError('这个对话所属的智能体已被删除');
    }

    final gateway = _ref.read(gatewayForAgentProvider(agent.id));
    if (gateway == null) {
      throw StateError('还没有可用的模型。请到「设置 → 模型配置 → 配置 API」添加服务商。');
    }

    _cancelled = false;
    _ref.read(sendingProvider.notifier).state = true;

    // ── 落库：用户消息 + 助手占位，**一个事务里做完** ──
    // 分两次插入的话，进程在中间被杀会留下一条永远等不到回复的用户消息。
    final turn = await repos.messages.prepareTurn(conversationId, userText: text);
    final assistantId = turn.assistantMessageId;

    _ref.read(streamingBufferProvider.notifier).state =
        StreamingBuffer(messageId: assistantId);
    _ref.invalidate(messagesProvider(conversationId));

    final history =
        await _buildHistory(repos, conversationId, excludeIds: <String>{assistantId});

    try {
      final loop = AgentLoop(
        gatekeeper: _ref.read(gatekeeperProvider),
        tools: _ref.read(toolRegistryProvider),
        hooks: _ref.read(hookBusProvider),
        gateway: gateway,
        // 插件运行时还没接 —— 有工具时会走到这里并**如实报错**，而不是假装成功
        invokeTool: (pluginId, handler, args) async => ToolInvocationResult.failure(
          'NO_RUNTIME',
          '插件运行时尚未接入（$pluginId 的 $handler）',
        ),
        // 人设可能为空 —— AgentLoop 在空串时**不注入 system 消息**，
        // 而不是替用户塞一句"你是一个助手"（见 docs/18 §6）
        persona: agent.persona.buildSystemPrompt(),
        maxSteps: 4,
        streamingCall: gateway.completeStreamingForLoop,
      );

      final turn = await loop.run(
        sessionId: conversationId,
        userText: text,
        history: history,
        onDelta: (content, reasoning) {
          if (_cancelled) throw const _Cancelled();
          final current = _ref.read(streamingBufferProvider);
          if (current == null) return;
          _ref.read(streamingBufferProvider.notifier).state =
              current.append(content, reasoning);
        },
      );

      if (_cancelled) {
        await _finalize(repos, assistantId, conversationId,
            status: MessageStatus.cancelled,
            buffer: _ref.read(streamingBufferProvider));
        return;
      }

      // ── 定稿 ──
      final buffer = _ref.read(streamingBufferProvider);
      final finalText = turn.finalText.isEmpty ? (buffer?.text ?? '') : turn.finalText;
      await repos.messages.update(
        assistantId,
        content: finalText,
        reasoning: turn.reasoning ?? buffer?.reasoning,
        status: MessageStatus.done,
      );
      await repos.conversations.touch(conversationId);

      // ── 用工具模型生成一个更好的标题 ──
      // 放在定稿之后：标题生成慢也不该拖住这条回复的显示。
      await _maybeGenerateTitle(repos, conversationId, text, finalText);
    } on _Cancelled {
      await _finalize(repos, assistantId, conversationId,
          status: MessageStatus.cancelled,
          buffer: _ref.read(streamingBufferProvider));
    } on TsukiroException catch (e) {
      await _finalize(repos, assistantId, conversationId,
          status: MessageStatus.error,
          errorCode: errorCodeToString(e.code),
          buffer: _ref.read(streamingBufferProvider));
      rethrow;
    } catch (e) {
      await _finalize(repos, assistantId, conversationId,
          status: MessageStatus.error,
          errorCode: 'INTERNAL',
          buffer: _ref.read(streamingBufferProvider));
      rethrow;
    } finally {
      _ref.read(streamingBufferProvider.notifier).state = null;
      _ref.read(sendingProvider.notifier).state = false;
      _ref.invalidate(messagesProvider(conversationId));
    }
  }

  /// 把流式缓冲里的内容落库并定稿。
  ///
  /// 出错 / 被取消时**保留已经收到的部分** —— 用户看到半句话，
  /// 比看到一片空白更能理解发生了什么。
  Future<void> _finalize(
    Repos repos,
    String messageId,
    String conversationId, {
    required MessageStatus status,
    String? errorCode,
    StreamingBuffer? buffer,
  }) async {
    await repos.messages.update(
      messageId,
      content: buffer?.text ?? '',
      reasoning: buffer?.reasoning,
      status: status,
      errorCode: errorCode,
    );
    await repos.conversations.touch(conversationId);
  }

  /// 用工具模型给对话起个更好的标题。
  ///
  /// **只在第一轮之后做一次**。判断方式是「对话里正好两条消息」——
  /// 这样不需要额外存一个「已生成」标记，也不会在后续轮次反复改名。
  ///
  /// 失败**完全静默**：`prepareTurn` 已经把用户第一句当占位标题了，
  /// 生成不出来就保持那个，用户不会有任何感知。
  Future<void> _maybeGenerateTitle(
    Repos repos,
    String conversationId,
    String userText,
    String assistantText,
  ) async {
    final service = _ref.read(utilityModelServiceProvider);
    if (!service.isAvailable) return;

    final conversation = await repos.conversations.get(conversationId);
    if (conversation == null || conversation.messageCount != 2) return;

    final title = await service.generateTitle(
      userText: userText,
      assistantText: assistantText,
    );
    if (title == null || title.trim().isEmpty) return;
    if (title == conversation.title) return;

    await repos.conversations.rename(conversationId, title);
    _ref.invalidate(conversationProvider(conversationId));
    _ref.invalidate(conversationListProvider);
  }

  /// 组装给模型的历史消息。
  ///
  /// 只带 `user` / `assistant` 且有内容的：`system` 由 AgentLoop 的 persona 提供，
  /// `tool` 结果属于上一轮的工具循环，不跨轮携带。
  Future<List<ChatMessage>> _buildHistory(
    Repos repos,
    String conversationId, {
    Set<String> excludeIds = const <String>{},
  }) async {
    final all = await repos.messages.list(conversationId, limit: 60);
    final usable = all.where((m) {
      if (excludeIds.contains(m.id)) return false;
      if (m.status == MessageStatus.streaming) return false;
      if (m.role != ChatRole.user && m.role != ChatRole.assistant) return false;
      // 出错的助手消息不进历史 —— 否则模型会看到自己"上次说了半句话"
      if (m.status == MessageStatus.error) return false;
      return m.content?.trim().isNotEmpty ?? false;
    }).toList();

    // 最后一条是刚插进去的这条用户消息，要排除（AgentLoop 会用 userText 再加一次）
    if (usable.isNotEmpty && usable.last.role == ChatRole.user) {
      usable.removeLast();
    }

    // 这一轮不接插件工具，所以剥掉 tool_calls 只留文本 ——
    // 带 tool_calls 但没有对应 tool 结果的助手消息会让部分上游 400。
    return usable
        .map((m) => ChatMessage(role: m.role, content: m.content))
        .toList(growable: false);
  }
}

/// 全局单例。
///
/// 控制器持有 [_sending] 这类跨帧状态，所以**必须是单例** ——
/// 每次 read 都 new 一个的话，并发保护就形同虚设。
final chatControllerProvider = Provider<ChatController>((ref) => ChatController(ref));
