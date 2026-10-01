/// Bridge 消息模型与编解码。
///
/// Bridge 是**沙箱 WebView ↔ 宿主** 的唯一通道。协议定义见
/// `docs/07-bridge-protocol.md`。
///
/// 五种消息：
///
/// | kind | 方向 | 用途 |
/// |---|---|---|
/// | `req` | 插件 → 宿主 | 调用原语 |
/// | `res` | 宿主 → 插件 | 请求成功返回 |
/// | `err` | 宿主 → 插件 | 请求失败 |
/// | `evt` | 双向 | 单向事件，不需回应 |
/// | `str` | 宿主 → 插件 | 流式分片 |
/// | `inv` | 宿主 → 插件 | 宿主反向调用插件（工具执行、生命周期） |
library;

import 'dart:convert';

import '../common/errors.dart';

/// 协议版本。宿主与插件 SDK 必须一致。
const int bridgeProtocolVersion = 1;

/// 单条消息大小上限（1 MB）。
///
/// 更大的数据传输必须走 `fs.*` 的沙箱路径，而不是塞进 Bridge。
const int bridgeMaxMessageBytes = 1024 * 1024;

/// 单次流式响应的分片数上限，防失控。
const int bridgeMaxStreamChunks = 10000;

/// 消息类型。
enum BridgeKind {
  /// 插件 → 宿主：调用原语。
  req,

  /// 宿主 → 插件：成功返回。
  res,

  /// 宿主 → 插件：失败返回。
  err,

  /// 双向：单向事件。
  evt,

  /// 宿主 → 插件：流式分片。
  str,

  /// 宿主 → 插件：反向调用。
  inv;

  static BridgeKind? parse(String? raw) {
    for (final k in BridgeKind.values) {
      if (k.name == raw) return k;
    }
    return null;
  }
}

/// 一条 Bridge 消息。
class BridgeEnvelope {
  const BridgeEnvelope({
    required this.kind,
    this.v = bridgeProtocolVersion,
    this.id,
    this.method,
    this.params,
    this.result,
    this.error,
    this.seq,
    this.delta,
    this.done,
    this.ts,
  });

  /// 请求：插件调用原语。
  factory BridgeEnvelope.request({
    required String id,
    required String method,
    Map<String, dynamic>? params,
  }) =>
      BridgeEnvelope(
        kind: BridgeKind.req,
        id: id,
        method: method,
        params: params ?? const <String, dynamic>{},
      );

  /// 成功响应。
  factory BridgeEnvelope.response({
    required String id,
    Object? result,
  }) =>
      BridgeEnvelope(kind: BridgeKind.res, id: id, result: result);

  /// 失败响应。
  factory BridgeEnvelope.failure({
    required String id,
    required TsukiroException error,
  }) =>
      BridgeEnvelope(kind: BridgeKind.err, id: id, error: error);

  /// 事件。
  factory BridgeEnvelope.event(String method, [Map<String, dynamic>? params]) =>
      BridgeEnvelope(kind: BridgeKind.evt, method: method, params: params);

  /// 流式分片。
  factory BridgeEnvelope.streamChunk({
    required String id,
    required int seq,
    required String delta,
    bool done = false,
  }) =>
      BridgeEnvelope(kind: BridgeKind.str, id: id, seq: seq, delta: delta, done: done);

  /// 宿主反向调用插件。
  factory BridgeEnvelope.invoke({
    required String id,
    required String method,
    Map<String, dynamic>? params,
  }) =>
      BridgeEnvelope(
        kind: BridgeKind.inv,
        id: id,
        method: method,
        params: params ?? const <String, dynamic>{},
      );

  final BridgeKind kind;
  final int v;

  /// `req` / `res` / `err` / `inv` 用于配对；`evt` 为 null。
  final String? id;

  /// `req` / `evt` / `inv` 的方法名。
  final String? method;

  final Map<String, dynamic>? params;
  final Object? result;
  final TsukiroException? error;

  /// 仅 `str`。
  final int? seq;
  final String? delta;
  final bool? done;

  final int? ts;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': v,
        'kind': kind.name,
        if (id != null) 'id': id,
        if (method != null) 'method': method,
        if (params != null) 'params': params,
        if (result != null) 'result': result,
        if (error != null) 'error': error!.toJson(),
        if (seq != null) 'seq': seq,
        if (delta != null) 'delta': delta,
        if (done != null) 'done': done,
        if (ts != null) 'ts': ts,
      };

  @override
  String toString() => 'BridgeEnvelope(${kind.name}'
      '${id == null ? '' : ' id=$id'}'
      '${method == null ? '' : ' method=$method'})';
}

