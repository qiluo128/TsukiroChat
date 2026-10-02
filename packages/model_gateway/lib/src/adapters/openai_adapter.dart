/// OpenAI 兼容协议适配器。
///
/// 覆盖：官方 OpenAI、Azure OpenAI（路径略有不同，走 `extraHeaders` + 自定义 base）、
/// 以及**绝大多数中转站**。我们实测的那家就是这套。
///
/// 线上格式（实测确认）：
/// - `POST {base}/chat/completions`
/// - `GET  {base}/models`
/// - 鉴权 `Authorization: Bearer <key>`
///
/// 推理模型（如 `deepseek-v4.1-flash`）会额外返回 `reasoning_content`，
/// 与 `content` **分开**推送。工具调用的 `arguments` 是**被切开的 JSON 字符串**，
/// 必须按 `index` 拼接后才能解析。
library;

import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';

import '../adapter.dart';
import '../errors.dart';
import '../protocol.dart';
import '../sse.dart';
import '../transport.dart';

class OpenAiAdapter implements ProtocolAdapter {
  const OpenAiAdapter();

  @override
  ProviderProtocol get protocol => ProviderProtocol.openai;

  // ─────────────────────────── 请求 ───────────────────────────

  @override
  HttpRequestSpec buildChatRequest(
    ProviderConfig config,
    ModelRequest request, {
    required bool stream,
  }) {
    final model = request.model ?? config.defaultModel;
    if (model == null || model.isEmpty) {
      throw ModelGatewayException(
        '没有指定模型名，且供应商配置里没有默认模型',
        kind: ModelErrorKind.invalidRequest,
      );
    }
    if (request.messages.isEmpty) {
      throw ModelGatewayException(
        'messages 不能为空',
        kind: ModelErrorKind.invalidRequest,
      );
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': request.messages.map((m) => m.toOpenAi()).toList(growable: false),
      if (request.tools.isNotEmpty) 'tools': request.tools,
      // 有工具时显式声明 auto：部分中转站不传这个字段就不启用工具
      if (request.tools.isNotEmpty) 'tool_choice': 'auto',
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
      'stream': stream,
      // 让服务端在流最后一个 chunk 带上 usage（OpenAI 官方需要显式要求）
      if (stream) 'stream_options': <String, dynamic>{'include_usage': true},
      ...request.extra,
    };

    return HttpRequestSpec(
      method: 'POST',
      url: '${config.normalizedBaseUrl}/chat/completions',
      headers: _headers(config, streaming: stream),
      body: jsonEncode(body),
      timeout: config.timeout,
    );
  }

  Map<String, String> _headers(ProviderConfig config, {bool streaming = false}) =>
      <String, String>{
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
        'Accept': streaming ? 'text/event-stream' : 'application/json',
        ...config.extraHeaders,
      };

