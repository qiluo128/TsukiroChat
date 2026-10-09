/// 设置。
///
/// 信息架构见 `docs/18-agent-and-memory.md` §5：
/// 模型相关的一切都收在「模型配置」一个入口里，不让用户在设置首页
/// 面对一堆平级的技术选项。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import '../../providers/plugin_providers.dart';
import '../../providers/theme_provider.dart';
import '../plugin_slot.dart';
import 'plugin_page.dart';
import '../../theme/app_theme.dart';
import '../appearance_pickers.dart';
import '../chat_background.dart';
import 'model_config_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final providers = ref.watch(providerListProvider).valueOrNull ?? const [];
    final usable = providers.where((p) => p.isUsable).length;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: <Widget>[
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('模型配置'),
            subtitle: Text(
              usable > 0 ? '$usable 个可用服务商' : '还没配置，点这里添加',
              style: TextStyle(
                fontSize: 12.5,
                color: usable > 0 ? t.textMuted : t.danger,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ModelConfigPage()),
            ),
          ),

          Divider(height: 24, color: t.divider, indent: t.spacing.page.toDouble()),

          // 插件插槽：设置页分区。插件可以往这里塞自己的设置界面。
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: const PluginSlot(slot: 'settings.sections', axis: Axis.vertical),
          ),

          const _SectionTitle('插件'),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('插件管理'),
            subtitle: Consumer(
              builder: (context, ref, _) {
                final host = ref.watch(pluginHostValueProvider);
                ref.watch(pluginHostRevisionProvider);
                return Text(
                  host == null
                      ? '正在启动…'
                      : '${host.plugins.length} 个已安装 · ${host.runningCount} 个运行中',
                  style: const TextStyle(fontSize: 12.5),
                );
              },
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PluginPage()),
            ),
          ),

          Divider(height: 24, color: t.divider, indent: t.spacing.page.toDouble()),

          const _SectionTitle('外观'),
          Consumer(
            builder: (context, ref, _) {
              final pref =
                  ref.watch(themePreferenceProvider).valueOrNull ?? ThemePreference.system;
              return ListTile(
                leading: Icon(switch (pref) {
                  ThemePreference.system => Icons.brightness_auto_outlined,
                  ThemePreference.light => Icons.light_mode_outlined,
                  ThemePreference.dark => Icons.dark_mode_outlined,
                }),
                title: const Text('主题'),
                subtitle: Text(pref.label, style: const TextStyle(fontSize: 12.5)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _pickTheme(context, ref, pref),
              );
            },
          ),

          // ── 聊天背景 ──
          Consumer(
            builder: (context, ref, _) {
              final bg = ref.watch(chatBackgroundProvider);
              return ListTile(
                leading: const Icon(Icons.wallpaper_outlined),
                title: const Text('聊天背景'),
                subtitle: Text(_backgroundLabel(bg), style: const TextStyle(fontSize: 12.5)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () async {
                  final media = await ref.read(mediaStoreProvider.future);
                  if (!context.mounted) return;
                  final picked = await showChatBackgroundPicker(
                    context,
                    media: media,
                    current: bg,
                  );
                  if (picked == null) return;
                  // 落库失败要说出来 —— 用户改完背景却"下次打开又没了"
                  // 是最让人困惑的失败
                  try {
                    await ref.read(chatBackgroundProvider.notifier).set(picked);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('保存背景失败：$e')),
                      );
                    }
                  }
                },
              );
            },
          ),

          Divider(height: 24, color: t.divider, indent: t.spacing.page.toDouble()),

          const _SectionTitle('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Tsukiro Chat'),
            subtitle: Text('0.2.0 · 插件化 AI 陪伴平台'),
          ),
          const ListTile(
            leading: Icon(Icons.warning_amber_rounded),
            title: Text('虚拟商品说明'),
            subtitle: Text('对话内容由 AI 生成，仅供参考。\n充值类虚拟商品不支持退款。'),
            isThreeLine: true,
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('数据存储'),
            subtitle: Text('对话与记忆保存在本机，不会自动上传。'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

Future<void> _pickTheme(
  BuildContext context,
  WidgetRef ref,
  ThemePreference current,
) async {
  final picked = await showModalBottomSheet<ThemePreference>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: ThemePreference.values.map((p) {
          return ListTile(
            leading: Icon(switch (p) {
              ThemePreference.system => Icons.brightness_auto_outlined,
              ThemePreference.light => Icons.light_mode_outlined,
              ThemePreference.dark => Icons.dark_mode_outlined,
            }),
            title: Text(p.label),
            trailing: p == current
                ? Icon(Icons.check, size: 18, color: context.tokens.primary)
                : null,
            onTap: () => Navigator.pop(ctx, p),
          );
        }).toList(growable: false),
      ),
    ),
  );
  if (picked != null) {
    await ref.read(themePreferenceProvider.notifier).set(picked);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.spacing.page.toDouble(), 8, t.spacing.page.toDouble(), 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: t.textMuted,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// 背景当前值的可读说明。
///
/// 放文件末尾而不是类里：它不依赖任何状态，是个纯函数，
/// 放类里反而要多写一个 this 才能调用。
String _backgroundLabel(ChatBackground bg) {
  switch (bg.kind) {
    case ChatBackgroundKind.theme:
      return '跟随主题';
    case ChatBackgroundKind.color:
      return '纯色';
    case ChatBackgroundKind.gradient:
      return '渐变';
    case ChatBackgroundKind.image:
      return '自定义图片';
  }
}