/// 主机侧解析出来的错误信息（与 [TsukiroException] 对应，但可独立构造）。
class BridgeError implements Exception {
  const BridgeError(this.code, this.message, {this.details, this.retryable = false});

  factory BridgeError.fromJson(Map<String, dynamic> json) => BridgeError(
        json['code']?.toString() ?? 'INTERNAL',
        json['message']?.toString() ?? '未知错误',
        details: json['details'] is Map<String, dynamic>
            ? json['details'] as Map<String, dynamic>
            : null,
        retryable: json['retryable'] == true,
      );

  final String code;
  final String message;
  final Map<String, dynamic>? details;
  final bool retryable;

  @override
  String toString() => 'BridgeError($code): $message';
}

/// Bridge 编解码器。
///
/// 所有对外来的字节都**不可信**，因此 [decode] 对每条消息做完整结构校验，
/// 任何不合规都抛 [TsukiroException]（不是返回 null）—— 让调用方能记审计。
class BridgeCodec {
  const BridgeCodec({this.maxBytes = bridgeMaxMessageBytes});

  final int maxBytes;

  /// 编码为 JSON 文本。
  ///
  /// 超过 [maxBytes] 抛 `INVALID_ARGS`。
  String encode(BridgeEnvelope envelope) {
    final map = envelope.toJson();
    map['ts'] ??= DateTime.now().millisecondsSinceEpoch;
    final text = jsonEncode(map);
    // 用 UTF-8 字节数而不是字符数：中文占 3 字节，按字符数判断会放过超限消息
    final bytes = utf8.encode(text).length;
    if (bytes > maxBytes) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '消息过大: $bytes 字节 > $maxBytes 字节',
        details: <String, dynamic>{'bytes': bytes, 'limit': maxBytes},
      );
    }
    return text;
  }

  /// 解析一条消息。任何不合规都抛 [TsukiroException]。
  BridgeEnvelope decode(String raw) {
    final byteLength = utf8.encode(raw).length;
    if (byteLength > maxBytes) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '消息过大: $byteLength 字节 > $maxBytes 字节',
        details: <String, dynamic>{'bytes': byteLength, 'limit': maxBytes},
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'Bridge 消息不是合法 JSON: ${e.message}',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'Bridge 消息顶层必须是对象',
      );
    }

    return _fromMap(decoded);
  }

  BridgeEnvelope _fromMap(Map<String, dynamic> json) {
    // ── 版本 ──
    final rawV = json['v'];
    if (rawV is! num) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'Bridge 消息缺少 v 字段',
      );
    }
    final version = rawV.toInt();
    if (version > bridgeProtocolVersion) {
      // 明确拒绝而不是尽力解析：高版本可能有不兼容的语义
      throw TsukiroException(
        TsukiroErrorCode.unsupported,
        'Bridge 协议版本 $version 高于宿主支持的 $bridgeProtocolVersion，请升级宿主',
        details: <String, dynamic>{'peerVersion': version},
      );
    }

    // ── kind ──
    final kind = BridgeKind.parse(json['kind']?.toString());
    if (kind == null) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '未知的 Bridge 消息类型: "${json['kind']}"',
      );
    }

    final id = json['id']?.toString();
    final method = json['method']?.toString();
    final ts = json['ts'] is num ? (json['ts'] as num).toInt() : null;

    Map<String, dynamic>? params;
    final rawParams = json['params'];
    if (rawParams != null) {
      if (rawParams is! Map<String, dynamic>) {
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          'params 必须是对象',
          details: <String, dynamic>{'kind': kind.name},
        );
      }
      params = rawParams;
    }

    switch (kind) {
      case BridgeKind.req:
      case BridgeKind.inv:
        if (id == null || id.isEmpty) {
          throw TsukiroException(
            TsukiroErrorCode.invalidArgs,
            '${kind.name} 消息必须有 id（用于请求/响应配对）',
          );
        }
        if (method == null || method.isEmpty) {
          throw TsukiroException(
            TsukiroErrorCode.invalidArgs,
            '${kind.name} 消息必须有 method',
          );
        }
        return BridgeEnvelope(
          kind: kind,
          v: version,
          id: id,
          method: method,
          params: params ?? const <String, dynamic>{},
          ts: ts,
        );

      case BridgeKind.res:
        if (id == null || id.isEmpty) {
          throw TsukiroException(TsukiroErrorCode.invalidArgs, 'res 消息必须有 id');
        }
        return BridgeEnvelope(kind: kind, v: version, id: id, result: json['result'], ts: ts);

      case BridgeKind.err:
        if (id == null || id.isEmpty) {
          throw TsukiroException(TsukiroErrorCode.invalidArgs, 'err 消息必须有 id');
        }
        final rawError = json['error'];
        if (rawError is! Map<String, dynamic>) {
          throw TsukiroException(TsukiroErrorCode.invalidArgs, 'err 消息必须有 error 对象');
        }
        return BridgeEnvelope(
          kind: kind,
          v: version,
          id: id,
          error: TsukiroException(
            errorCodeFromString(rawError['code']?.toString() ?? '') ??
                TsukiroErrorCode.internal,
            rawError['message']?.toString() ?? '未知错误',
            details: rawError['details'] is Map<String, dynamic>
                ? rawError['details'] as Map<String, dynamic>
                : null,
            retryable: rawError['retryable'] == true,
          ),
          ts: ts,
        );

      case BridgeKind.evt:
        if (method == null || method.isEmpty) {
          throw TsukiroException(TsukiroErrorCode.invalidArgs, 'evt 消息必须有 method');
        }
        return BridgeEnvelope(
          kind: kind,
          v: version,
          method: method,
          params: params ?? const <String, dynamic>{},
          ts: ts,
        );

      case BridgeKind.str:
        if (id == null || id.isEmpty) {
          throw TsukiroException(TsukiroErrorCode.invalidArgs, 'str 消息必须有 id');
        }
        final rawSeq = json['seq'];
        if (rawSeq is! num || rawSeq < 0) {
          throw TsukiroException(TsukiroErrorCode.invalidArgs, 'str 消息的 seq 必须是非负数字');
        }
        final seq = rawSeq.toInt();
        if (seq >= bridgeMaxStreamChunks) {
          throw TsukiroException(
            TsukiroErrorCode.rateLimited,
            '流式分片数超过上限 $bridgeMaxStreamChunks',
            details: <String, dynamic>{'seq': seq},
          );
        }
        return BridgeEnvelope(
          kind: kind,
          v: version,
          id: id,
          seq: seq,
          delta: json['delta']?.toString() ?? '',
          done: json['done'] == true,
          ts: ts,
        );
    }
  }
}

