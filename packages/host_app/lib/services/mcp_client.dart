/// MCP Client（HTTP / JSON-RPC）。
///
/// ## 范围
///
/// 只做**方向 A**：Tsukiro 接入外部 MCP server。
/// 不做方向 B（把我们的插件暴露出去）—— 那需要别的设备连手机，场景窄。
///
/// 只支持 **HTTP** 传输。stdio 需要子进程，也就是需要命令执行能力，
/// 而我们不做命令执行 —— 所以 Android 上的 MCP 是「连远程」，不是「跑本地」。
///
/// ## 为什么不做能力门禁
///
/// 见 `docs/25-mcp.md` §6。一句话：我们的权限体系保护的全是**宿主资源**，
/// 而 MCP server 在它自己服务器上做什么，我们批不批准都改变不了。
///
/// 我们能管的是「**发给它什么**」，那靠连接时告知 + 调用审计，不靠门禁。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 把可能出现在文本里的密钥擦掉。
///
/// **这不是"美化错误"。** 我们的原则是错误原文照显示 ——
/// 但原文里可能回显了鉴权头或 token。
///
/// **不美化 ≠ 泄漏。** 这两件事必须同时成立。
///
/// 实现上用 replaceAllMapped 而不是 replaceAll：后者的替换串是
/// **字面量**，不认分组引用（我第一版就这么写错了，输出里留下字面 $1）。
String redactSecrets(String text) {
  var out = text;

  // Bearer <token>
  out = out.replaceAllMapped(
    RegExp(r'(Bearer\s+)[A-Za-z0-9\-._~+/]{6,}=*'),
    (m) => m[1]! + '***',
  );

  // sk-xxxx（我们的模型 key 长这样），保留前 4 位以便辨认是哪个 key
  out = out.replaceAllMapped(
    RegExp(r'(sk-[A-Za-z0-9]{4})[A-Za-z0-9\-_]*'),
    (m) => m[1]! + '***',
  );

  // Authorization: xxx / "authorization":"xxx"
  out = out.replaceAllMapped(
    RegExp(r'([Aa]uthorization["\s:=]+)[^"\s,}]{6,}'),
    (m) => m[1]! + '***',
  );

  // token=xxx / "api_key": "xxx" / secret: xxx（允许出现在行首）
  out = out.replaceAllMapped(
    RegExp(
        r'(^|["\s,])((?:token|api_?key|secret|password)["\s:=]+)[A-Za-z0-9\-._~+/]{8,}'),
    (m) => m[1]! + m[2]! + '***',
  );

  return out;
}
class McpTool {
  const McpTool({
    required this.name,
    this.description = '',
    this.inputSchema = const <String, dynamic>{},
  });

  final String name;
  final String description;

  /// JSON Schema。原样带回，注册进工具表时直接当 `parameters` 用。
  final Map<String, dynamic> inputSchema;

  static McpTool? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    if (name is! String || name.isEmpty) return null;
    return McpTool(
      name: name,
      description: j['description'] as String? ?? '',
      inputSchema: (j['inputSchema'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    );
  }
}

class McpServerInfo {
  const McpServerInfo({
    this.name = '',
    this.version = '',
    this.protocolVersion = '',
  });

  final String name;
  final String version;
  final String protocolVersion;
}

/// 一次工具调用的结果。
///
/// MCP 的 `content` 是一个数组（可能是 text / image / resource），
/// 这里只取其中的文本部分 —— 图片和资源暂时不往模型传
/// （桥接有 1MB 上限，而 base64 图片很容易超）。
class McpCallResult {
  const McpCallResult({
    required this.text,
    this.json,
    this.isError = false,
  });

  /// 原始文本（多个 content 项用换行拼接）。
  final String text;

  /// **解包后的结构化结果。**
  ///
  /// 很多 MCP server 把工具结果塞在一个 JSON 字符串里：
  ///   content: [{type: "text", text: "{\"ok\":true,...}"}]
  /// 原样给模型的话，它拿到的是**字符串**，得自己再解析一次 ——
  /// 而且字符串里的 isError 我们看不到，外层就报了 ok:true。
  ///
  /// 能整体解析成 JSON 时放这里；null 表示就是纯文本。
  final Object? json;

  /// MCP 层是否报错。**解包后会再看一次里面的 isError。**
  final bool isError;
}

class McpException implements Exception {
  McpException(String message, {this.code}) : message = redactSecrets(message);

  final String message;
  final int? code;

