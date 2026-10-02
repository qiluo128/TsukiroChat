/// Bridge 会话 —— 一个插件 WebView 与宿主之间的**全部**通信。
///
/// 见 `docs/07-bridge-protocol.md`。
///
/// 三条它负责的安全约束：
///   1. **实例绑定**：`pluginId` 由宿主在创建会话时绑定，不信任消息里的自称。
///      插件 A 无法冒充插件 B。
///   2. **握手门禁**：握手完成前收到的任何消息一律丢弃并记审计 ——
///      防止注入的脚本抢跑。
///   3. **方法白名单**：只有注册表里的原语能调；`__host.*` 保留命名空间对插件关闭。
library;

import 'dart:async';

import '../audit/audit.dart';
import '../common/errors.dart';
import '../permission/gatekeeper.dart';
import '../primitive/primitive_registry.dart';
import 'envelope.dart';

/// 会话状态。
enum SessionState {
  /// WebView 已创建，等 `bridge.hello`。
  awaitingHello,

  /// 握手完成，正常通信。
  ready,

  /// 因安全原因被宿主终止（插件冒充、协议版本不符等）。
  terminated,
}

/// 一次会话的事件回调（宿主用来把日志接到调试面板）。
typedef SessionObserver = void Function(String message, {Map<String, dynamic>? data});

/// 一个插件的 Bridge 会话。
class BridgeSession {
  BridgeSession({
    required this.pluginId,
    required this.pluginVersion,
    required this.registry,
    required this.gatekeeper,
    this.hostVersion = '1.0.0',
    this.codec = const BridgeCodec(),
    AuditSink? audit,
    this.maxPending = 64,
    this.observer,
  }) : audit = audit ?? const NullAuditSink();

  /// **由宿主绑定**，不来自消息体。这是实例绑定的基础。
  final String pluginId;

  final String pluginVersion;
  final PrimitiveRegistry registry;
  final Gatekeeper gatekeeper;
  final String hostVersion;
  final BridgeCodec codec;
  final AuditSink audit;
  final int maxPending;
  final SessionObserver? observer;

  SessionState _state = SessionState.awaitingHello;
  String? _terminationReason;

  final PendingCallRegistry _outbound = PendingCallRegistry();
  final Map<String, Completer<BridgeEnvelope>> _awaiting = <String, Completer<BridgeEnvelope>>{};

  /// 握手中插件自称的版本，用于兼容性判断与审计。
  String? peerHostApi;

  SessionState get state => _state;

  bool get isReady => _state == SessionState.ready;

  bool get isTerminated => _state == SessionState.terminated;

  String? get terminationReason => _terminationReason;

  int get pendingOutbound => _awaiting.length;

  /// 当前悬挂的反向调用 id。
  ///
  /// 存在的理由有两个：宿主调试面板要展示"哪些调用还没回来"；
  /// 以及在无法注入 WebView 的测试环境里，需要知道宿主刚发出了哪个 id 才能模拟回音。
  List<String> get pendingInvokeIds => _awaiting.keys.toList(growable: false);

  // ─────────────────────────── 入口 ───────────────────────────

  /// 处理一条来自 WebView 的原始文本消息。
  ///
  /// 返回要回发的消息；null 表示这条消息被丢弃（未握手 / 无需回应）。
  Future<BridgeEnvelope?> handleRaw(String raw) async {
    if (_state == SessionState.terminated) return null;

    final BridgeEnvelope envelope;
    try {
      envelope = codec.decode(raw);
    } on TsukiroException catch (e) {
      // 解不开的消息：记审计但不回发 —— 回发等于给攻击者一个探测信道
      _record('bridge.decodeError', 'error', <String, dynamic>{'message': e.message});
      return null;
    }
    return handle(envelope);
  }

  /// 处理一条已解码的消息。
  Future<BridgeEnvelope?> handle(BridgeEnvelope envelope) async {
    if (_state == SessionState.terminated) return null;

    // ── 握手门禁 ──
    if (_state == SessionState.awaitingHello) {
      if (envelope.kind == BridgeKind.evt && envelope.method == 'bridge.hello') {
        return _handleHello(envelope);
      }
      // 握手前的一切消息丢弃 + 审计
      _record('bridge.preHandshakeDrop', 'denied', <String, dynamic>{
        'kind': envelope.kind.name,
        'method': envelope.method,
      });
      return null;
    }

    switch (envelope.kind) {
      case BridgeKind.req:
        return _handleRequest(envelope);

      case BridgeKind.evt:
        return _handleEvent(envelope);

      case BridgeKind.res:
      case BridgeKind.err:
        _resolveOutbound(envelope);
        return null;

      case BridgeKind.str:
      case BridgeKind.inv:
        // 插件不该发这两种。记审计并忽略，不报错 ——
        // 报错会让插件知道"我踩到了什么"，反而提供信息。
        _record('bridge.unexpectedKind', 'denied', <String, dynamic>{
          'kind': envelope.kind.name,
        });
        return null;
    }
  }

