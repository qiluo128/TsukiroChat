/// 插槽渲染：把插件声明的 UI 画成**原生 Flutter 控件**。
///
/// ## 为什么是原生控件而不是 WebView
///
/// 声明式 UI（`provides.ui`）里的一句话是「一个按钮」，
/// 而不是「一段 HTML」。用原生控件渲染的好处：
///   - 视觉、动效、无障碍与宿主完全一致（插件做的按钮不会长得不一样）
///   - 不需要为每个插槽开一个 WebView（那很重，而且有生命周期问题）
///   - 宿主完全掌控渲染，没有注入面
///
/// 需要**完全自定义**视觉的插件走另一条路：`tsukiro.defineSlot` 返回 HTML，
/// 宿主用 WebView 装（见 [HtmlSlot]）。两条路按需要选。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../providers/plugin_providers.dart';
import '../theme/app_theme.dart';
import 'plugin_native_view.dart';

/// 一个插槽位。
///
/// 放在界面的哪个位置，由调用方决定；插件只知道自己的 `slot` 名字。
class PluginSlot extends ConsumerWidget {
  const PluginSlot({
    super.key,
    required this.slot,
    this.context = const <String, dynamic>{},
    this.axis = Axis.horizontal,
    this.emptyPlaceholder,
  });

  final String slot;

  /// 渲染上下文（供声明里的 `when` 求值）。
  final Map<String, dynamic> context;

  /// 排布方向。工具栏类插槽横向，区块类插槽纵向。
  final Axis axis;

  /// 没有插件占用这个插槽时显示什么。默认什么都不显示。
  final Widget? emptyPlaceholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ══════════════════ 在这里声明自己 ══════════════════
    //
    // **这是「加插槽不用改内核」的落地点。**
    //
    // 界面里写一行 `PluginSlot(slot: 'newpage.thing')`，那个位置就存在了 ——
    // 内核的 knownSlots 只是基线，不再是白名单。
    //
    // 在 build 里做副作用听起来不干净，但 declare 是**幂等**的
    // （Registry 里判了重复），而且它本来就该跟着"界面渲染到哪"走。
    ref.read(slotRegistryProvider).declare(slot);

    final host = ref.watch(pluginHostValueProvider);
    if (host == null) return emptyPlaceholder ?? const SizedBox.shrink();

    // 插件加载/启停会改变插槽内容，所以 watch 一下让界面跟着重建
    ref.watch(pluginHostRevisionProvider);

    final items = host.visibleUi(slot, context: this.context);
    if (items.isEmpty) return emptyPlaceholder ?? const SizedBox.shrink();

    final children = <Widget>[
      for (final item in items)
        _DeclarationWidget(
          key: ValueKey<String>(item.key),
          registered: item,
          host: host,
        ),
    ];

    if (axis == Axis.horizontal) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < children.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 6),
              children[i],
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 6),
          children[i],
        ],
      ],
    );
  }
}

/// 渲染一条声明。
class _DeclarationWidget extends StatefulWidget {
  const _DeclarationWidget({super.key, required this.registered, required this.host});

  final RegisteredUi registered;
  final dynamic host;

  @override
  State<_DeclarationWidget> createState() => _DeclarationWidgetState();
}

class _DeclarationWidgetState extends State<_DeclarationWidget> {
  /// toggle 的本地状态。
  ///
  /// 存在界面而不是插件里：**插件崩了不该让按钮状态丢失**。
  /// 真正的持久化由插件自己负责（收到事件后写它自己的存储）。
  bool _toggleValue = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final decl = widget.registered.declaration;
    final pluginId = widget.registered.pluginId;

