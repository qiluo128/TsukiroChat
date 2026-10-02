/// HTTP 传输层 —— 抽成接口，让适配器可以在没有网络的情况下被测透。
///
/// 真实实现用 `dart:io` 的 `HttpClient`（零外部依赖）；
/// 测试用 `FakeTransport` 回放真实抓到的响应体。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一次 HTTP 请求。
class HttpRequestSpec {
  const HttpRequestSpec({
    required this.method,
    required this.url,
    this.headers = const <String, String>{},
    this.body,
    this.timeout = const Duration(seconds: 120),
  });

  final String method;
  final String url;
  final Map<String, String> headers;

  /// 已序列化的请求体（JSON 字符串）。
  final String? body;

  final Duration timeout;

  @override
  String toString() => '$method $url';
}

/// 一次 HTTP 响应。
class HttpResponseData {
  const HttpResponseData({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// 解析成 JSON 对象；失败返回 null（不抛，让调用方决定怎么报错）。
  Map<String, dynamic>? tryJson() {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'HttpResponseData($statusCode, ${body.length} bytes)';
}

/// 传输层接口。
abstract class HttpTransport {
  /// 发一个请求，拿到完整响应体。
  Future<HttpResponseData> send(HttpRequestSpec spec);

  /// 发一个流式请求，拿到**原始字节流**（用于 SSE）。
  ///
  /// 只抛出网络层错误；HTTP 状态码由调用方从 [StreamedResponse] 读。
  Future<StreamedResponse> sendStreaming(HttpRequestSpec spec);

  void close();
}

/// 流式响应。
class StreamedResponse {
  const StreamedResponse({
    required this.statusCode,
    required this.bytes,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final Stream<List<int>> bytes;
  final Map<String, String> headers;

  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// 非 2xx 时把 body 读成字符串，便于报错。
  Future<String> readAll() async {
    final chunks = <int>[];
    await for (final c in bytes) {
      chunks.addAll(c);
    }
    return utf8.decode(chunks, allowMalformed: true);
  }
}

/// 基于 `dart:io` 的真实实现。
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 20);
  }

  final HttpClient _client;

  @override
  Future<HttpResponseData> send(HttpRequestSpec spec) async {
    final request = await _open(spec);
    final response = await request.close().timeout(spec.timeout);
    final body = await response.transform(utf8.decoder).join();
    return HttpResponseData(
      statusCode: response.statusCode,
      body: body,
      headers: _headersOf(response),
    );
  }

  @override
  Future<StreamedResponse> sendStreaming(HttpRequestSpec spec) async {
    final request = await _open(spec);
    final response = await request.close().timeout(spec.timeout);
    return StreamedResponse(
      statusCode: response.statusCode,
      // 不在这里 join —— SSE 必须边收边用
      bytes: response,
      headers: _headersOf(response),
    );
  }

  Future<HttpClientRequest> _open(HttpRequestSpec spec) async {
    final uri = Uri.parse(spec.url);
    final request = await _client.openUrl(spec.method, uri).timeout(spec.timeout);
    spec.headers.forEach(request.headers.set);
    if (spec.body != null) {
      final payload = utf8.encode(spec.body!);
      request.contentLength = payload.length;
      request.add(payload);
    }
    return request;
  }

  Map<String, String> _headersOf(HttpClientResponse response) {
    final out = <String, String>{};
    response.headers.forEach((name, values) {
      out[name.toLowerCase()] = values.join(', ');
    });
    return out;
  }

  @override
  void close() => _client.close(force: true);
}
