/// Anthropic Messages API 适配器。
///
/// 与 OpenAI 的**关键差异**（不是换个路径那么简单）：
///   1. 鉴权走 `x-api-key` 头，且必须带 `anthropic-version`
///   2. **system prompt 是顶层字段**，不能塞进 messages
///   3. `max_tokens` 是**必填**
///   4. 工具定义用 `input_schema` 而不是 `parameters`
///   5. 工具调用在响应里是**内容块**（`content: [{type:'tool_use'}]`），
///      而不是 `message.tool_calls`
///   6. 工具结果要以 `role: 'user'` + `tool_result` 块回填，**不是** `role:'tool'`
///   7. 流式用命名事件（`content_block_delta`），`data:` 里带 `type`
library;

import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';

import '../adapter.dart';
import '../errors.dart';
import '../protocol.dart';
import '../sse.dart';
import '../transport.dart';

class AnthropicAdapter implements ProtocolAdapter {
  const AnthropicAdapter();

  @override
  ProviderProtocol get protocol => ProviderProtocol.anthropic;

  @override
  HttpRequestSpec buildChatRequest(
    ProviderConfig config,
    ModelRequest request, {
    required bool stream,
  }) {
    final model = request.model ?? config.defaultModel;
    if (model == null || model.isEmpty) {
      throw ModelGatewayException(
        '没有指定模型名',
        kind: ModelErrorKind.invalidRequest,
      );
    }

    // system 必须抽出来单独传
    final systemParts = <String>[];
    final messages = <Map<String, dynamic>>[];
    for (final m in request.messages) {
      switch (m.role) {
        case ChatRole.system:
          if (m.content != null) systemParts.add(m.content!);
        case ChatRole.tool:
          // Anthropic 用 user + tool_result 表达工具结果
          messages.add(<String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'tool_result',
                'tool_use_id': m.toolCallId,
                'content': m.content ?? '',
              },
            ],
          });
        case ChatRole.assistant:
          final blocks = <Map<String, dynamic>>[];
          if (m.content != null && m.content!.isNotEmpty) {
            blocks.add(<String, dynamic>{'type': 'text', 'text': m.content});
          }
          for (final call in m.toolCalls) {
            blocks.add(<String, dynamic>{
              'type': 'tool_use',
              'id': call.id,
              'name': call.name,
              'input': call.arguments,
            });
          }
          messages.add(<String, dynamic>{
            'role': 'assistant',
            'content': blocks.isEmpty ? (m.content ?? '') : blocks,
          });
        case ChatRole.user:
          messages.add(<String, dynamic>{'role': 'user', 'content': m.content ?? ''});
      }
    }

    final body = <String, dynamic>{
      'model': model,
      // Anthropic 的必填字段。没给就按协议默认值 —— 不传会直接 400。
      'max_tokens': request.maxTokens ?? 4096,
      'messages': messages,
      if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.tools.isNotEmpty) 'tools': request.tools.map(_toAnthropicTool).toList(),
      'stream': stream,
      ...request.extra,
    };

    return HttpRequestSpec(
      method: 'POST',
      url: '${config.normalizedBaseUrl}/messages',
      headers: _headers(config),
      body: jsonEncode(body),
      timeout: config.timeout,
    );
  }

  /// OpenAI 的 `{type:'function', function:{name,description,parameters}}`
  /// → Anthropic 的 `{name, description, input_schema}`。
  Map<String, dynamic> _toAnthropicTool(Map<String, dynamic> openAiTool) {
    final fn = openAiTool['function'];
    final fnMap = fn is Map ? fn : const <String, dynamic>{};
    return <String, dynamic>{
      'name': fnMap['name'],
      'description': fnMap['description'],
      'input_schema': fnMap['parameters'] ??
          <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    };
  }

  Map<String, String> _headers(ProviderConfig config) => <String, String>{
        'x-api-key': config.apiKey,
        'anthropic-version': config.anthropicVersion,
        'Content-Type': 'application/json',
        ...config.extraHeaders,
      };

  @override
  ModelReply parseChatResponse(ProviderConfig config, HttpResponseData response) {
    if (!response.isOk) {
      throw ModelGatewayException.fromHttp(
        describeHttpError(response),
        statusCode: response.statusCode,
      );
    }
    final json = response.tryJson();
    if (json == null) {
      throw ModelGatewayException('响应不是合法 JSON', kind: ModelErrorKind.badResponse);
    }

    final text = StringBuffer();
    final toolCalls = <ToolCall>[];

    final content = json['content'];
    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            text.write(block['text']?.toString() ?? '');
          case 'thinking':
            // Anthropic 的思维链也是内容块
            break;
          case 'tool_use':
            final input = block['input'];
            toolCalls.add(ToolCall(
              id: block['id']?.toString() ?? '',
              name: block['name']?.toString() ?? '',
              arguments: input is Map<String, dynamic> ? input : <String, dynamic>{},
            ));
        }
      }
    }

    final usage = json['usage'];
    final usageMap = usage is Map ? usage : const <String, dynamic>{};

    return ModelReply(
      text: text.toString(),
      toolCalls: toolCalls,
      promptTokens: _int(usageMap['input_tokens']),
      completionTokens: _int(usageMap['output_tokens']),
      finishReason: json['stop_reason']?.toString(),
    );
  }

  @override
  StreamDelta? parseStreamChunk(String data) {
    final json = tryDecodeJsonObject(data);
    if (json == null) return null;

    switch (json['type']) {
      case 'content_block_delta':
        final delta = json['delta'];
        final deltaMap = delta is Map ? delta : const <String, dynamic>{};
        if (deltaMap['type'] == 'text_delta') {
          return StreamDelta(content: deltaMap['text']?.toString());
        }
        if (deltaMap['type'] == 'thinking_delta') {
          return StreamDelta(reasoning: deltaMap['thinking']?.toString());
        }
        // 工具参数的 JSON 也是**分片**推送的
        if (deltaMap['type'] == 'input_json_delta') {
          return StreamDelta(
            toolCalls: <ToolCallDelta>[
              ToolCallDelta(
                index: _int(json['index']),
                argumentsChunk: deltaMap['partial_json']?.toString(),
              ),
            ],
          );
        }
        return null;

      case 'content_block_start':
        final block = json['content_block'];
        final blockMap = block is Map ? block : const <String, dynamic>{};
        if (blockMap['type'] == 'tool_use') {
          return StreamDelta(
            toolCalls: <ToolCallDelta>[
              ToolCallDelta(
                index: _int(json['index']),
                id: blockMap['id']?.toString(),
                name: blockMap['name']?.toString(),
              ),
            ],
          );
        }
        return null;

      case 'message_delta':
        final usage = json['usage'];
        final usageMap = usage is Map ? usage : const <String, dynamic>{};
        final delta = json['delta'];
        final deltaMap = delta is Map ? delta : const <String, dynamic>{};
        return StreamDelta(
          finishReason: deltaMap['stop_reason']?.toString(),
          completionTokens: usageMap.isEmpty ? null : _int(usageMap['output_tokens']),
        );

      case 'message_start':
        final message = json['message'];
        final msgMap = message is Map ? message : const <String, dynamic>{};
        final usage = msgMap['usage'];
        final usageMap = usage is Map ? usage : const <String, dynamic>{};
        return StreamDelta(promptTokens: _int(usageMap['input_tokens']));

      default:
        return null;
    }
  }

  @override
  HttpRequestSpec? buildListModelsRequest(ProviderConfig config) => HttpRequestSpec(
        method: 'GET',
        url: '${config.normalizedBaseUrl}/models',
        headers: _headers(config),
        timeout: const Duration(seconds: 30),
      );

  @override
  List<ModelInfo> parseModelList(ProviderConfig config, HttpResponseData response) {
    if (!response.isOk) {
      throw ModelGatewayException.fromHttp(
        describeHttpError(response),
        statusCode: response.statusCode,
      );
    }
    final json = response.tryJson();
    final raw = json?['data'] ?? json?['models'];
    if (raw is! List) {
      throw ModelGatewayException(
        '模型表结构不认得',
        kind: ModelErrorKind.badResponse,
      );
    }
    final out = <ModelInfo>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        final info = ModelInfo.fromOpenAi(item);
        if (info != null) out.add(info);
      }
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  @override
  String describeError(HttpResponseData response) => describeHttpError(response);

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}
