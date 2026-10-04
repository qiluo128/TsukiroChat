/// 插件运行时：一个插件 = 一个 WebView + 一条 Bridge 会话。
///
/// **这是整个架构里最后一个被真实验证的部分。** 在此之前，
/// 内核、桥接协议、权限门禁都有单测覆盖，但"插件代码真的在 JS 引擎里跑起来"
/// 这件事只被 Dart 桩验证过 —— 桩和真实 WebView 的差别，
/// 恰恰是最容易出问题的地方（消息编码、时序、异步边界）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:plugin_core/plugin_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'plugin_bundle.dart';

/// 运行时状态。
enum RuntimeState { created, loading, ready, stopped, failed }

/// 日志条目（接到插件管理页的调试面板）。
class PluginLogEntry {
  PluginLogEntry({
    required this.level,
    required this.message,
    this.data,
    required this.at,
  });

  final String level;
  final String message;
  final Object? data;
  final DateTime at;
}

/// 插件的运行时抽象。
///
/// 抽出来是为了让上层（工具循环、插件管理）不依赖 WebView ——
/// 测试里可以塞一个假实现。
abstract class PluginRuntime {
  String get pluginId;
  RuntimeState get state;
  bool get isReady;
  List<PluginLogEntry> get logs;

  /// 失败原因。`state == failed` 时有值，其余情况为 null。
  ///
  /// 界面上要显示它 —— 插件起不来时"启动失败"四个字没有用，
  /// 用户和开发者都需要知道**为什么**。
  String? get failureReason;

  Future<void> start();
  Future<void> stop();

  /// 执行插件定义的某个工具。
  Future<ToolInvocationResult> invokeTool(String name, Map<String, dynamic> args);

  /// 让插件渲染一个插槽。返回 `{html, height}` 或 null。
  Future<Map<String, dynamic>?> renderSlot(String slot, Map<String, dynamic> context);

  /// 给插件发一条事件（宿主→插件单向）。
  ///
  /// 界面上的按钮点击走这条。返回 false 表示插件没在跑 ——
  /// 界面据此给用户明确反馈，而不是点下去毫无反应。
  bool sendEvent(String event, [Map<String, dynamic>? payload]);

  /// 承载 WebView 的控件。宿主必须把它挂进树里，否则 Android 侧不会创建
  /// 底层 WebView，JS 也就不会跑。
  Widget buildView();
}

/// 基于系统 WebView 的运行时。
class WebViewPluginRuntime implements PluginRuntime {
  WebViewPluginRuntime({
    required this.bundle,
    required this.registry,
    required this.gatekeeper,
    AuditSink? audit,
    this.readyTimeout = const Duration(seconds: 15),
  }) : audit = audit ?? const NullAuditSink() {
    _session = BridgeSession(
      pluginId: bundle.manifest.id,
      pluginVersion: bundle.manifest.version,
      registry: registry,
      gatekeeper: gatekeeper,
      audit: this.audit,
      send: _deliverToWebView,
      observer: (message, {data}) => _log('debug', message, data),
    );
  }

  final PluginBundle bundle;
  final PrimitiveRegistry registry;
  final Gatekeeper gatekeeper;
  final AuditSink audit;
  final Duration readyTimeout;

  late final BridgeSession _session;

  final WebViewController _controller = WebViewController();
  final List<PluginLogEntry> _logs = <PluginLogEntry>[];
  final Completer<void> _readyCompleter = Completer<void>();

  RuntimeState _state = RuntimeState.created;
  String? _failureReason;

  static const int _maxLogs = 200;

  @override
  String get pluginId => bundle.manifest.id;

  @override
  RuntimeState get state => _state;

  @override
  bool get isReady => _state == RuntimeState.ready;

  @override
  List<PluginLogEntry> get logs => List<PluginLogEntry>.unmodifiable(_logs);

  @override
  String? get failureReason => _failureReason;
  BridgeSession get session => _session;

  @override
  Widget buildView() => WebViewWidget(controller: _controller);

  // ─────────────────────────── 生命周期 ───────────────────────────

