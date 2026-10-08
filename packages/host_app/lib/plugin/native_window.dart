/// 原生窗口的宿主实现。
///
/// 把插件送来的 UI 树挂到一个真实的路由页面上，
/// 并支持后续 update / close。
///
/// 见 `docs/21-native-ui-windows.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

import '../ui/plugin_native_view.dart';

/// 一个开着（或开过）的窗口。
class _WindowState {
  _WindowState({
    required this.pluginId,
    required this.windowId,
    required String title,
    required UiNode root,
  })  : title = ValueNotifier<String>(title),
        root = ValueNotifier<UiNode>(root);

  final String pluginId;
  final String windowId;

  /// 用 ValueNotifier 而不是重建路由：`update` 应该只重画内容，
  /// 不该让整个页面重新 push（那会闪一下，还会打断滚动位置）。
  final ValueNotifier<String> title;
  final ValueNotifier<UiNode> root;

  Route<void>? route;
}

class AppNativeWindow implements HostNativeWindow {
  AppNativeWindow({
    required this.navigatorKey,
    required this.dispatchEvent,
  });

  /// 宿主的路由入口。原生窗口挂在这上面。
  final GlobalKey<NavigatorState> navigatorKey;

  /// 把交互事件发回插件。返回 false 表示插件没在跑。
  final bool Function(String pluginId, String event, Map<String, dynamic> payload)
      dispatchEvent;

  final Map<String, _WindowState> _windows = <String, _WindowState>{};

  static String _keyOf(String pluginId, String windowId) => '$pluginId#$windowId';

  @override
  bool isOpen(String pluginId, String windowId) =>
      _windows.containsKey(_keyOf(pluginId, windowId));

  @override
  Future<bool> open(
    String pluginId,
    String windowId, {
    String? title,
    required UiNode root,
  }) async {
    final key = _keyOf(pluginId, windowId);
    final existing = _windows[key];

    // 已经开着 → 替换内容。插件重开自己的窗口是正常操作，
    // 不该逼它先 close 再 open（那会闪一下）。
    if (existing != null) {
      if (title != null) existing.title.value = title;
      existing.root.value = root;
      return true;
    }

    final navigator = navigatorKey.currentState;
    if (navigator == null) return false;

    final state = _WindowState(
      pluginId: pluginId,
      windowId: windowId,
      title: title ?? '',
      root: root,
    );
    _windows[key] = state;

    final route = MaterialPageRoute<void>(
      builder: (_) => _NativeWindowPage(
        state: state,
        onEvent: (nodeId, event, payload) => dispatchEvent(
          pluginId,
          event,
          <String, dynamic>{
            'windowId': windowId,
            if (nodeId != null) 'nodeId': nodeId, // ignore: use_null_aware_elements
            ...payload,
          },
        ),
      ),
    );
    state.route = route;

    // 用户按返回键关掉时也要把记录清掉，否则插件的
    // `open` 会以为窗口还开着，然后 update 到一个不存在的页面。
    unawaited(navigator.push(route).then((_) {
      if (identical(_windows[key], state)) _windows.remove(key);
    }));
    return true;
  }

  @override
  Future<bool> update(
    String pluginId,
    String windowId, {
    String? title,
    UiNode? root,
  }) async {
    final state = _windows[_keyOf(pluginId, windowId)];
    if (state == null) return false;
    if (title != null) state.title.value = title;
    if (root != null) state.root.value = root;
    return true;
  }

  @override
  Future<bool> close(String pluginId, String windowId) async {
    final key = _keyOf(pluginId, windowId);
    final state = _windows.remove(key);
    if (state == null) return false;

    final navigator = navigatorKey.currentState;
    final route = state.route;
    if (navigator != null && route != null) {
      // 用 removeRoute 而不是 pop：多个窗口叠着时 pop 会关错那个
      navigator.removeRoute(route);
    }
    return true;
  }
}

/// 窗口页面。只订阅两个 ValueNotifier，不做别的。
class _NativeWindowPage extends StatelessWidget {
  const _NativeWindowPage({required this.state, required this.onEvent});

  final _WindowState state;
  final void Function(String? nodeId, String event, Map<String, dynamic> payload) onEvent;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: state.title,
      builder: (context, title, _) => Scaffold(
        appBar: AppBar(
          title: Text(title.isEmpty ? '插件窗口' : title),
          // 明确标出这是插件开的窗口 —— 用户该知道这块界面来自插件
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0),
            child: const SizedBox.shrink(),
          ),
        ),
        body: ValueListenableBuilder<UiNode>(
          valueListenable: state.root,
          builder: (context, root, _) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: PluginNativeView(
              root: root,
              pluginId: state.pluginId,
              onEvent: onEvent,
            ),
          ),
        ),
      ),
    );
  }
}
