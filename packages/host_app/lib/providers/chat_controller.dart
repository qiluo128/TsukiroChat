/// 聊天状态机。
///
/// 关键设计：**走 plugin_core 的 [AgentLoop]，不另起一套循环**。
/// 将来接入插件（工具调用、钩子、上下文注入）时，这个文件一行都不用改 ——
/// 只是 `tools` / `gatekeeper` 里开始有东西而已。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';

import '../data/database.dart';
import '../data/models.dart';
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

  /// 已经收到过正文（用于区分"在想"和"在说"）。
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

/// 本轮的工具调用记录，供界面显示"正在查时间…"这类状态。
final activeToolCallsProvider =
    StateProvider<List<String>>((ref) => const <String>[]);

/// 用户主动取消。
class _Cancelled implements Exception {
  const _Cancelled();
}

/// 聊天控制器。
class ChatController {
  ChatController(this._ref);

  final Ref _ref;

  bool _cancelled = false;

  /// 取消当前这一轮。
  ///
  /// 实现方式是在流式回调里抛异常 —— 那会取消 `await for` 的订阅，
  /// 从而真正断掉 HTTP 流，而不只是"界面上不显示了"。
  void cancel() => _cancelled = true;

  /// 发一条消息并等模型回完。
  Future<void> send({required String sessionId, required String text}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final repo = _ref.read(chatRepositoryProvider);
    final gateway = _ref.read(modelGatewayProvider);
    final persona = _ref.read(personaProvider);

    if (gateway == null) {
      throw StateError('还没有配置模型。请到「设置 → 模型」填写 Base URL 与 API Key。');
    }

    _cancelled = false;
    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(activeToolCallsProvider.notifier).state = const <String>[];

    // ── 落库：用户消息 ──
    final seq = await repo.nextSeq(sessionId);
    await repo.insertMessage(StoredChatMessage(
      id: newId('m'),
      sessionId: sessionId,
      role: ChatRole.user,
      content: trimmed,
      seq: seq,
      createdAt: DateTime.now(),
    ));

    // 第一条用户消息顺便当会话标题 —— 让会话列表有辨识度
    final session = await repo.getSession(sessionId);
    if (session != null && (session.title == '新对话' || session.title.trim().isEmpty)) {
      await repo.renameSession(sessionId, _titleFrom(trimmed));
    }

    // ── 落库：助手占位消息（status=streaming）──
    final assistantId = newId('m');
    await repo.insertMessage(StoredChatMessage(
      id: assistantId,
      sessionId: sessionId,
      role: ChatRole.assistant,
      status: MessageStatus.streaming,
      seq: seq + 1,
      createdAt: DateTime.now(),
    ));

    _ref.read(streamingBufferProvider.notifier).state =
        StreamingBuffer(messageId: assistantId);
    _ref.invalidate(messagesProvider(sessionId));

    // ── 组装历史 ──
    final history = await _buildHistory(repo, sessionId, excludeIds: <String>{assistantId});

    try {
      final loop = AgentLoop(
        gatekeeper: _ref.read(gatekeeperProvider),
        tools: _ref.read(toolRegistryProvider),
        hooks: _ref.read(hookBusProvider),
        gateway: gateway,
        // 插件运行时还没接 —— 有工具时会走到这里并如实报错，
        // 而不是假装成功
        invokeTool: (pluginId, handler, args) async => ToolInvocationResult.failure(
          'NO_RUNTIME',
          '插件运行时尚未接入（$pluginId 的 $handler）',
        ),
        persona: persona.systemPrompt,
        maxSteps: 4,
        streamingCall: gateway.completeStreamingForLoop,
      );

      final turn = await loop.run(
        sessionId: sessionId,
        userText: trimmed,
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
        await _finalize(repo, assistantId, sessionId,
            status: MessageStatus.cancelled,
            buffer: _ref.read(streamingBufferProvider));
        return;
      }

      // ── 定稿 ──
      final buffer = _ref.read(streamingBufferProvider);
      await repo.updateMessage(
        assistantId,
        content: turn.finalText.isEmpty ? (buffer?.text ?? '') : turn.finalText,
        reasoning: turn.reasoning ?? buffer?.reasoning,
        status: MessageStatus.done,
      );
      await repo.touchSession(sessionId);
    } on _Cancelled {
      await _finalize(repo, assistantId, sessionId,
          status: MessageStatus.cancelled,
          buffer: _ref.read(streamingBufferProvider));
    } on TsukiroException catch (e) {
      await _finalize(repo, assistantId, sessionId,
          status: MessageStatus.error,
          errorCode: errorCodeToString(e.code),
          buffer: _ref.read(streamingBufferProvider));
      rethrow;
    } catch (e) {
      await _finalize(repo, assistantId, sessionId,
          status: MessageStatus.error,
          errorCode: 'INTERNAL',
          buffer: _ref.read(streamingBufferProvider));
      rethrow;
    } finally {
      _ref.read(streamingBufferProvider.notifier).state = null;
      _ref.read(sendingProvider.notifier).state = false;
      _ref.read(activeToolCallsProvider.notifier).state = const <String>[];
      _ref.invalidate(messagesProvider(sessionId));
      _ref.invalidate(sessionListProvider);
    }
  }

