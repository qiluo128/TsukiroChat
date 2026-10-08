/// 原生窗口：把插件送来的 [UiNode] 树渲染成 Flutter 控件。
///
/// ## 这一层的价值
///
/// 插件想画一个「礼物展柜」（网格 + 卡片 + 图片），以前只能开 WebView
/// 或 Flame —— 对一个网格列表来说都太重，而且 WebView 里的颜色
/// **永远接不上宿主主题**。
///
/// 现在它送来一棵树，宿主用 Flutter 画。于是：
///
///   - 深浅色切换自动生效
///   - 主题包换色自动生效
///   - 圆角、间距、字体全是设计 token
///   - 不引入 WebView 的内存开销，也不引入 Flame
///
/// **插件拿不到 Flutter**，只能描述"我要一个三列网格"。
/// 这不是限制，是上面那些一致性的来源。
library;

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

import '../theme/app_theme.dart';
import 'plugin_slot.dart' show pluginIcon;

/// 渲染一棵插件 UI 树。
class PluginNativeView extends StatelessWidget {
  const PluginNativeView({
    super.key,
    required this.root,
    required this.pluginId,
    required this.onEvent,
  });

  final UiNode root;
  final String pluginId;

  /// 节点被交互时回调。
  ///
  /// [nodeId] 是插件给的标识（可能为 null），[event] 是 `onTap` 指定的
  /// 事件名（缺省 `ui.click`）。
  final void Function(String? nodeId, String event, Map<String, dynamic> payload) onEvent;

  @override
  Widget build(BuildContext context) => _build(context, root);

  // ═══════════════════════════ 分发 ═══════════════════════════

  Widget _build(BuildContext context, UiNode node) {
    switch (node.type) {
      case UiNodeType.column:
        return _column(context, node);
      case UiNodeType.row:
        return _row(context, node);
      case UiNodeType.grid:
        return _grid(context, node);
      case UiNodeType.list:
        return _list(context, node);
      case UiNodeType.spacer:
        return _spacer(context, node);
      case UiNodeType.divider:
        return Divider(height: 1, color: context.tokens.divider);

      case UiNodeType.text:
        return _text(context, node);
      case UiNodeType.image:
        return _image(context, node);
      case UiNodeType.icon:
        return Icon(
          pluginIcon(node.icon ?? 'circle'),
          size: _iconSize(node.size),
          color: _color(context, node.emphasis),
        );
      case UiNodeType.badge:
        return _badge(context, node);
      case UiNodeType.progress:
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: node.progress,
            minHeight: 6,
            backgroundColor: context.tokens.divider,
            valueColor: AlwaysStoppedAnimation<Color>(context.tokens.primary),
          ),
        );

      case UiNodeType.button:
        return _button(context, node);
      case UiNodeType.toggle:
        return _toggle(context, node);
      case UiNodeType.card:
        return _card(context, node);
      case UiNodeType.section:
        return _section(context, node);

