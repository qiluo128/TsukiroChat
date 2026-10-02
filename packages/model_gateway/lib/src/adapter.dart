/// 适配器接口与流式增量模型。
///
/// 三套协议只在**线格式**上不同；这个接口把它们归一，上层只见
/// `ModelRequest` / `ModelReply` / `StreamDelta`。
library;

import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';

import 'protocol.dart';
import 'transport.dart';

/// 流式增量。
///
/// 一次只能带一部分信息：文本 delta、思维链 delta、工具调用分片、或结尾的用量。
class StreamDelta {
  const StreamDelta({
    this.content,
    this.reasoning,
    this.toolCalls = const <ToolCallDelta>[],
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
    this.extra = const <String, dynamic>{},
  });

  /// 正文增量。
  final String? content;

  /// 思维链增量（推理模型）。
  final String? reasoning;

  /// 工具调用分片。
  final List<ToolCallDelta> toolCalls;

  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;

  /// 该 chunk 上的私有字段。
  final Map<String, dynamic> extra;

  bool get isEmpty =>
      (content == null || content!.isEmpty) &&
      (reasoning == null || reasoning!.isEmpty) &&
      toolCalls.isEmpty &&
      finishReason == null &&
      promptTokens == null &&
      completionTokens == null;
}

/// 工具调用的一个分片。
///
/// OpenAI 系的约定：`id` 与 `function.name` 只在**第一个**分片里出现，
/// `function.arguments` 是**被切开的 JSON 字符串**，要按 [index] 拼接后才能解析。
class ToolCallDelta {
  const ToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.argumentsChunk,
  });

  final int index;
  final String? id;
  final String? name;
  final String? argumentsChunk;
}

/// 把流式增量拼成最终回复。
///
/// **工具调用的 arguments 必须拼完再解析** —— 边收边 parse 一定失败，
/// 因为 JSON 被从任意位置切开了。
class StreamAccumulator {
  final StringBuffer _content = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final Map<int, _PartialToolCall> _tools = <int, _PartialToolCall>{};

  String? finishReason;
  int promptTokens = 0;
  int completionTokens = 0;
  final Map<String, dynamic> extra = <String, dynamic>{};

  /// 喂一个增量。
  void add(StreamDelta delta) {
    if (delta.content != null && delta.content!.isNotEmpty) {
      _content.write(delta.content);
    }
    if (delta.reasoning != null && delta.reasoning!.isNotEmpty) {
      _reasoning.write(delta.reasoning);
    }
    for (final t in delta.toolCalls) {
      final slot = _tools.putIfAbsent(t.index, () => _PartialToolCall(t.index));
      if (t.id != null && t.id!.isNotEmpty) slot.id = t.id;
      if (t.name != null && t.name!.isNotEmpty) slot.name = t.name;
      if (t.argumentsChunk != null) slot.arguments.write(t.argumentsChunk);
    }
    if (delta.finishReason != null) finishReason = delta.finishReason;
    if (delta.promptTokens != null) promptTokens = delta.promptTokens!;
    if (delta.completionTokens != null) completionTokens = delta.completionTokens!;
    extra.addAll(delta.extra);
  }

  /// 当前已收到的正文（供 UI 增量渲染）。
  String get partialText => _content.toString();

  /// 当前已收到的思维链。
  String get partialReasoning => _reasoning.toString();

  /// 收敛成最终回复。
  ///
  /// `arguments` 解析失败时**不抛异常**，而是给一个空的参数对象并记在 [extra] 里 ——
  /// 一个坏的工具调用不该让整轮对话崩掉，模型看到空参数会自己纠偏。
  ModelReply finish() {
    final toolCalls = <ToolCall>[];
    final sortedIndexes = _tools.keys.toList()..sort();

    for (final i in sortedIndexes) {
      final partial = _tools[i]!;
      final rawArgs = partial.arguments.toString();
      Map<String, dynamic> args;
      if (rawArgs.trim().isEmpty) {
        args = <String, dynamic>{};
      } else {
        try {
          final decoded = jsonDecode(rawArgs);
          args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
        } catch (_) {
          args = <String, dynamic>{};
          extra['badToolArguments'] = <String, dynamic>{
            'index': i,
            'name': partial.name,
            'raw': rawArgs.length > 200 ? '${rawArgs.substring(0, 200)}…' : rawArgs,
          };
        }
      }
      toolCalls.add(ToolCall(
        id: partial.id ?? 'call_${i}_${DateTime.now().microsecondsSinceEpoch}',
        name: partial.name ?? '',
        arguments: args,
      ));
    }

    return ModelReply(
      text: _content.toString(),
      reasoning: _reasoning.isEmpty ? null : _reasoning.toString(),
      toolCalls: toolCalls,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      finishReason: finishReason,
      extra: extra,
    );
  }

  void reset() {
    _content.clear();
    _reasoning.clear();
    _tools.clear();
    finishReason = null;
    promptTokens = 0;
    completionTokens = 0;
    extra.clear();
  }
}

class _PartialToolCall {
  _PartialToolCall(this.index);

  final int index;
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

/// 线协议适配器。
abstract class ProtocolAdapter {
  ProviderProtocol get protocol;

  /// 拼聊天请求。
  HttpRequestSpec buildChatRequest(
    ProviderConfig config,
    ModelRequest request, {
    required bool stream,
  });

  /// 解析非流式响应。
  ModelReply parseChatResponse(ProviderConfig config, HttpResponseData response);

  /// 解析一个 SSE 数据载荷为增量。返回 null 表示这个 chunk 无需处理
  /// （例如中转站的统计行、空 delta）。
  StreamDelta? parseStreamChunk(String data);

  /// 拼"拉模型表"的请求；协议不支持时返回 null。
  HttpRequestSpec? buildListModelsRequest(ProviderConfig config);

  /// 解析模型表响应。
  List<ModelInfo> parseModelList(ProviderConfig config, HttpResponseData response);

  /// 从错误响应里提取人话消息（各协议的字段不同）。
  String describeError(HttpResponseData response);
}

// ─────────────────────────── 共用工具 ───────────────────────────

/// 把上游错误响应变成可读消息。
///
/// 中转站的错误体格式五花八门：`{error:{message}}` / `{message}` / `{error:"..."}` /
/// 纯文本 HTML。逐个兜住，最后退回状态码 + 原文片段。
String describeHttpError(HttpResponseData response) {
  final json = response.tryJson();
  if (json != null) {
    final err = json['error'];
    if (err is Map) {
      final msg = err['message'] ?? err['msg'] ?? err['type'];
      if (msg != null) return msg.toString();
    }
    if (err is String && err.isNotEmpty) return err;
    for (final key in <String>['message', 'msg', 'detail', 'error_description']) {
      final v = json[key];
      if (v != null) return v.toString();
    }
  }
  final trimmed = response.body.trim();
  final snippet = trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed;
  return 'HTTP ${response.statusCode}${snippet.isEmpty ? '' : '：$snippet'}';
}
