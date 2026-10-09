/// 聊天背景。
///
/// 和头像同一套思路：**用一个带 scheme 的字符串**，不加表列、不做迁移。
///
/// ```text
/// null / '' / 'default'          跟随主题
/// 'color:#RRGGBB'                纯色
/// 'gradient:#RRGGBB,#RRGGBB'     纵向渐变
/// 'file:/data/.../chat.png'      背景图
/// ```
///
/// 存设置表（全局一份）。做成"每个智能体一份"是下一步的事 ——
/// 那需要按 agentId 分键，而现在的设置表已经是 KV，改起来很小。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';

/// 背景的四种形态。
enum ChatBackgroundKind { theme, color, gradient, image }

class ChatBackground {
  const ChatBackground({
    required this.kind,
    this.colors = const <Color>[],
    this.path,
  });

  final ChatBackgroundKind kind;
  final List<Color> colors;
  final String? path;

  static const ChatBackground followTheme =
      ChatBackground(kind: ChatBackgroundKind.theme);

  /// 解析设置里存的值。
  ///
  /// **解不开就退回主题**，不抛错 —— 一个坏掉的背景值不该让聊天页打不开。
  static ChatBackground parse(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty || text == 'default') return followTheme;

    if (text.startsWith('color:')) {
      final c = _parseHex(text.substring('color:'.length));
      return c == null ? followTheme : ChatBackground(kind: ChatBackgroundKind.color, colors: <Color>[c]);
    }

    if (text.startsWith('gradient:')) {
      final parts = text.substring('gradient:'.length).split(',');
      final parsed = parts.map(_parseHex).whereType<Color>().toList(growable: false);
      if (parsed.length < 2) return followTheme;
      return ChatBackground(kind: ChatBackgroundKind.gradient, colors: parsed);
    }

    final path = text.startsWith('file:') ? text.substring('file:'.length) : text;
    if (path.trim().isEmpty) return followTheme;
    return ChatBackground(kind: ChatBackgroundKind.image, path: path.trim());
  }

  static String encodeColor(Color c) =>
      'color:#${_hex(c)}';

  static String encodeGradient(Color a, Color b) =>
      'gradient:#${_hex(a)},#${_hex(b)}';

  static String encodeImage(String path) => 'file:$path';

  static String _hex(Color c) =>
      ((c.r * 255).round() << 16 | (c.g * 255).round() << 8 | (c.b * 255).round())
          .toRadixString(16)
          .padLeft(6, '0')
          .toUpperCase();

  static Color? _parseHex(String raw) {
    var text = raw.trim();
    if (text.startsWith('#')) text = text.substring(1);
    if (text.length == 3) {
      text = '${text[0]}${text[0]}${text[1]}${text[1]}${text[2]}${text[2]}';
    }
    if (text.length != 6) return null;
    final v = int.tryParse(text, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  /// 装在消息列表背后的那层。
  ///
  /// 返回 null 表示"别加任何装饰，用主题的"。
  Widget? buildLayer(BuildContext context) {
    switch (kind) {
      case ChatBackgroundKind.theme:
        return null;
      case ChatBackgroundKind.color:
        return ColoredBox(color: colors.first);
      case ChatBackgroundKind.gradient:
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: colors,
            ),
          ),
        );
      case ChatBackgroundKind.image:
        final file = File(path!);
        return Image.file(
          file,
          fit: BoxFit.cover,
          // 图被删了就**悄悄退回主题**，不显示"图片加载失败"
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
    }
  }
}

/// 背景设置。
class AppearanceKeys {
  static const String chatBackground = 'appearance.chat.background';
}

/// 当前聊天背景。
///
/// 用 `StateNotifier` 而不是 FutureProvider：改背景要**立刻生效**，
/// 不该等一次重新读取。
final chatBackgroundProvider =
    StateNotifierProvider<ChatBackgroundNotifier, ChatBackground>((ref) {
  return ChatBackgroundNotifier(ref);
});

class ChatBackgroundNotifier extends StateNotifier<ChatBackground> {
  ChatBackgroundNotifier(this._ref) : super(ChatBackground.followTheme) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final repos = await _ref.read(reposProvider.future);
      final raw = await repos.settings.get(AppearanceKeys.chatBackground);
      if (!mounted) return;
      state = ChatBackground.parse(raw);
    } catch (_) {
      // 读不出来就用主题默认 —— 背景坏了不该让聊天页白屏
    }
  }

  /// 设置并持久化。传 null 表示恢复主题默认。
  Future<void> set(ChatBackground? background) async {
    state = background ?? ChatBackground.followTheme;
    final repos = await _ref.read(reposProvider.future);
    await repos.settings.set(
      AppearanceKeys.chatBackground,
      _encode(state),
    );
  }

  static String _encode(ChatBackground b) {
    switch (b.kind) {
      case ChatBackgroundKind.theme:
        return 'default';
      case ChatBackgroundKind.color:
        return ChatBackground.encodeColor(b.colors.first);
      case ChatBackgroundKind.gradient:
        return ChatBackground.encodeGradient(b.colors.first, b.colors.last);
      case ChatBackgroundKind.image:
        return ChatBackground.encodeImage(b.path!);
    }
  }
}

/// 可选的背景色。
const List<Color> chatBackgroundColors = <Color>[
  Color(0xFFF5FBFC),
  Color(0xFFFFF7F0),
  Color(0xFFF3F0FF),
  Color(0xFFEDF7F0),
  Color(0xFFFDF2F6),
  Color(0xFF10202A),
  Color(0xFF1B2A38),
  Color(0xFF2A1F2E),
];

/// 可选的渐变对（浅→深）。
const List<List<Color>> chatBackgroundGradients = <List<Color>>[
  <Color>[Color(0xFFE8F6FB), Color(0xFFF7FBFF)],
  <Color>[Color(0xFFFFF1E6), Color(0xFFFDF7F0)],
  <Color>[Color(0xFFEDE9FF), Color(0xFFF8F6FF)],
  <Color>[Color(0xFFE6F5EA), Color(0xFFF5FBF7)],
  <Color>[Color(0xFF1B2A38), Color(0xFF0E1A22)],
];