  @override
  String toString() => code == null ? message : '[$code] $message';
}

class McpClient {
  McpClient({
    required this.url,
    Map<String, String> headers = const <String, String>{},
    this.initializeTimeout = const Duration(seconds: 10),
    this.callTimeout = const Duration(seconds: 60),
  }) : headers = headers;

  final String url;
  final Map<String, String> headers;
  final Duration initializeTimeout;
  final Duration callTimeout;

  int _nextId = 1;
  String? _sessionId;

  McpServerInfo _info = const McpServerInfo();
  McpServerInfo get info => _info;

  /// 握手。成功后 server 信息可读。
  Future<McpServerInfo> initialize() async {
    final result = await _request('initialize', <String, dynamic>{
      'protocolVersion': '2024-11-05',
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{
        'name': 'TsukiroChat',
        'version': '1',
      },
    }, timeout: initializeTimeout);

    final serverInfo = (result['serverInfo'] as Map?)?.cast<String, dynamic>();
    _info = McpServerInfo(
      name: serverInfo?['name'] as String? ?? '',
      version: serverInfo?['version'] as String? ?? '',
      protocolVersion: result['protocolVersion'] as String? ?? '',
    );

    // 协议要求握手后发一个 notification（没有 id，不需要回复）。
    // 发不出去也不该让初始化失败 —— 有些 server 不关心它。
    try {
      await _notify('notifications/initialized');
    } catch (_) {}
    return _info;
  }

  Future<List<McpTool>> listTools() async {
    final result = await _request('tools/list', <String, dynamic>{});
    final raw = (result['tools'] as List?) ?? const <dynamic>[];
    final out = <McpTool>[];
    for (final t in raw) {
      if (t is Map) {
        final tool = McpTool.fromJson(t.cast<String, dynamic>());
        if (tool != null) out.add(tool);
      }
    }
    return out;
  }

  Future<McpCallResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final result = await _request('tools/call', <String, dynamic>{
      'name': name,
      'arguments': args,
    }, timeout: callTimeout);

    final isError = result['isError'] == true;
    final content = (result['content'] as List?) ?? const <dynamic>[];

    // 只拼文本部分。非文本内容**明确说明被省略**，
    // 而不是静默丢掉 —— 模型以为没有内容会瞎猜。
    final parts = <String>[];
    var skipped = 0;
    for (final c in content) {
      if (c is! Map) continue;
      final m = c.cast<String, dynamic>();
      if (m['type'] == 'text' && m['text'] is String) {
        parts.add(m['text'] as String);
      } else {
        skipped++;
      }
    }
    final joined = parts.join("\n");

    // **单条文本、且整体是一个 JSON 对象 → 解包。**
    //
    // 这是 2.2 / 2.3 两个问题的同一个根因：
    //   · 不解包 → 模型拿到字符串，要自己再解析（容易失败）
    //   · 不解包 → 里面的 isError 看不到，外层报 ok:true（状态矛盾）
    Object? parsed;
    var isErrorOut = isError;
    if (parts.length == 1) {
      final candidate = tryParseJson(joined);
      if (candidate is Map) {
        parsed = candidate;
        // 内层说错了就是错了 —— 外面的 ok 是协议层的，不是语义层的
        if (candidate["isError"] == true) isErrorOut = true;
      } else if (candidate != null) {
        parsed = candidate;
      }
    }

    final suffix = skipped > 0 ? "\n\n（另有 $skipped 个非文本内容已省略）" : "";
    return McpCallResult(
      text: joined + suffix,
      json: parsed,
      isError: isErrorOut,
    );
  }

  /// 试着把一段文本解析成 JSON。失败返回 null（**不当错误**）。
  ///
  /// 只认对象和数组：数字/字符串/布尔解析出来也没意义，
  /// 反而会把普通的 "123" 变成 int 让上游困惑。
  @visibleForTesting
  static Object? tryParseJson(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (!t.startsWith("{") && !t.startsWith("[")) return null;
    try {
      final v = jsonDecode(t);
      return (v is Map || v is List) ? v : null;
    } on FormatException {
      return null;
    }
  }