  @override
  Future<void> start() async {
    if (_state == RuntimeState.ready) return;
    if (_state == RuntimeState.failed) {
      throw StateError('运行时已失败：$_failureReason');
    }

    _state = RuntimeState.loading;

    final runtimeSource =
        await rootBundle.loadString('assets/plugin_runtime/tsukiro.js');
    // 用**真实清单**生成 HTML —— pluginId / hostApi 要填进去，
    // 握手时会拿它跟宿主绑定值比对（对不上直接终止会话）
    final html = PluginScriptBuilder(bundle: bundle).buildHtml(runtimeSource: runtimeSource);

    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setBackgroundColor(Colors.transparent);

    // 背景透明：插槽渲染的 WebView 要能叠在宿主界面上
    await _controller.addJavaScriptChannel(
      'TsukiroBridge',
      onMessageReceived: _onJsMessage,
    );

    // ── 沙箱第一道防线 ──
    // 挡住一切导航与外部资源。插件想联网必须走 tsukiro.net.* 原语，
    // 而那条路要过权限门禁。
    await _controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (request) {
        // 只允许我们注入的 data:/about: 初始文档
        final url = request.url;
        final allowed = url.startsWith('data:') ||
            url.startsWith('about:') ||
            url.isEmpty;
        if (!allowed) {
          _log('warn', '拦下了一次导航：$url');
        }
        return NavigationDecision.prevent;
      },
      onWebResourceError: (error) {
        // 被 CSP 拦下的请求会走到这里 —— 这是**预期行为**，不是故障
        _log('debug', '资源被拦：${error.description}（${error.errorType}）');
      },
    ));

    // 监听 JS 控制台，插件里 console.log 的内容能进调试面板
    await _controller.setOnConsoleMessage((msg) {
      _log('debug', '[console.${msg.level.name}] ${msg.message}');
    });

    await _controller.loadHtmlString(html);

    try {
      await _readyCompleter.future.timeout(readyTimeout);
      _state = RuntimeState.ready;
      _log('info', '运行时就绪');
    } on TimeoutException {
      _state = RuntimeState.failed;
      _failureReason = '插件未在 ${readyTimeout.inSeconds} 秒内完成握手';
      _log('error', _failureReason!);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (_state == RuntimeState.stopped) return;
    _state = RuntimeState.stopped;
    try {
      await _session.shutdown();
    } catch (e) {
      _log('warn', '停机时出错：$e');
    }
  }

  // ─────────────────────────── 调用 ───────────────────────────

  @override
  Future<ToolInvocationResult> invokeTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (!isReady) {
      return ToolInvocationResult.failure(
        'NOT_READY',
        '插件 $pluginId 的运行时未就绪（state=${_state.name}）',
      );
    }

    final timeout = _toolTimeout(name);
    final reply = await _session.invoke(
      'tool.invoke',
      params: <String, dynamic>{'name': name, 'args': args},
      timeout: timeout,
    );

    if (reply.kind == BridgeKind.err) {
      final err = reply.error;
      return ToolInvocationResult.failure(
        err?.code.name ?? 'PLUGIN_ERROR',
        err?.message ?? '插件执行失败',
      );
    }

    final result = reply.result;
    if (result is Map<String, dynamic>) {
      // 插件可以显式返回 {ok:false, error} 表示业务失败
      if (result['ok'] == false) {
        return ToolInvocationResult.failure(
          result['error']?.toString() ?? 'PLUGIN_ERROR',
          result['message']?.toString() ?? '插件返回了失败',
        );
      }
      return ToolInvocationResult.ok(result);
    }
    return ToolInvocationResult.ok(<String, dynamic>{'result': result});
  }

  @override
  Future<Map<String, dynamic>?> renderSlot(
    String slot,
    Map<String, dynamic> context,
  ) async {
    if (!isReady) return null;
    final reply = await _session.invoke(
      'slot.render',
      params: <String, dynamic>{'slot': slot, 'context': context},
      timeout: const Duration(seconds: 5),
    );
    if (reply.kind == BridgeKind.err) {
      _log('warn', '插槽 $slot 渲染失败：${reply.error?.message}');
      return null;
    }
    final r = reply.result;
    return r is Map<String, dynamic> ? r : null;
  }

  @override
  bool sendEvent(String event, [Map<String, dynamic>? payload]) {
    if (!isReady) return false;
    // `event()` 自己负责投递；返回 null 表示会话未就绪
    return _session.event(event, payload) != null;
  }

  Duration _toolTimeout(String name) {
    for (final t in bundle.manifest.provides.tools) {
      if (t.name == name) return Duration(milliseconds: t.timeoutMs);
    }
    return const Duration(seconds: 10);
  }

  // ─────────────────────────── Bridge 接线 ───────────────────────────

  /// 把一条消息投递进 WebView。
  ///
  /// 用 `jsonEncode` 把 JSON 文本再编码一次成 **JS 字符串字面量** ——
  /// 直接拼 `'window.__tsukiro_receive($raw)'` 的话，插件数据里
  /// 只要有一个引号或反斜杠就会把脚本拼坏（而且拼坏的方式是
  /// 静默执行一半，极难排查）。
  Future<void> _deliverToWebView(String rawJson) async {
    if (_state == RuntimeState.stopped) return;
    await _controller.runJavaScript(
      'window.__tsukiro_receive(${jsonEncode(rawJson)});',
    );
  }

  void _onJsMessage(JavaScriptMessage message) {
    unawaited(_handleJsMessage(message.message));
  }

  Future<void> _handleJsMessage(String raw) async {
    try {
      await _session.dispatch(raw);
    } catch (e) {
      _log('error', '处理插件消息失败：$e');
      return;
    }

    // **握手完成后必须放行 start()。**
    //
    // 之前这里漏了这一步，而 `_readyCompleter` 在整个文件里**只被 await、
    // 从来没有被 complete** —— 于是 `start()` 必然走满 15 秒超时，
    // 插件无一例外显示"启动失败"。排查时最迷惑的地方在于：
    // 日志里握手是成功的，但状态就是 failed。
    if (_session.isReady && !_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  // ─────────────────────────── 日志 ───────────────────────────

  void _log(String level, String message, [Object? data]) {
    if (_logs.length >= _maxLogs) _logs.removeAt(0);
    _logs.add(PluginLogEntry(
      level: level,
      message: message,
      data: data,
      at: DateTime.now(),
    ));
    if (kDebugMode) debugPrint('[plugin:$pluginId][$level] $message');
  }

  /// 供宿主转发的插件日志（`plugin.log` 事件）。
  void addExternalLog(String level, String message, Object? data) =>
      _log(level, message, data);
}
