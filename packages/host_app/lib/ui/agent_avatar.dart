/// 智能体头像。
///
/// ## 为什么用「带前缀的字符串」而不是加几个数据库字段
///
/// 头像有三种形态：名字首字（默认）、emoji、图片文件。
/// 直觉做法是给 `agents` 表加 `avatar_emoji` / `avatar_color` 两列 ——
/// 但那要一次 schema 迁移，而 `avatar_path` 这个字段**本来就在那儿、
/// 一直没人用**。
///
/// 所以复用它，用一个 scheme 前缀区分形态：
///
/// ```text
/// null / ''              名字首字（默认）
/// 'emoji:🦊'             emoji
/// 'file:/data/.../x.png' 图片文件
/// '/data/.../x.png'      图片文件（旧写法，照样认）
/// ```
///
/// 好处：**零迁移**，而且旧的"裸路径"仍然能解析。
/// 代价：这个字段的名字（avatar_path）不再完全准确 —— 但它已经是
/// 一个"头像标识"了，改名要迁移，不值当。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 头像的三种形态。
enum AvatarKind { initial, emoji, file }

/// 解析结果。
class AvatarSpec {
  const AvatarSpec({required this.kind, this.emoji, this.path});

  final AvatarKind kind;
  final String? emoji;
  final String? path;

  /// 从 `avatarPath` 字段解析。
  static AvatarSpec parse(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return const AvatarSpec(kind: AvatarKind.initial);

    if (text.startsWith('emoji:')) {
      final e = text.substring('emoji:'.length).trim();
      if (e.isEmpty) return const AvatarSpec(kind: AvatarKind.initial);
      return AvatarSpec(kind: AvatarKind.emoji, emoji: e);
    }

    final path = text.startsWith('file:') ? text.substring('file:'.length) : text;
    if (path.trim().isEmpty) return const AvatarSpec(kind: AvatarKind.initial);
    return AvatarSpec(kind: AvatarKind.file, path: path.trim());
  }

  /// 编回 `avatarPath` 字段。
  static String encodeEmoji(String emoji) => 'emoji:$emoji';
  static String encodeFile(String path) => 'file:$path';
}

/// 智能体头像。三态自动降级。
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    required this.name,
    this.avatarPath,
    this.size = 32,
  });

  /// 收 name + avatarPath 而不是整个 Agent ——
  /// 消息气泡手里只有这两个值，为了画头像去查一次智能体不值得。
  final String name;
  final String? avatarPath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final spec = AvatarSpec.parse(avatarPath);
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: _content(context, spec),
      ),
    );
  }

  Widget _content(BuildContext context, AvatarSpec spec) {
    switch (spec.kind) {
      case AvatarKind.emoji:
        final t = context.tokens;
        return ColoredBox(
          color: t.primary.withValues(alpha: 0.14),
          child: Center(
            child: Text(
              spec.emoji!,
              style: TextStyle(fontSize: size * 0.54),
              textAlign: TextAlign.center,
            ),
          ),
        );

      case AvatarKind.file:
        final file = File(spec.path!);
        return Image.file(
          file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // **文件被删/读不了时退回首字，而不是显示破图。**
          // 头像坏了不该让整条对话看起来像出了问题。
          errorBuilder: (_, _, _) => _initial(context),
        );

      case AvatarKind.initial:
        return _initial(context);
    }
  }

  Widget _initial(BuildContext context) {
    final t = context.tokens;
    return ColoredBox(
      color: t.primary.withValues(alpha: 0.18),
      child: Center(
        child: Text(
          _initialChar,
          style: TextStyle(
            fontSize: size * 0.42,
            fontWeight: FontWeight.w600,
            color: t.text,
          ),
        ),
      ),
    );
  }
}

extension on AgentAvatar {
  /// 名字首字。用 runes.first 而不是 [0] —— 后者会把 emoji
  /// 或某些中文字截成半个码点，渲染出乱码方块。
  String get _initialChar {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : String.fromCharCode(trimmed.runes.first);
  }
}

/// 可选的头像 emoji。
///
/// **给一组而不是自由输入**：一个自由文本框会让用户输入任意长字符串，
/// 而头像位置只有几十像素。给一组挑好的，既好看又不会破版。
const List<String> avatarEmojis = <String>[
  '🦊', '🐱', '🐶', '🐰', '🐼', '🐨', '🦁', '🐯',
  '🌸', '🌙', '⭐', '🌈', '🍀', '🔥', '❄️', '⚡',
  '🌊', '🍃', '🎐', '🫧', '💠', '🔮', '🎭', '👻',
  '🤖', '👾', '🧊', '🌵', '🍄', '🪐', '☁️', '🕊️',
];
