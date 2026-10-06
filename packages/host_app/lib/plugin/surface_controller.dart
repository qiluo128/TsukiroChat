/// 可见插件 Surface 控制器。
///
/// Web Surface 使用独立 WebView，页面通过轻量 SurfaceBridge 与插件 Worker
/// 互传事件；Flame Surface 使用宿主注册的 GameWidget。普通插件不执行 Dart。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'flame_surface.dart';
import 'plugin_host.dart';
import 'package:plugin_core/plugin_core.dart';

class PluginSurfaceController implements HostSurfaceController {
  PluginSurfaceController({required this._navigatorKey});

  final GlobalKey<NavigatorState> _navigatorKey;
  PluginHost? _host;
  final Map<String, _SurfaceWebViewState> _webViews = <String, _SurfaceWebViewState>{};
  final Map<String, FlameGame> _flameGames = <String, FlameGame>{};
  final Map<String, Map<String, dynamic>> _pendingStates = <String, Map<String, dynamic>>{};

  void attachHost(PluginHost host) => _host = host;

  String _key(String pluginId, String surfaceId) => '$pluginId#$surfaceId';

  @override
  Future<bool> open(String pluginId, String surfaceId) async {
    final host = _host;
    final plugin = host?.byId(pluginId);
    final surface = host?.surfaceRegistry.find(pluginId, surfaceId);
    final navigator = _navigatorKey.currentState;
    if (host == null || plugin == null || surface == null || navigator == null) return false;

    if (surface.declaration.isFlame) {
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('${plugin.name} · ${surface.id}')),
          body: PluginFlameSurface(
            host: host,
            pluginId: pluginId,
            surfaceId: surfaceId,
            params: <String, dynamic>{'surfaceId': surfaceId},
            onCreated: (game) {
              final key = _key(pluginId, surfaceId);
              _flameGames[key] = game;
              final pending = _pendingStates[key];
              if (game is PluginSceneGame && pending != null) {
                unawaited(game.updateState(pending));
              }
            },
            onEvent: (event) => unawaited(this.event(pluginId, surfaceId, event)),
          ),
        ),
      )));
      return true;
    }

    final entry = surface.declaration.entry;
    if (entry == null) return false;
    final file = File('${plugin.directory}${Platform.pathSeparator}$entry');
    if (!file.existsSync()) return false;
    final html = await file.readAsString();
    await navigator.push<void>(MaterialPageRoute<void>(
      builder: (_) => PluginWebSurfacePage(
        pluginId: pluginId,
        surfaceId: surfaceId,
        title: '${plugin.name} · ${surface.id}',
        html: html,
        controller: this,
      ),
    ));
    return true;
  }

  @override
  Future<bool> update(String pluginId, String surfaceId, Map<String, dynamic> state) async {
    final key = _key(pluginId, surfaceId);
    _pendingStates[key] = Map<String, dynamic>.from(state);
    final view = _webViews[key];
    if (view != null) {
      view.pushState(state);
      return true;
    }
    final game = _flameGames[key];
    if (game is PluginSceneGame) {
      await game.updateState(state);
      return true;
    }
    // Surface 可能还在 push/attach；保留状态，实例注册后立即补发。
    return _host?.surfaceRegistry.find(pluginId, surfaceId) != null;

  }

  @override
  Future<bool> close(String pluginId, String surfaceId) async {
    final navigator = _navigatorKey.currentState;
    _flameGames.remove(_key(pluginId, surfaceId));
    if (navigator != null && navigator.canPop()) navigator.pop();
    return true;
  }

  @override
  Future<bool> event(String pluginId, String surfaceId, Map<String, dynamic> event) async {
    final plugin = _host?.byId(pluginId);
    final runtime = plugin?.runtime;
    if (runtime == null || !runtime.isReady) return false;
    return runtime.sendEvent('surface.event', <String, dynamic>{
      'surfaceId': surfaceId,
      ...event,
    });
  }

  void _registerWebView(String pluginId, String surfaceId, _SurfaceWebViewState state) {
    _webViews[_key(pluginId, surfaceId)] = state;
  }

  void _unregisterWebView(String pluginId, String surfaceId, _SurfaceWebViewState state) {
    final key = _key(pluginId, surfaceId);
    if (identical(_webViews[key], state)) _webViews.remove(key);
  }
}

class PluginWebSurfacePage extends StatefulWidget {
  const PluginWebSurfacePage({
    super.key,
    required this.pluginId,
    required this.surfaceId,
    required this.title,
    required this.html,
    required this.controller,
  });

  final String pluginId;
  final String surfaceId;
  final String title;
  final String html;
  final PluginSurfaceController controller;

  @override
  State<PluginWebSurfacePage> createState() => _SurfaceWebViewState();
}

class _SurfaceWebViewState extends State<PluginWebSurfacePage> {
  late final WebViewController _web;

  @override
  void initState() {
    super.initState();
    widget.controller._registerWebView(widget.pluginId, widget.surfaceId, this);
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('SurfaceBridge', onMessageReceived: (message) {
        try {
          final event = jsonDecode(message.message);
          if (event is Map<String, dynamic>) {
            widget.controller.event(widget.pluginId, widget.surfaceId, event);
          }
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (_) => NavigationDecision.prevent,
      ));
    _load();
  }

  Future<void> _load() async {
    final shim = '''
<script>
window.tsukiro = window.tsukiro || {};
window.tsukiro.event = window.tsukiro.event || (function(){
  const handlers = {};
  return {
    on: (name, fn) => (handlers[name] ||= []).push(fn),
    emit: (name, payload) => SurfaceBridge.postMessage(JSON.stringify(payload || {})),
    _dispatch: (name, payload) => (handlers[name] || []).forEach(fn => { try { fn(payload); } catch (_) {} })
  };
})();
window.__surface_state = (state) => window.tsukiro.event._dispatch('surface.state', state);
</script>
''';
    await _web.loadHtmlString('$shim${widget.html}');
    final pending = widget.controller._pendingStates[
      widget.controller._key(widget.pluginId, widget.surfaceId)
    ];
    if (pending != null) pushState(pending);
  }

  void pushState(Map<String, dynamic> state) {
    final payload = jsonEncode(state).replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    _web.runJavaScript("window.__surface_state(JSON.parse('$payload'));");
  }

  @override
  void dispose() {
    widget.controller._unregisterWebView(widget.pluginId, widget.surfaceId, this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: WebViewWidget(controller: _web),
      );
}
