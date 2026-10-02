/// Google Gemini（Generative Language API）适配器。
///
/// 与 OpenAI 的**关键差异**：
///   1. 模型名在**路径**里：`POST {base}/models/{model}:generateContent`
///   2. 鉴权走 `?key=` 查询参数（也支持 `x-goog-api-key` 头）
///   3. 对话是 `contents: [{role:'user'|'model', parts:[...]}]` —— 角色只有两种
///   4. system prompt 用 `systemInstruction`
///   5. 工具定义包在 `tools[].functionDeclarations[]` 里
///   6. 工具调用是 `parts[].functionCall`，**没有 id**（要自己造一个）
///   7. 工具结果回填用 `functionResponse`，同样 `role:'user'`
///   8. 流式用 `alt=sse`
library;

import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';

import '../adapter.dart';
import '../errors.dart';
import '../protocol.dart';
import '../sse.dart';
import '../transport.dart';

class GoogleAdapter implements ProtocolAdapter {
  const GoogleAdapter();

  @override
  ProviderProtocol get protocol => ProviderProtocol.google;

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

    final systemParts = <String>[];
    final contents = <Map<String, dynamic>>[];

    for (final m in request.messages) {
      switch (m.role) {
        case ChatRole.system:
          if (m.content != null) systemParts.add(m.content!);

        case ChatRole.tool:
          contents.add(<String, dynamic>{
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{
                'functionResponse': <String, dynamic>{
                  'name': _toolNameFor(m.toolCallId),
                  'response': <String, dynamic>{'result': m.content ?? ''},
                },
              },
            ],
          });

        case ChatRole.assistant:
          final parts = <Map<String, dynamic>>[];
          if (m.content != null && m.content!.isNotEmpty) {
            parts.add(<String, dynamic>{'text': m.content});
          }
          for (final call in m.toolCalls) {
            parts.add(<String, dynamic>{
              'functionCall': <String, dynamic>{
                'name': call.name,
                'args': call.arguments,
              },
            });
          }
          if (parts.isNotEmpty) {
            contents.add(<String, dynamic>{'role': 'model', 'parts': parts});
          }

        case ChatRole.user:
          contents.add(<String, dynamic>{
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'text': m.content ?? ''},
            ],
          });
      }
    }

    final body = <String, dynamic>{
      'contents': contents,
      if (systemParts.isNotEmpty)
        'systemInstruction': <String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{'text': systemParts.join('\n\n')},
          ],
        },
      if (request.tools.isNotEmpty)
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'functionDeclarations':
                request.tools.map(_toGoogleTool).toList(growable: false),
          },
        ],
      if (request.temperature != null || request.maxTokens != null)
        'generationConfig': <String, dynamic>{
          if (request.temperature != null) 'temperature': request.temperature,
          if (request.maxTokens != null) 'maxOutputTokens': request.maxTokens,
        },
      ...request.extra,
    };

    final method = stream ? 'streamGenerateContent' : 'generateContent';
    final query = <String, String>{
      'key': config.apiKey,
      if (stream) 'alt': 'sse',
    };
    final uri = Uri.parse('${config.normalizedBaseUrl}/models/$model:$method')
        .replace(queryParameters: query);

    return HttpRequestSpec(
      method: 'POST',
      url: uri.toString(),
      headers: <String, dynamic>{
        'Content-Type': 'application/json',
        ...config.extraHeaders,
      }.cast<String, String>(),
      body: jsonEncode(body),
      timeout: config.timeout,
    );
  }

  Map<String, dynamic> _toGoogleTool(Map<String, dynamic> openAiTool) {
    final fn = openAiTool['function'];
    final fnMap = fn is Map ? fn : const <String, dynamic>{};
    return <String, dynamic>{
      'name': fnMap['name'],
      'description': fnMap['description'],
      'parameters': fnMap['parameters'] ??
          <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    };
  }

  /// Gemini 的 functionResponse 只认**函数名**，不认 id。
  ///
  /// 我们在 [ToolCall.id] 里塞了 `name::<n>` 作为变通（见 [_toolIdFor]），
  /// 这里解析回来。这是 Gemini 协议本身的限制，不是我们的设计选择。
  String _toolNameFor(String? toolCallId) {
    if (toolCallId == null) return '';
    final idx = toolCallId.indexOf('::');
    return idx < 0 ? toolCallId : toolCallId.substring(0, idx);
  }

  static String _toolIdFor(String name, int index) => '$name::$index';

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

    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw ModelGatewayException(
        '响应里没有 candidates（可能是安全策略拦截）：${json['promptFeedback'] ?? ""}',
        kind: ModelErrorKind.badResponse,
      );
    }

    final parsed = _parseParts(candidates.first);
    final usage = json['usageMetadata'];
    final usageMap = usage is Map ? usage : const <String, dynamic>{};

    return ModelReply(
      text: parsed.text,
      toolCalls: parsed.toolCalls,
      promptTokens: _int(usageMap['promptTokenCount']),
      completionTokens: _int(usageMap['candidatesTokenCount']),
      finishReason: parsed.finishReason,
    );
  }

  _ParsedParts _parseParts(Object? candidate) {
    if (candidate is! Map) return const _ParsedParts(text: '', toolCalls: <ToolCall>[]);
    final content = candidate['content'];
    final contentMap = content is Map ? content : const <String, dynamic>{};
    final parts = contentMap['parts'];
    if (parts is! List) {
      return _ParsedParts(
        text: '',
        toolCalls: const <ToolCall>[],
        finishReason: candidate['finishReason']?.toString(),
      );
    }

    final text = StringBuffer();
    final toolCalls = <ToolCall>[];
    var index = 0;

    for (final part in parts) {
      if (part is! Map) continue;
      if (part['text'] != null) text.write(part['text']);
      final fc = part['functionCall'];
      if (fc is Map) {
        final args = fc['args'];
        final name = fc['name']?.toString() ?? '';
        toolCalls.add(ToolCall(
          // Gemini 不给 id，自己造一个，并把函数名编进去以便回填时能还原
          id: _toolIdFor(name, index++),
          name: name,
          arguments: args is Map<String, dynamic> ? args : <String, dynamic>{},
        ));
      }
    }

    return _ParsedParts(
      text: text.toString(),
      toolCalls: toolCalls,
      finishReason: candidate['finishReason']?.toString(),
    );
  }

  @override
  StreamDelta? parseStreamChunk(String data) {
    final json = tryDecodeJsonObject(data);
    if (json == null) return null;

    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      final usage = json['usageMetadata'];
      final usageMap = usage is Map ? usage : const <String, dynamic>{};
      if (usageMap.isEmpty) return null;
      return StreamDelta(
        promptTokens: _int(usageMap['promptTokenCount']),
        completionTokens: _int(usageMap['candidatesTokenCount']),
      );
    }

    final parsed = _parseParts(candidates.first);
    final usage = json['usageMetadata'];
    final usageMap = usage is Map ? usage : const <String, dynamic>{};

    return StreamDelta(
      content: parsed.text.isEmpty ? null : parsed.text,
      toolCalls: parsed.toolCalls
          .asMap()
          .entries
          .map((e) => ToolCallDelta(
                index: e.key,
                id: e.value.id,
                name: e.value.name,
                argumentsChunk: jsonEncode(e.value.arguments),
              ))
          .toList(growable: false),
      finishReason: parsed.finishReason,
      promptTokens: usageMap.isEmpty ? null : _int(usageMap['promptTokenCount']),
      completionTokens:
          usageMap.isEmpty ? null : _int(usageMap['candidatesTokenCount']),
    );
  }

  @override
  HttpRequestSpec? buildListModelsRequest(ProviderConfig config) {
    final uri = Uri.parse('${config.normalizedBaseUrl}/models')
        .replace(queryParameters: <String, String>{'key': config.apiKey});
    return HttpRequestSpec(
      method: 'GET',
      url: uri.toString(),
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  List<ModelInfo> parseModelList(ProviderConfig config, HttpResponseData response) {
    if (!response.isOk) {
      throw ModelGatewayException.fromHttp(
        describeHttpError(response),
        statusCode: response.statusCode,
      );
    }
    final json = response.tryJson();
    final raw = json?['models'];
    if (raw is! List) {
      throw ModelGatewayException('模型表结构不认得', kind: ModelErrorKind.badResponse);
    }
    final out = <ModelInfo>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        final info = ModelInfo.fromGoogle(item);
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

class _ParsedParts {
  const _ParsedParts({required this.text, required this.toolCalls, this.finishReason});

  final String text;
  final List<ToolCall> toolCalls;
  final String? finishReason;
}