/// 请求 id 配对表。
///
/// 并发请求必须能各自拿到自己的响应，因此需要按 id 配对。
class PendingCallRegistry {
  PendingCallRegistry({this.maxPending = 64});

  /// 同时在途的请求上限，防止插件把宿主资源打满。
  final int maxPending;

  final Map<String, String> _pending = <String, String>{}; // id → method
  int _counter = 0;

  int get pendingCount => _pending.length;

  /// 生成新请求 id。
  ///
  /// 用单调计数器而不是随机数：便于在日志里按顺序读，也避免碰撞。
  /// 前缀区分方向，方便调试时一眼看出是谁发起的。
  String nextId({String prefix = 'r'}) => '${prefix}_${(++_counter).toRadixString(36)}';

  /// 登记一个在途请求。超出上限抛 `RATE_LIMITED`。
  void register(String id, String method) {
    if (_pending.length >= maxPending) {
      throw TsukiroException(
        TsukiroErrorCode.rateLimited,
        '在途请求过多（$maxPending），请等待之前的请求返回',
        details: <String, dynamic>{'pending': _pending.length, 'limit': maxPending},
      );
    }
    _pending[id] = method;
  }

  /// 取出并移除一个在途请求。未知 id 返回 null（可能是重复响应或伪造）。
  String? take(String id) => _pending.remove(id);

  bool isPending(String id) => _pending.containsKey(id);

  /// 清空（插件停用/崩溃时调用，避免悬挂的 await 永远不返回）。
  List<String> clear() {
    final ids = _pending.keys.toList(growable: false);
    _pending.clear();
    return ids;
  }
}

/// 流式分片序号校验器。
///
/// 用于检测丢包与乱序。协议本身不保证传输可靠，所以分片可能缺失或重复。
class StreamSequenceValidator {
  int _expected = 0;

  int get expected => _expected;

  /// 校验一个分片；返回 false 表示序号不符合预期（调用方应记审计）。
  bool accept(int seq) {
    if (seq != _expected) return false;
    _expected++;
    return true;
  }

  void reset() => _expected = 0;
}