  // ─────────────────────────── 握手 ───────────────────────────

  Future<BridgeEnvelope?> _handleHello(BridgeEnvelope envelope) async {
    final params = envelope.params ?? const <String, dynamic>{};

    // ① 实例绑定校验：自称的 pluginId 必须与宿主绑定的一致
    final claimed = params['pluginId']?.toString();
    if (claimed != null && claimed != pluginId) {
      _terminate('插件自称的身份 "$claimed" 与会话绑定的 "$pluginId" 不符（疑似冒充）');
      return BridgeEnvelope.event('bridge.fatal', <String, dynamic>{
        'reason': 'instance_mismatch',
        'message': '会话绑定的插件身份与自称不符',
      });
    }

    // ② 协议版本
    final peerVersion = params['v'] is num ? (params['v'] as num).toInt() : 0;
    if (peerVersion > bridgeProtocolVersion) {
      _terminate('协议版本 $peerVersion 高于宿主支持的 $bridgeProtocolVersion');
      return BridgeEnvelope.event('bridge.fatal', <String, dynamic>{
        'reason': 'protocol_too_new',
        'message': '插件要求的 Bridge 协议版本高于宿主支持',
        'hostVersion': bridgeProtocolVersion,
      });
    }

    peerHostApi = params['hostApi']?.toString();
    _state = SessionState.ready;

    _record('bridge.handshake', 'ok', <String, dynamic>{
      'peerVersion': peerVersion,
      'hostApi': peerHostApi,
    });
    observer?.call('bridge 握手完成', data: <String, dynamic>{'pluginId': pluginId});

    return BridgeEnvelope.event('bridge.ready', <String, dynamic>{
      'hostVersion': hostVersion,
      'bridgeProtocolVersion': bridgeProtocolVersion,
      // 已授权权限让插件能在启动时决定功能开关，不必等第一次调用失败
      'granted': gatekeeper.grantedOf(pluginId).toList(growable: false),
    });
  }

  /// 因安全原因终止会话。宿主应随即销毁 WebView。
  void _terminate(String reason) {
    _state = SessionState.terminated;
    _terminationReason = reason;
    _record('bridge.terminate', 'denied', <String, dynamic>{'reason': reason});
    observer?.call('bridge 会话被终止：$reason');

    // 把悬挂的反向调用全部失败掉，避免宿主侧永远 await
    for (final c in _awaiting.values) {
      if (!c.isCompleted) {
        c.complete(BridgeEnvelope.failure(
          id: 'terminated',
          error: TsukiroException(
            TsukiroErrorCode.pluginError,
            'Bridge 会话已终止：$reason',
          ),
        ));
      }
    }
    _awaiting.clear();
    _outbound.clear();
  }

  // ─────────────────────────── 请求 ───────────────────────────

  Future<BridgeEnvelope> _handleRequest(BridgeEnvelope envelope) async {
    final id = envelope.id!;
    final method = envelope.method!;

    // 保留命名空间对插件关闭
    if (method.startsWith('__')) {
      _record('bridge.reservedNamespace', 'denied', <String, dynamic>{'method': method});
      return BridgeEnvelope.failure(
        id: id,
        error: TsukiroException(
          TsukiroErrorCode.permissionDenied,
          '方法名 "$method" 属于宿主保留命名空间，插件不可调用',
        ),
      );
    }

    // 在途请求数限制：防止插件把宿主资源打满
    if (_outbound.pendingCount >= maxPending) {
      return BridgeEnvelope.failure(
        id: id,
        error: TsukiroException(
          TsukiroErrorCode.rateLimited,
          '同时在途的请求过多（上限 $maxPending）',
        ),
      );
    }

    _outbound.register(id, method);

    try {
      final result = await registry.invoke(
        pluginId,
        method,
        envelope.params ?? const <String, dynamic>{},
      );
      _outbound.take(id);
      return BridgeEnvelope.response(id: id, result: result);
    } on TsukiroException catch (e) {
      _outbound.take(id);
      return BridgeEnvelope.failure(id: id, error: e);
    } catch (e) {
      _outbound.take(id);
      return BridgeEnvelope.failure(
        id: id,
        error: TsukiroException(TsukiroErrorCode.internal, '原语 $method 异常：$e'),
      );
    }
  }