    switch (decl.type) {
      // ── 视觉节点 ──
      //
      // 这些和声明式控件不一样：它们不是"按钮/开关"那类语义控件，
      // 而是**画面元素**（粒子、模糊、变换）。
      //
      // 复用运行期 UI 树的渲染器 —— 一套渲染代码，两个来源
      // （清单声明 / 运行期 update），不然两边会长歪。
      case 'particle':
      case 'blur':
      case 'stack':
      case 'transform':
      case 'shape':
        return PluginNativeView(
          // 把插件的配置读进来：声明里的 config.<键> 靠它求值。
          // 少了它，配置项就只是存进库、界面回显，而画面不变。
          root: uiNodeFromDeclaration(
            decl,
            configOf: (key) => widget.host?.configValue(pluginId, key),
          ),
          pluginId: widget.registered.pluginId,
          onEvent: (nodeId, event, payload) =>
              _dispatch(pluginId, decl, <String, dynamic>{'nodeId': nodeId}),
        );

      case 'divider':
        return t.isDark
            ? Container(width: 1, height: 20, color: t.divider)
            : Divider(height: 20, color: t.divider);

      case 'text':
        return _buildText(context, decl);

      case 'button':
        return _buildButton(context, decl, pluginId);

      case 'toggle':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (decl.icon != null) ...<Widget>[
              Icon(pluginIcon(decl.icon!), size: 16, color: t.textMuted),
              const SizedBox(width: 6),
            ],
            Text(decl.label ?? '', style: TextStyle(fontSize: 13, color: t.text)),
            const SizedBox(width: 4),
            Switch(
              value: _toggleValue,
              onChanged: (v) {
                setState(() => _toggleValue = v);
                _dispatch(pluginId, decl, <String, dynamic>{'value': v});
              },
            ),
          ],
        );

      case 'menu-item':
        return ListTile(
          dense: true,
          leading: decl.icon != null ? Icon(pluginIcon(decl.icon!), size: 18) : null,
          title: Text(decl.label ?? '', style: const TextStyle(fontSize: 13.5)),
          onTap: () => _dispatch(pluginId, decl, const <String, dynamic>{}),
        );

      case 'section':
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (decl.label != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: <Widget>[
                        if (decl.icon != null) ...<Widget>[
                          Icon(pluginIcon(decl.icon!), size: 15, color: t.primary),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          decl.label!,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: t.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                for (var i = 0; i < decl.children.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: 8),
                  _DeclarationWidget(
                    registered: RegisteredUi(
                      declaration: decl.children[i],
                      pluginId: pluginId,
                      pluginVersion: widget.registered.pluginVersion,
                    ),
                    host: widget.host,
                  ),
                ],
              ],
            ),
          ),
        );

      // input / select / number / slider：
      // 这些在 Demo 阶段先用一个"未支持"的占位。
      // **不假装能填** —— 一个输入框打不开、或者填了没反应，比明说没实现更糟。
      case 'input':
      case 'select':
      case 'number':
      case 'slider':
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.construction_outlined, size: 14, color: t.textMuted),
              const SizedBox(width: 4),
              Text(
                '${decl.label ?? decl.type}（暂未支持）',
                style: TextStyle(fontSize: 12, color: t.textMuted),
              ),
            ],
          ),
        );

      default:
        // 未知控件类型静默忽略：插件用新版宿主的控件时，
        // 在旧宿主上只是不显示，而不是报错
        return const SizedBox.shrink();
    }
  }

  Widget _buildText(BuildContext context, UiDeclaration decl) {
    final t = context.tokens;
    final binding = decl.binding;
    if (binding == null || binding.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(decl.label ?? '', style: TextStyle(fontSize: 12.5, color: t.textMuted)),
      );
    }

    // **走 provider，不在这里新建 Future。**
    //
    // 原先是每次 build 都 `state.getState(...)` —— 两个问题：
    //   1. 每次都造一个新 Future，FutureBuilder 回到"等待中"，界面会闪
    //   2. **插件改状态时没人通知它重跑**，于是「只更新了一次就不动了」
    //
    // Riverpod 会缓存同一个 family 实例；插件 setState 时
    // AppAgentState.onChanged 会 invalidate 它，这里才重新取值。
    return Consumer(
      builder: (context, ref, _) {
        const fallback = <String, dynamic>{'mood': 50, 'opinion': '还在了解中'};
        final snapshot = ref.watch(agentStateProvider(widget.registered.pluginId));
        final data = (snapshot.hasError || snapshot.valueOrNull == null)
            ? fallback
            : snapshot.valueOrNull!;
        final value = _bindingValue(data, binding);
        final text = value == null ? '${decl.label ?? ''}：读取中…' : '${decl.label ?? ''}：$value';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(text, style: TextStyle(fontSize: 12.5, color: t.textMuted)),
        );
      },
    );
  }

  Object? _bindingValue(Map<String, dynamic> state, String binding) {
    final parts = binding.split('.');
    if (parts.length < 2) return null;
    final key = parts[1];
    final raw = state[key];
    if (key == 'mood' && parts.length > 2 && parts[2] == 'label') {
      final mood = (raw as num?)?.toInt() ?? 50;
      if (mood >= 80) return '很好（$mood/100）';
      if (mood >= 60) return '不错（$mood/100）';
      if (mood >= 40) return '平静（$mood/100）';
      return '低落（$mood/100）';
    }
    return raw;
  }

  Widget _buildButton(BuildContext context, UiDeclaration decl, String pluginId) {
    final t = context.tokens;
    final icon = decl.icon != null ? pluginIcon(decl.icon!) : null;
    final label = decl.label;

    // 有文字就做成 chip（工具栏里更常见），没文字就纯图标按钮
    final child = label == null || label.isEmpty
        ? IconButton(
            icon: Icon(icon ?? Icons.extension, size: 20, color: t.text),
            tooltip: decl.tooltip,
            onPressed: () => _dispatch(pluginId, decl, const <String, dynamic>{}),
          )
        : ActionChip(
            avatar: icon != null ? Icon(icon, size: 15, color: t.primary) : null,
            label: Text(label),
            onPressed: () => _dispatch(pluginId, decl, const <String, dynamic>{}),
            backgroundColor: t.surface,
            side: BorderSide(color: t.divider),
            labelStyle: TextStyle(fontSize: 12.5, color: t.text),
            visualDensity: VisualDensity.compact,
            tooltip: decl.tooltip,
          );

    return child;
  }

  /// 把点击发给插件。
  ///
  /// 插件没在跑时给一条明确提示 —— 点了毫无反应是最让人困惑的。
  void _dispatch(String pluginId, UiDeclaration decl, Map<String, dynamic> payload) {
    final event = decl.onClickEvent ?? 'ui.click';
    final ok = widget.host.dispatchUiEvent(
      pluginId,
      event,
      payload: <String, dynamic>{'id': decl.id, ...payload},
    );

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('插件还没启动好，稍后再试'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}

/// 把 `lucide:languages` 这类图标名映射到 Material 图标。
///
/// 为什么不做成"完整支持 lucide"：那要引入整个图标集（几百 KB 字体）。
/// 这里只覆盖 demo 插件会用到的那批，其余给一个通用图标 ——
/// **未知图标显示成通用图标，而不是报错或不显示**，
/// 这样插件作者用了新图标名也不会让按钮整个消失。
IconData pluginIcon(String name) {
  final key = name.contains(':') ? name.split(':').last : name;
  return _iconMap[key] ?? Icons.extension_outlined;
}

const Map<String, IconData> _iconMap = <String, IconData>{
  'languages': Icons.translate,
  'translate': Icons.translate,
  'clock': Icons.schedule,
  'time': Icons.schedule,
  'timer': Icons.timer_outlined,
  'calendar': Icons.calendar_today_outlined,
  'settings': Icons.settings_outlined,
  'sliders': Icons.tune,
  'sparkles': Icons.auto_awesome,
  'star': Icons.star_outline,
  'heart': Icons.favorite_outline,
  'smile': Icons.sentiment_satisfied_outlined,
  'zap': Icons.bolt,
  'sun': Icons.light_mode_outlined,
  'moon': Icons.dark_mode_outlined,
  'palette': Icons.palette_outlined,
  'image': Icons.image_outlined,
  'music': Icons.music_note_outlined,
  'search': Icons.search,
  'plus': Icons.add,
  'minus': Icons.remove,
  'check': Icons.check,
  'x': Icons.close,
  'info': Icons.info_outline,
  'alert': Icons.warning_amber_outlined,
  'message': Icons.chat_bubble_outline,
  'mic': Icons.mic_none,
  'copy': Icons.copy_outlined,
  'share': Icons.share_outlined,
  'download': Icons.download_outlined,
  'trash': Icons.delete_outline,
  'refresh': Icons.refresh,
  'gamepad': Icons.sports_esports_outlined,
  'dice': Icons.casino_outlined,
  'flower': Icons.local_florist_outlined,
  'book': Icons.menu_book_outlined,
  'brain': Icons.psychology_outlined,
  'activity': Icons.monitor_heart_outlined,
};

/// 用 WebView 渲染插件返回的 HTML。
///
/// 给需要完全自定义视觉的插件用（`tsukiro.defineSlot` 返回 HTML）。
/// **这个 WebView 不带 Bridge** —— 它只显示静态结果，
/// 交互仍然走声明式 UI 那条路。
class HtmlSlot extends StatefulWidget {
  const HtmlSlot({super.key, required this.html, this.height});

  final String html;
  final double? height;

  @override
  State<HtmlSlot> createState() => _HtmlSlotState();
}

class _HtmlSlotState extends State<HtmlSlot> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HtmlSlot old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _load();
  }

  Future<void> _load() async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.transparent);
    // 沙箱：连静态 HTML 也挡掉一切导航，防止插件用它当跳板
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (_) => NavigationDecision.prevent,
    ));
    await controller.loadHtmlString(widget.html);
    if (mounted) setState(() => _controller = controller);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return SizedBox(height: widget.height ?? 60);
    return SizedBox(
      height: widget.height ?? 60,
      child: WebViewWidget(controller: controller),
    );
  }
}