  /// 把流式缓冲里的内容落库并定稿。
  ///
  /// 出错 / 被取消时**保留已经收到的部分** —— 用户看到半句话，
  /// 比看到一片空白更能理解发生了什么。
  Future<void> _finalize(
    ChatRepository repo,
    String messageId,
    String sessionId, {
    required MessageStatus status,
    String? errorCode,
    StreamingBuffer? buffer,
  }) async {
    await repo.updateMessage(
      messageId,
      content: buffer?.text ?? '',
      reasoning: buffer?.reasoning,
      status: status,
      errorCode: errorCode,
    );
    await repo.touchSession(sessionId);
  }

  /// 组装给模型的历史消息。
  ///
  /// 只带 `user` / `assistant` 且有内容的 —— `system` 由 AgentLoop 的 persona 提供，
  /// `tool` 结果属于上一轮的工具循环，不跨轮携带。
  Future<List<ChatMessage>> _buildHistory(
    ChatRepository repo,
    String sessionId, {
    Set<String> excludeIds = const <String>{},
  }) async {
    final all = await repo.listMessages(sessionId, limit: 60);
    final usable = all.where((m) {
      if (excludeIds.contains(m.id)) return false;
      if (m.status == MessageStatus.streaming) return false;
      if (m.role != ChatRole.user && m.role != ChatRole.assistant) return false;
      // 出错的助手消息不进历史 —— 否则模型会看到自己"上次说了半句话"
      if (m.status == MessageStatus.error) return false;
      return (m.content?.trim().isNotEmpty ?? false);
    }).toList();

    // 最后一条是刚插进去的这条用户消息，要排除（AgentLoop 会用 userText 再加一次）
    if (usable.isNotEmpty && usable.last.role == ChatRole.user) {
      usable.removeLast();
    }

    // 历史里的 assistant 消息带 tool_calls 但缺 tool 结果，会让部分上游 400。
    // 这一轮不接插件工具，所以剥掉 tool_calls 只留文本。
    return usable
        .map((m) => ChatMessage(role: m.role, content: m.content))
        .toList(growable: false);
  }

  static String _titleFrom(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 18 ? flat : '${flat.substring(0, 18)}…';
  }
}

final chatControllerProvider = Provider<ChatController>((ref) => ChatController(ref));

// ─────────────────────────── 插件基础设施（暂空） ───────────────────────────
//
// 现在还没有插件运行时，所以这三个是空的。但**它们必须是真实对象**而不是
// 在控制器里临时 new —— 插件系统接入时只往里注册，调用方一行不改。

final gatekeeperProvider = Provider<Gatekeeper>((ref) => Gatekeeper());

final toolRegistryProvider = Provider<ToolRegistry>((ref) => ToolRegistry());

final hookBusProvider = Provider<HookBus>((ref) {
  return HookBus(
    dispatcher: (registration, context) async {
      // 没有插件运行时 → 没有钩子可调。返回 null 表示"无改动"。
      debugPrint('[hook] ${registration.phase.name} 没有运行时，跳过');
      return null;
    },
  );
});
