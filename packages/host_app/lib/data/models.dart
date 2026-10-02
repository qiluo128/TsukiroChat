/// 数据模型。
///
/// 与 `docs/10-data-model.md` 对齐，但 Demo 阶段去掉了用不上的字段
/// （点数、向量检索、FTS）。表结构保留可扩展空间，后面加列不需要重建。
library;

import 'dart:math';

import 'package:plugin_core/plugin_core.dart';

/// 消息在本地库里的状态。
enum MessageStatus {
  /// 正在流式输出。
  streaming,

  /// 已完成。
  done,

  /// 出错（保留了已收到的部分内容）。
  error,

  /// 被用户取消。
  cancelled;

  static MessageStatus parse(String? raw) {
    for (final s in MessageStatus.values) {
      if (s.name == raw) return s;
    }
    return MessageStatus.done;
  }
}

/// 一个会话。
class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    this.personaId,
    this.model,
    required this.createdAt,
    required this.updatedAt,
    this.lastMessageAt,
    this.messageCount = 0,
    this.archived = false,
  });

  final String id;
  String title;
  String? personaId;
  String? model;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? lastMessageAt;
  int messageCount;
  bool archived;

  /// 列表页显示用的时间：优先最后一条消息的时间。
  DateTime get sortTime => lastMessageAt ?? updatedAt;
}

/// 一条消息。
class StoredChatMessage {
  StoredChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content,
    this.toolCalls = const <ToolCall>[],
    this.toolCallId,
    this.pluginId,
    this.status = MessageStatus.done,
    this.errorCode,
    required this.seq,
    required this.createdAt,
    this.tokensPrompt,
    this.tokensCompletion,
    this.reasoning,
    this.meta = const <String, dynamic>{},
  });

  final String id;
  final String sessionId;
  final ChatRole role;
  String? content;
  List<ToolCall> toolCalls;
  String? toolCallId;
  String? pluginId;
  MessageStatus status;
  String? errorCode;
  final int seq;
  final DateTime createdAt;
  int? tokensPrompt;
  int? tokensCompletion;
  String? reasoning;
  Map<String, dynamic> meta;

  bool get isUser => role == ChatRole.user;
  bool get isAssistant => role == ChatRole.assistant;
  bool get isStreaming => status == MessageStatus.streaming;

  /// 供 UI 判断"这条消息是不是空的占位"（流式刚开始，还没收到内容）。
  bool get isEmptyBody =>
      (content == null || content!.trim().isEmpty) && toolCalls.isEmpty;

  ChatMessage toChatMessage() => ChatMessage(
        role: role,
        content: content,
        toolCalls: toolCalls,
        toolCallId: toolCallId,
      );

  @override
  String toString() =>
      'StoredChatMessage(${role.name} #$seq, ${content?.length ?? 0} 字符, ${status.name})';
}

/// 生成 id。
///
/// 刻意不引 `uuid` 包：Demo 只需要"够用的唯一性"，而时间戳 + 随机后缀
/// 在单机单用户场景下足够，且**时间有序**（方便按 id 排序、便于调试时看顺序）。
/// 正式版要跨设备同步时再换 UUIDv7。
final Random _random = Random();
String newId([String prefix = '']) {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = _random.nextInt(0xFFFFFF).toRadixString(36).padLeft(5, '0');
  return prefix.isEmpty ? '$ts$rand' : '${prefix}_$ts$rand';
}