  Future<BridgeEnvelope?> _handleEvent(BridgeEnvelope envelope) async {
    switch (envelope.method) {
      case 'stream.cancel':
        // 插件主动取消一次流式调用
        final target = envelope.params?['id']?.toString();
        if (target != null) {
          _record('bridge.streamCancel', 'ok', <String, dynamic>{'id': target});
        }
        return null;

      case 'bridge.bye':
        _record('bridge.bye', 'ok', const <String, dynamic>{});
        _terminate('插件主动断开');
        return null;

      default:
        // 未知事件静默忽略 —— 这样加新事件不需要升协议版本
        return null;
    }
  }

  // ─────────────────────────── 反向调用 ───────────────────────────

  /// 宿主反向调用插件（工具执行、生命周期、钩子）。
  ///
  /// 返回插件回的 `res`/`err`。超时会返回一个 `TIMEOUT` 的失败响应，
  /// **不抛异常** —— 调用方（工具循环）需要把失败当作一个正常结果处理，
  /// 好让模型看到"这个工具失败了"并自行组织语言。
  Future<BridgeEnvelope> invoke(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!isReady) {
      return BridgeEnvelope.failure(
        id: 'not_ready',
        error: TsukiroException(
          TsukiroErrorCode.pluginError,
          'Bridge 会话尚未就绪（state=${_state.name}）',
        ),
      );
    }

    final id = _outbound.nextId(prefix: 'i');
    final completer = Completer<BridgeEnvelope>();
    _awaiting[id] = completer;

    observer?.call('→ inv $method', data: params);

    // 宿主把这条消息投递给 WebView；这里只等回音。
    // 用 unawaited 显式表明"这是刻意的后台超时兜底"，不是在漏 await。
    // 注意必须是 Future<void> —— 给 Future.delayed 指定非空类型参数时它要求
    // 传 computation，那正是我们要的这个空操作。
    unawaited(Future<void>.delayed(timeout).then((_) {
      if (!completer.isCompleted) {
        _awaiting.remove(id);
        completer.complete(BridgeEnvelope.failure(
          id: id,
          error: TsukiroException(
            TsukiroErrorCode.timeout,
            '插件未在 ${timeout.inMilliseconds}ms 内响应 $method',
          ),
        ));
      }
    }));

    return completer.future;
  }

  void _resolveOutbound(BridgeEnvelope envelope) {
    final id = envelope.id;
    if (id == null) return;
    final completer = _awaiting.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(envelope);
    }
  }

  // ─────────────────────────── 宿主发事件 ───────────────────────────

  /// 宿主给插件发一条事件。
  BridgeEnvelope? event(String method, [Map<String, dynamic>? params]) {
    if (!isReady) return null;
    return BridgeEnvelope.event(method, params);
  }

  /// 用户撤销/授予权限后通知插件，让它有机会优雅降级。
  BridgeEnvelope? notifyPermissionChange({
    List<String> granted = const <String>[],
    List<String> revoked = const <String>[],
  }) =>
      event('permission.change', <String, dynamic>{
        'granted': granted,
        'revoked': revoked,
      });

  /// 插件停止时调用。等它做完收尾（最多 [grace]），然后终止会话。
  Future<void> shutdown({
    Duration grace = const Duration(seconds: 2),
    String reason = '宿主停用插件',
  }) async {
    if (isReady) {
      final response = await invoke(
        'lifecycle.stop',
        params: <String, dynamic>{'reason': reason},
        timeout: grace,
      );
      if (!response.kind.name.startsWith('res')) {
        _record('bridge.shutdownTimeout', 'error', <String, dynamic>{'reason': reason});
      }
    }
    _terminate(reason);
  }

  void _record(String primitive, String result, Map<String, dynamic> digest) {
    audit.write(AuditEntry(
      pluginId: pluginId,
      pluginVersion: pluginVersion,
      kind: 'bridge',
      primitive: primitive,
      argsDigest: digest,
      result: result,
    ));
  }
}