  // ─────────────────────── 传输 ───────────────────────

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    final t = timeout ?? callTimeout;
    final id = _nextId++;
    final body = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });

    final response = await _post(body, timeout: t, expectResponse: true);
    final decoded = response;

    // JSON-RPC 的 error 是**协议层**的错误，和 HTTP 状态码无关
    final error = (decoded['error'] as Map?)?.cast<String, dynamic>();
    if (error != null) {
      throw McpException(
        error['message'] as String? ?? 'MCP 返回错误',
        code: (error['code'] as num?)?.toInt(),
      );
    }

    final result = decoded['result'];
    if (result is! Map) {
      // 有些 server 对无返回的方法给 null，这里当作空对象
      return <String, dynamic>{};
    }
    return result.cast<String, dynamic>();
  }

  Future<void> _notify(String method) async {
    final body = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
    });
    await _post(body, timeout: initializeTimeout, expectResponse: false);
  }

  Future<Map<String, dynamic>> _post(
    String body, {
    required Duration timeout,
    required bool expectResponse,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw McpException('MCP 地址不合法：$url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw McpException('只支持 http/https，收到 ${uri.scheme}');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      // **不跟随重定向**：跟随会把请求（含鉴权头）发到另一个地址。
      // MCP server 不该重定向；真需要的话让用户改 URL。
      ..findProxy = ((_) => 'DIRECT');

    try {
      return await _doPost(client, uri, body, timeout, expectResponse)
          .timeout(timeout, onTimeout: () {
        throw McpException('MCP 请求超时（${timeout.inSeconds}s）：$url');
      });
    } on SocketException catch (e) {
      throw McpException('连接不上 MCP server：${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _doPost(
    HttpClient client,
    Uri uri,
    String body,
    Duration timeout,
    bool expectResponse,
  ) async {
    final req = await client.postUrl(uri);
    req.followRedirects = false;
    req.headers.contentType = ContentType.json;
    // **两种都要声明。** Streamable HTTP 的服务端按 Accept 决定回纯 JSON
    // 还是 SSE 流；只写 application/json 会被判成不支持流式，
    // 部分服务端直接拒绝。
    req.headers.set('Accept', 'application/json, text/event-stream');
    for (final entry in headers.entries) {
      req.headers.set(entry.key, entry.value);
    }
    // 有会话就带上 —— 有些 server 靠它维持状态
    final sid = _sessionId;
    if (sid != null) req.headers.set('Mcp-Session-Id', sid);

    final bytes = utf8.encode(body);
    req.contentLength = bytes.length;
    req.add(bytes);

    final res = await req.close();

    // 记下会话 id，后续请求复用
    final newSid = res.headers.value('mcp-session-id');
    if (newSid != null && newSid.isNotEmpty) _sessionId = newSid;

    final text = await res.transform(utf8.decoder).join();

    if (res.statusCode < 200 || res.statusCode >= 300) {
      // 把响应体也带上 —— 有些 server 用 body 说明为什么失败
      // **脱敏之后才进错误信息。** 响应体可能回显了请求头。
      final safe = redactSecrets(text);
      final brief = safe.length > 300 ? '${safe.substring(0, 300)}…' : safe;
      throw McpException(
        'MCP server 返回 HTTP ${res.statusCode}${brief.isEmpty ? '' : '：$brief'}',
        code: res.statusCode,
      );
    }

    if (!expectResponse || text.trim().isEmpty) {
      return <String, dynamic>{};
    }

    return _decodeBody(text);
  }

  /// 解析响应体。
  ///
  /// Streamable HTTP 允许两种：
  ///   · `application/json` —— 直接一个 JSON 对象
  ///   · `text/event-stream` —— SSE，若干 `data: {...}` 行
  ///
  /// **两种都要支持**：服务端可以按自己的判断在两者之间选，
  /// 而客户端不能假设一定拿到哪一种。
  Map<String, dynamic> _decodeBody(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};

    // 纯 JSON
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) return decoded;
        throw McpException('MCP 响应不是 JSON 对象');
      } on FormatException {
        throw McpException('MCP 响应不是合法 JSON');
      }
    }

    // SSE：取最后一个能解析的 data 行。
    //
    // 取最后一个而不是第一个：一次响应里可能有多个事件
    // （比如进度通知 + 最终结果），我们要的是结果。
    final lines = trimmed.split(RegExp(r'\r?\n'));
    final dataLines = lines.where((l) => l.startsWith('data:')).toList();
    if (dataLines.isEmpty) {
      throw McpException('MCP 响应既不是 JSON 也不是 SSE：${trimmed.length > 120 ? trimmed.substring(0, 120) : trimmed}');
    }
    for (final line in dataLines.reversed) {
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        continue;
      }
    }
    throw McpException('SSE 里没有可解析的 JSON 事件');
  }
}
