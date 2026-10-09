/// 换头像 / 换背景的选择面板。
///
/// 两处共用，所以抽出来而不是各写一遍 —— 否则「emoji 网格」和
/// 「相册选图」这两套会长出不同的行为。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/media_store.dart';
import '../theme/app_theme.dart';
import 'agent_avatar.dart';
import 'chat_background.dart';

/// 让用户选一个头像。返回要写进 `Agent.avatarPath` 的值；
/// 返回 null 表示用户取消（**不是**"恢复默认"）。
///
/// 恢复默认用返回 `AvatarChoice.reset` 表达。
sealed class AvatarChoice {
  const AvatarChoice();
}

class AvatarEmoji extends AvatarChoice {
  const AvatarEmoji(this.emoji);
  final String emoji;
}

class AvatarFile extends AvatarChoice {
  const AvatarFile(this.path);
  final String path;
}

class AvatarReset extends AvatarChoice {
  const AvatarReset();
}

/// 弹出头像选择面板。
Future<AvatarChoice?> showAvatarPicker(
  BuildContext context, {
  required MediaStore media,
  required String agentId,
  String? current,
}) async {
  final t = context.tokens;

  return showModalBottomSheet<AvatarChoice>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('换个头像', style: TextStyle(fontSize: t.font.title.toDouble(), fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),

            // ── emoji ──
            SizedBox(
              height: 168,
              child: GridView.count(
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: <Widget>[
                  for (final e in avatarEmojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.pop(ctx, AvatarEmoji(e)),
                      child: Center(child: Text(e, style: const TextStyle(fontSize: 26))),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 4),

            // ── 相册 ──
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_library_outlined, size: 20),
              title: const Text('从相册选一张'),
              subtitle: const Text('会复制到应用目录，删掉相册里的原图也不影响',
                  style: TextStyle(fontSize: 12)),
              onTap: () async {
                final picked = await _pickImage();
                if (picked == null) {
                  if (ctx.mounted) Navigator.pop(ctx);
                  return;
                }
                try {
                  final saved = await media.saveAvatar(
                    agentId: agentId,
                    sourcePath: picked.path,
                  );
                  if (ctx.mounted) Navigator.pop(ctx, AvatarFile(saved));
                } catch (e) {
                  // **必须 catch** —— 让异常逃逸的话面板关不掉，
                  // 用户会以为点坏了
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    _toast(context, '保存头像失败：$e');
                  }
                }
              },
            ),

            // 已经设过头像才给"恢复默认" —— 没设过的时候这一项没意义
            if ((current ?? '').isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.restart_alt, size: 20, color: t.danger),
                title: Text('恢复默认', style: TextStyle(color: t.danger)),
                subtitle: const Text('改回显示名字的第一个字', style: TextStyle(fontSize: 12)),
                onTap: () => Navigator.pop(ctx, const AvatarReset()),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 弹出聊天背景选择面板。
Future<ChatBackground?> showChatBackgroundPicker(
  BuildContext context, {
  required MediaStore media,
  required ChatBackground current,
}) async {
  final t = context.tokens;

  return showModalBottomSheet<ChatBackground>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('聊天背景', style: TextStyle(fontSize: t.font.title.toDouble(), fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),

              Text('纯色', style: TextStyle(fontSize: t.font.caption.toDouble(), color: t.textMuted)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  for (final c in chatBackgroundColors)
                    _Swatch(
                      color: c,
                      selected: current.kind == ChatBackgroundKind.color &&
                          current.colors.first.toARGB32() == c.toARGB32(),
                      onTap: () => Navigator.pop(
                        ctx,
                        ChatBackground(kind: ChatBackgroundKind.color, colors: <Color>[c]),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 16),
              Text('渐变', style: TextStyle(fontSize: t.font.caption.toDouble(), color: t.textMuted)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  for (final g in chatBackgroundGradients)
                    _Swatch(
                      gradient: g,
                      selected: current.kind == ChatBackgroundKind.gradient &&
                          current.colors.first.toARGB32() == g.first.toARGB32(),
                      onTap: () => Navigator.pop(
                        ctx,
                        ChatBackground(kind: ChatBackgroundKind.gradient, colors: g),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 16),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.image_outlined, size: 20),
                title: const Text('用自己的图片'),
                onTap: () async {
                  final picked = await _pickImage();
                  if (picked == null) {
                    if (ctx.mounted) Navigator.pop(ctx);
                    return;
                  }
                  try {
                    final saved = await media.saveBackground(sourcePath: picked.path);
                    if (ctx.mounted) {
                      Navigator.pop(
                        ctx,
                        ChatBackground(kind: ChatBackgroundKind.image, path: saved),
                      );
                    }
                  } catch (e) {
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                      _toast(context, '保存背景失败：$e');
                    }
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt, size: 20),
                title: const Text('跟随主题'),
                onTap: () => Navigator.pop(ctx, ChatBackground.followTheme),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 选图。
///
/// **失败返回 null 而不是抛** —— 用户按返回键取消是正常操作，
/// 不该变成一个异常往上冒。
Future<XFile?> _pickImage() async {
  try {
    return await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // 头像/背景都不需要原图：4096px 的照片既慢又占地方
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
  } catch (_) {
    return null;
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({this.color, this.gradient, required this.selected, required this.onTap});

  final Color? color;
  final List<Color>? gradient;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: color,
          gradient: gradient == null
              ? null
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: gradient!,
                ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? t.primary : t.divider,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: 18, color: t.onPrimary)
            : null,
      ),
    );
  }
}

/// 文件是否还在（背景/头像渲染前的廉价检查）。
bool mediaFileExists(String? path) =>
    path != null && path.isNotEmpty && File(path).existsSync();
