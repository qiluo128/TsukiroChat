/// 模型网关实现 —— 把三套协议收敛成一个 [ModelGateway]。
///
/// 这是宿主 `model.chat` 原语的落地实现，也是 Agent 循环调模型的地方。
/// **上游凭据只在这里流转**，永远不会通过 Bridge 传给插件。
library;

import 'dart:async';
import 'dart:io';

import 'package:plugin_core/plugin_core.dart';

import 'adapter.dart';
import 'adapters/anthropic_adapter.dart';
import 'adapters/google_adapter.dart';
import 'adapters/openai_adapter.dart';
import 'errors.dart';
import 'protocol.dart';
import 'sse.dart';
import 'transport.dart';

/// 按协议选适配器。
ProtocolAdapter adapterFor(ProviderProtocol protocol) {
  switch (protocol) {
    case ProviderProtocol.openai:
      return const OpenAiAdapter();
    case ProviderProtocol.anthropic:
      return const AnthropicAdapter();
    case ProviderProtocol.google:
      return const GoogleAdapter();
  }
}

/// HTTP 模型网关。
class HttpModelGateway implements ModelGateway {
  HttpModelGateway({
    required this.config,
    HttpTransport? transport,
    ProtocolAdapter? adapter,
  })  : _transport = transport ?? IoHttpTransport(),
        _adapter = adapter ?? adapterFor(config.protocol);

  final ProviderConfig config;
  final HttpTransport _transport;
  final ProtocolAdapter _adapter;

  @override
  String get activeModel => config.defaultModel ?? '(未指定模型)';

  /// 暴露配置的打码形式，供设置页显示 —— **绝不暴露 apiKey 原文**。
  String get displayEndpoint => '${config.normalizedBaseUrl} (${config.maskedKey})';

  // ─────────────────────────── 非流式 ───────────────────────────

  @override
  Future<ModelReply> complete(ModelRequest request) async {
    final spec = _adapter.buildChatRequest(config, request, stream: false);
    final response = await _guard(() => _transport.send(spec));
    return _adapter.parseChatResponse(config, response);
  }

  // ─────────────────────────── 流式 ───────────────────────────

  /// 流式增量（含思维链与工具调用分片）。
  ///
  /// Agent 循环应该用这个，而不是 [stream] —— 后者只给纯文本，
  /// 拿不到工具调用。
  Stream<StreamDelta> streamDeltas(ModelRequest request) async* {
    final spec = _adapter.buildChatRequest(config, request, stream: true);

    final StreamedResponse response;
    try {
      response = await _transport.sendStreaming(spec);
    } on SocketException catch (e) {
      throw ModelGatewayException('连接失败：${e.message}', kind: ModelErrorKind.network);
    } on TimeoutException {
      throw ModelGatewayException('连接超时', kind: ModelErrorKind.timeout);
    } on HandshakeException catch (e) {
      throw ModelGatewayException('TLS 握手失败：${e.message}', kind: ModelErrorKind.network);
    }

    if (!response.isOk) {
      final body = await response.readAll();
      throw ModelGatewayException.fromHttp(
        describeHttpError(HttpResponseData(statusCode: response.statusCode, body: body)),
        statusCode: response.statusCode,
      );
    }

    await for (final data in sseDataEvents(response.bytes)) {
      final delta = _adapter.parseStreamChunk(data);
      if (delta != null) yield delta;
    }
  }

  /// 流式并收敛成完整回复（含工具调用）。
  ///
  /// 这是 Agent 循环要用的方法：既有流式体验，又能在结束时拿到 `tool_calls`。
  Future<ModelReply> completeStreaming(
    ModelRequest request, {
    void Function(StreamDelta delta)? onDelta,
  }) async {
    final accumulator = StreamAccumulator();
    await for (final delta in streamDeltas(request)) {
      accumulator.add(delta);
      onDelta?.call(delta);
    }
    return accumulator.finish();
  }

  /// `plugin_core.ModelGateway` 要求的纯文本流。
  @override
  Stream<String> stream(ModelRequest request) async* {
    await for (final delta in streamDeltas(request)) {
      final content = delta.content;
      if (content != null && content.isNotEmpty) yield content;
    }
  }

  // ─────────────────────────── 模型表 ───────────────────────────

  /// 拉取供应商支持的模型列表。
  ///
  /// 中转站的模型表是**动态的**（上游换模型、加路由都会变），
  /// 所以设置页应该能手动刷新，而不是把模型名写死在客户端。
  Future<List<ModelInfo>> listModels() async {
    final spec = _adapter.buildListModelsRequest(config);
    if (spec == null) {
      throw ModelGatewayException(
        '${config.protocol.name} 协议不支持拉取模型表',
        kind: ModelErrorKind.invalidRequest,
      );
    }
    final response = await _guard(() => _transport.send(spec));
    return _adapter.parseModelList(config, response);
  }

  /// 连通性 + 鉴权自检。
  ///
  /// 设置页的「测试连接」按钮用这个：不发对话请求，只拉模型表 ——
  /// **不消耗 token，也不花钱**。
  Future<ConnectionCheck> check() async {
    final sw = Stopwatch()..start();
    try {
      final models = await listModels();
      sw.stop();
      return ConnectionCheck(
        ok: true,
        modelCount: models.length,
        models: models,
        latency: sw.elapsed,
      );
    } on ModelGatewayException catch (e) {
      sw.stop();
      return ConnectionCheck(
        ok: false,
        errorMessage: e.message,
        errorKind: e.kind,
        latency: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return ConnectionCheck(ok: false, errorMessage: '$e', latency: sw.elapsed);
    }
  }

  /// 把底层异常统一成 [ModelGatewayException]。
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ModelGatewayException {
      rethrow;
    } on SocketException catch (e) {
      throw ModelGatewayException(
        '连接失败（${e.address?.address ?? "?"}:${e.port ?? "?"}）：${e.message}',
        kind: ModelErrorKind.network,
      );
    } on HandshakeException catch (e) {
      throw ModelGatewayException('TLS 握手失败：${e.message}', kind: ModelErrorKind.network);
    } on TimeoutException {
      throw ModelGatewayException('请求超时', kind: ModelErrorKind.timeout);
    } on FormatException catch (e) {
      throw ModelGatewayException('响应解析失败：${e.message}', kind: ModelErrorKind.badResponse);
    }
  }

  void close() => _transport.close();
}

/// 连接自检结果。
class ConnectionCheck {
  const ConnectionCheck({
    required this.ok,
    this.modelCount = 0,
    this.models = const <ModelInfo>[],
    this.errorMessage,
    this.errorKind,
    this.latency = Duration.zero,
  });

  final bool ok;
  final int modelCount;
  final List<ModelInfo> models;
  final String? errorMessage;
  final ModelErrorKind? errorKind;
  final Duration latency;

  @override
  String toString() => ok
      ? 'ConnectionCheck(ok, $modelCount 个模型, ${latency.inMilliseconds}ms)'
      : 'ConnectionCheck(FAILED: $errorMessage)';
}
