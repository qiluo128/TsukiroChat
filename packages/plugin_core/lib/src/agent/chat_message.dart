/// 对话消息模型。
///
/// 内核只需要这一个最小形状：宿主存库、Bridge 传递、钩子读写都基于它。
/// 人设、附件、富内容等属于宿主扩展，放在 [meta] 里，内核不解释。
library;

import 'dart:convert';

/// 消息角色。
enum ChatRole {
  system,
  user,
  assistant,
  tool;

  static ChatRole parse(String? raw) {
    for (final r in ChatRole.values) {
      if (r.name == raw) return r;
    }
    return ChatRole.user;
  }
}

/// 模型发起的一次工具调用（已解析）。
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;

  /// **已解析**的参数。Bridge 上传输的是 JSON 字符串（因为流式传输时是分片拼接的），
  /// 解析完成后再变成对象。
  final Map<String, dynamic> arguments;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': 'function',
        'function': <String, dynamic>{
          'name': name,
          // **必须是 JSON 字符串，不能是对象。**
          //
          // OpenAI 协议规定 `function.arguments` 是"被序列化后的 JSON 文本"。
          // 传对象在离线假网关下看不出问题，接真实 API 会直接 400：
          //   "expected a string, but got `{}` instead"
          //
          // 这个格式怪癖的根源是流式：参数是**按字符分片**推送的，
          // 所以线上表示只能是字符串。收端拼完再 parse（见 fromOpenAi）。
          'arguments': arguments.isEmpty ? '{}' : jsonEncode(arguments),
        },
      };

  static ToolCall fromOpenAi(Map<String, dynamic> json) {
    final fn = json['function'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final rawArgs = fn['arguments'];
    Map<String, dynamic> args;
    if (rawArgs is Map<String, dynamic>) {
      args = rawArgs;
    } else if (rawArgs is String && rawArgs.isNotEmpty) {
      // 分片拼接完成后才到这里；解析失败不应让整轮对话崩掉
      args = _tryParseJson(rawArgs) ?? <String, dynamic>{};
    } else {
      args = <String, dynamic>{};
    }
    return ToolCall(
      id: json['id']?.toString() ?? '',
      name: fn['name']?.toString() ?? '',
      arguments: args,
    );
  }

  static Map<String, dynamic>? _tryParseJson(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// 一条对话消息。
class ChatMessage {
  const ChatMessage({
    required this.role,
    this.content,
    this.toolCalls = const <ToolCall>[],
    this.toolCallId,
    this.name,
    this.meta = const <String, dynamic>{},
  });

  ChatMessage.system(String text) : this(role: ChatRole.system, content: text);
  ChatMessage.user(String text) : this(role: ChatRole.user, content: text);
  ChatMessage.assistant(String text) : this(role: ChatRole.assistant, content: text);

  /// 工具执行结果，回填给模型。
  ChatMessage.toolResult({
    required String toolCallId,
    required String content,
  }) : this(role: ChatRole.tool, content: content, toolCallId: toolCallId);

  final ChatRole role;
  final String? content;
  final List<ToolCall> toolCalls;
  final String? toolCallId;
  final String? name;

  /// 宿主与插件的扩展数据。内核不解译，只透传。
  ///
  /// 约定：插件的私有数据放在 `meta[pluginId][...]`，插件之间互不可见。
  final Map<String, dynamic> meta;

  /// 转成 OpenAI 兼容的消息对象（发给模型的形状）。
  Map<String, dynamic> toOpenAi() => <String, dynamic>{
        'role': role.name,
        if (content != null) 'content': content,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls.map((t) => t.toJson()).toList(growable: false),
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (name != null) 'name': name,
      };

  ChatMessage copyWith({
    ChatRole? role,
    String? content,
    List<ToolCall>? toolCalls,
    String? toolCallId,
    String? name,
    Map<String, dynamic>? meta,
  }) =>
      ChatMessage(
        role: role ?? this.role,
        content: content ?? this.content,
        toolCalls: toolCalls ?? this.toolCalls,
        toolCallId: toolCallId ?? this.toolCallId,
        name: name ?? this.name,
        meta: meta ?? this.meta,
      );

  @override
  String toString() =>
      'ChatMessage(${role.name}${content == null ? '' : ': ${_preview(content!)}'})';

  static String _preview(String s) =>
      s.length <= 30 ? s : '${s.substring(0, 30)}…';
}