      case UiNodeType.unknown:
        // **不静默跳过**：插件用新版宿主的控件时，
        // 让作者看见"这个宿主不认识它"，而不是画面莫名缺一块
        return _unsupported(context, node);
    }
  }

  // ═══════════════════════════ 布局 ═══════════════════════════

  Widget _column(BuildContext context, UiNode node) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: _crossAlign(node.align),
      children: _withGaps(context, node.children, node.spacing, vertical: true),
    );
  }

  Widget _row(BuildContext context, UiNode node) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: _mainAlign(node.align),
      children: _withGaps(context, node.children, node.spacing ?? 8, vertical: false),
    );
  }

  Widget _grid(BuildContext context, UiNode node) {
    final columns = node.columns ?? 2;
    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: node.spacing ?? 10,
      crossAxisSpacing: node.spacing ?? 10,
      // 卡片是「图 + 两行字」，比例接近方形。
      // 让插件调宽高会引入一套布局语言，不如宿主给个合适值。
      childAspectRatio: 0.82,
      children: node.children.map((c) => _build(context, c)).toList(growable: false),
    );
  }

  Widget _list(BuildContext context, UiNode node) {
    // 用 Column 而不是 ListView：外层通常已经在可滚动区域里，
    // 嵌套可滚动会打架（而且 grid 也用 shrinkWrap 保持同一策略）。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _withGaps(context, node.children, node.spacing ?? 8, vertical: true),
    );
  }

  Widget _spacer(BuildContext context, UiNode node) {
    final gap = node.spacing ?? context.tokens.spacing.section.toDouble();
    if ((node.flex ?? 0) > 0) return const Spacer();
    return SizedBox(height: gap);
  }

  // ═══════════════════════════ 内容 ═══════════════════════════

  Widget _text(BuildContext context, UiNode node) {
    final t = context.tokens;
    final hasSubtitle = (node.subtitle ?? '').isNotEmpty;
    final title = Text(
      node.text ?? '',
      style: TextStyle(
        fontSize: _fontSize(node.size),
        color: _color(context, node.emphasis),
        fontWeight: node.emphasis == UiEmphasis.primary ? FontWeight.w600 : null,
      ),
    );
    if (!hasSubtitle) return title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        title,
        const SizedBox(height: 2),
        Text(
          node.subtitle!,
          style: TextStyle(fontSize: t.font.caption.toDouble(), color: t.textMuted),
        ),
      ],
    );
  }

  Widget _image(BuildContext context, UiNode node) {
    final url = node.image;
    if (url == null || url.isEmpty) {
      return _imagePlaceholder(context, Icons.image_outlined);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.tokens.radius.card.toDouble()),
      child: AspectRatio(
        aspectRatio: 1,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          // **加载失败要有可见的反馈**：插件给了一个坏链接时，
          // 静默留白会让人以为是宿主的问题
          errorBuilder: (_, _, _) =>
              _imagePlaceholder(context, Icons.broken_image_outlined),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _imagePlaceholder(context, Icons.hourglass_empty);
          },
        ),
      ),
    );
  }

  Widget _imagePlaceholder(BuildContext context, IconData icon) => Container(
        color: context.tokens.divider,
        alignment: Alignment.center,
        child: Icon(icon, size: 22, color: context.tokens.textMuted),
      );

  Widget _badge(BuildContext context, UiNode node) {
    final t = context.tokens;
    final color = _color(context, node.emphasis);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        node.text ?? '',
        style: TextStyle(fontSize: t.font.caption.toDouble(), color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  // ═══════════════════════════ 交互 ═══════════════════════════

  Widget _button(BuildContext context, UiNode node) {
    final t = context.tokens;
    final label = Text(node.text ?? '');
    final icon = node.icon == null ? null : Icon(pluginIcon(node.icon!), size: 18);

    void fire() => onEvent(node.id, node.onTap ?? 'ui.click', <String, dynamic>{});

    if (_isDanger(context, node)) {
      return OutlinedButton.icon(
        onPressed: node.enabled ? fire : null,
        icon: icon ?? const SizedBox.shrink(),
        label: label,
        style: OutlinedButton.styleFrom(
          foregroundColor: t.danger,
          side: BorderSide(color: t.danger.withValues(alpha: 0.4)),
        ),
      );
    }
    if (node.emphasis == UiEmphasis.muted) {
      return TextButton(onPressed: node.enabled ? fire : null, child: label);
    }
    return FilledButton(
      onPressed: node.enabled ? fire : null,
      style: FilledButton.styleFrom(
        backgroundColor: node.emphasis == UiEmphasis.primary ? t.primary : t.surface,
        foregroundColor: node.emphasis == UiEmphasis.primary ? t.onPrimary : t.text,
        side: node.emphasis == UiEmphasis.primary ? BorderSide.none : BorderSide(color: t.divider),
      ),
      child: icon == null
          ? label
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[icon, const SizedBox(width: 6), label],
            ),
    );
  }

  Widget _toggle(BuildContext context, UiNode node) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(node.text ?? '', style: TextStyle(fontSize: context.tokens.font.body.toDouble())),
      subtitle: (node.subtitle ?? '').isEmpty ? null : Text(node.subtitle!),
      value: node.value ?? false,
      onChanged: node.enabled
          ? (v) => onEvent(node.id, node.onTap ?? 'ui.click', <String, dynamic>{'value': v})
          : null,
    );
  }

  Widget _card(BuildContext context, UiNode node) {
    final t = context.tokens;
    final hasImage = (node.image ?? '').isNotEmpty;
    final hasText = (node.text ?? '').isNotEmpty || (node.subtitle ?? '').isNotEmpty;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (hasImage) _image(context, node),
        if (hasImage && hasText) const SizedBox(height: 8),
        if (hasText)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: _text(context, node),
          ),
        if (node.children.isNotEmpty) ...<Widget>[
          if (hasImage || hasText) const SizedBox(height: 8),
          ...node.children.map((c) => _build(context, c)),
        ],
      ],
    );

    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: node.enabled && node.onTap != null
            ? () => onEvent(node.id, node.onTap!, <String, dynamic>{})
            : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: content,
        ),
      ),
    );
  }

  Widget _section(BuildContext context, UiNode node) {
    final t = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if ((node.text ?? '').isNotEmpty) ...<Widget>[
          Text(
            node.text!,
            style: TextStyle(
              fontSize: t.font.title.toDouble(),
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          const SizedBox(height: 10),
        ],
        ...node.children.map((c) => _build(context, c)),
      ],
    );
  }

  /// 不认识的控件。
  ///
  /// **显示占位而不是跳过** —— 跳过的话插件作者只会看到画面莫名少一块，
  /// 然后去查自己的代码。
  Widget _unsupported(BuildContext context, UiNode node) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: t.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.help_outline, size: 14, color: t.textMuted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '这个版本不支持控件「${node.text ?? node.id ?? '?'}」',
              style: TextStyle(fontSize: t.font.caption.toDouble(), color: t.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════ 工具 ═══════════════════════════

  Color _color(BuildContext context, UiEmphasis e) {
    final t = context.tokens;
    switch (e) {
      case UiEmphasis.muted:
        return t.textMuted;
      case UiEmphasis.primary:
        return t.primary;
      case UiEmphasis.danger:
        return t.danger;
      case UiEmphasis.success:
        return t.success;
      case UiEmphasis.normal:
        return t.text;
    }
  }

  bool _isDanger(BuildContext context, UiNode node) =>
      node.emphasis == UiEmphasis.danger;

  double _fontSize(UiSize size) {
    switch (size) {
      case UiSize.sm:
        return 12.5;
      case UiSize.lg:
        return 20;
      case UiSize.md:
        return 16;
    }
  }

  double _iconSize(UiSize size) {
    switch (size) {
      case UiSize.sm:
        return 16;
      case UiSize.lg:
        return 32;
      case UiSize.md:
        return 22;
    }
  }

  CrossAxisAlignment _crossAlign(UiAlign a) {
    switch (a) {
      case UiAlign.center:
        return CrossAxisAlignment.center;
      case UiAlign.end:
        return CrossAxisAlignment.end;
      case UiAlign.spaceBetween:
      case UiAlign.start:
        return CrossAxisAlignment.start;
    }
  }

  MainAxisAlignment _mainAlign(UiAlign a) {
    switch (a) {
      case UiAlign.center:
        return MainAxisAlignment.center;
      case UiAlign.end:
        return MainAxisAlignment.end;
      case UiAlign.spaceBetween:
        return MainAxisAlignment.spaceBetween;
      case UiAlign.start:
        return MainAxisAlignment.start;
    }
  }

  /// 按子节点的 `flex` 决定要不要包 Expanded，并在中间插空隙。
  ///
  /// **空隙也要按轴来**：Column 里插 `width` 是多余的，
  /// Row 里插 `height` 会影响交叉轴对齐。
  List<Widget> _withGaps(
    BuildContext context,
    Iterable<UiNode> nodes,
    double? gap, {
    required bool vertical,
  }) {
    final list = nodes.toList(growable: false);
    if (list.isEmpty) return const <Widget>[];
    final g = gap ?? 8;
    final out = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      if (i > 0) {
        out.add(vertical ? SizedBox(height: g) : SizedBox(width: g));
      }
      final child = _build(context, list[i]);
      // flex 只在 Column/Row 里有意义；别的容器忽略它
      final flex = list[i].flex ?? 0;
      out.add(flex > 0 ? Expanded(flex: flex, child: child) : child);
    }
    return out;
  }
}