  // ─────────────────────────── 非流式响应 ───────────────────────────

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
      throw ModelGatewayException(
        '响应不是合法 JSON：${_snippet(response.body)}',
        kind: ModelErrorKind.badResponse,
      );
    }

    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      // 有些中转站出错时也返回 200，错误藏在 body 里
      final err = json['error'];
      if (err != null) {
        throw ModelGatewayException(
          '上游返回错误：$err',
          kind: ModelErrorKind.upstream,
        );
      }
      throw ModelGatewayException(
        '响应里没有 choices：${_snippet(response.body)}',
        kind: ModelErrorKind.badResponse,
      );
    }

    final choice = choices.first;
    if (choice is! Map) {
      throw ModelGatewayException(
        'choices[0] 不是对象',
        kind: ModelErrorKind.badResponse,
      );
    }

    final message = choice['message'];
    final messageMap = message is Map ? message : const <String, dynamic>{};

    final content = messageMap['content']?.toString() ?? '';
    final reasoning = messageMap['reasoning_content']?.toString();

    final toolCalls = <ToolCall>[];
    final rawToolCalls = messageMap['tool_calls'];
    if (rawToolCalls is List) {
      for (final raw in rawToolCalls) {
        if (raw is Map<String, dynamic>) {
          final call = ToolCall.fromOpenAi(raw);
          if (call.name.isNotEmpty) toolCalls.add(call);
        }
      }
    }

    final usage = json['usage'];
    final usageMap = usage is Map ? usage : const <String, dynamic>{};

    return ModelReply(
      text: content,
      reasoning: (reasoning == null || reasoning.isEmpty) ? null : reasoning,
      toolCalls: toolCalls,
      promptTokens: _asInt(usageMap['prompt_tokens']),
      completionTokens: _asInt(usageMap['completion_tokens']),
      finishReason: choice['finish_reason']?.toString(),
      extra: _collectExtra(json),
    );
  }

  // ─────────────────────────── 流式响应 ───────────────────────────

  @override
  StreamDelta? parseStreamChunk(String data) {
    final json = tryDecodeJsonObject(data);
    if (json == null) return null;

    final usage = json['usage'];
    final usageMap = usage is Map ? usage : const <String, dynamic>{};

    final choices = json['choices'];
    // **实测确认**：最后一个 chunk 的 choices 是空数组，只带 usage。
    if (choices is! List || choices.isEmpty) {
      if (usageMap.isEmpty && json['error'] == null) return null;
      return StreamDelta(
        promptTokens: usageMap.isEmpty ? null : _asInt(usageMap['prompt_tokens']),
        completionTokens:
            usageMap.isEmpty ? null : _asInt(usageMap['completion_tokens']),
        extra: _collectExtra(json),
      );
    }

    final choice = choices.first;
    if (choice is! Map) return null;

    final delta = choice['delta'];
    final deltaMap = delta is Map ? delta : const <String, dynamic>{};

    final toolCallDeltas = <ToolCallDelta>[];
    final rawToolCalls = deltaMap['tool_calls'];
    if (rawToolCalls is List) {
      for (var i = 0; i < rawToolCalls.length; i++) {
        final raw = rawToolCalls[i];
        if (raw is! Map) continue;
        final fn = raw['function'];
        final fnMap = fn is Map ? fn : const <String, dynamic>{};
        toolCallDeltas.add(ToolCallDelta(
          index: _asInt(raw['index'], fallback: i),
          id: raw['id']?.toString(),
          name: fnMap['name']?.toString(),
          argumentsChunk: fnMap['arguments']?.toString(),
        ));
      }
    }

    final delta_ = StreamDelta(
      content: deltaMap['content']?.toString(),
      reasoning: deltaMap['reasoning_content']?.toString(),
      toolCalls: toolCallDeltas,
      finishReason: choice['finish_reason']?.toString(),
      promptTokens: usageMap.isEmpty ? null : _asInt(usageMap['prompt_tokens']),
      completionTokens:
          usageMap.isEmpty ? null : _asInt(usageMap['completion_tokens']),
      extra: _collectExtra(json),
    );

    return delta_.isEmpty ? null : delta_;
  }

  // ─────────────────────────── 模型表 ───────────────────────────

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
    if (json == null) {
      throw ModelGatewayException(
        '模型表响应不是合法 JSON：${_snippet(response.body)}',
        kind: ModelErrorKind.badResponse,
      );
    }

    // 主流是 {data:[...]}；有些中转站直接给数组，或包一层 {models:[...]}
    final raw = json['data'] ?? json['models'];
    final list = raw is List ? raw : (json.containsKey('id') ? <dynamic>[json] : null);
    if (list == null) {
      throw ModelGatewayException(
        '模型表结构不认得（既没有 data 也没有 models）：${_snippet(response.body)}',
        kind: ModelErrorKind.badResponse,
      );
    }

    final out = <ModelInfo>[];
    for (final item in list) {
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

  // ─────────────────────────── 内部 ───────────────────────────

  /// 收集中转站塞的私有字段。
  ///
  /// 实测那家在**流式最后一个 chunk** 里放了 `cost_cny` / `trace_id` /
  /// `reasoning_available` / `billing_pending`。这些对运营与排障有用，
  /// 在解析层丢掉就再也拿不回来了。
  static const Set<String> _standardKeys = <String>{
    'id', 'object', 'created', 'model', 'choices', 'usage', 'system_fingerprint',
    'service_tier', 'error',
  };

  static Map<String, dynamic> _collectExtra(Map<String, dynamic> json) {
    final extra = <String, dynamic>{};
    json.forEach((k, v) {
      if (!_standardKeys.contains(k)) extra[k] = v;
    });
    return extra;
  }

  static int _asInt(Object? v, {int fallback = 0}) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static String _snippet(String body) {
    final t = body.trim();
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }
}
