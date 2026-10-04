/// 设置。
///
/// 信息架构见 `docs/18-agent-and-memory.md` §5：
/// 模型相关的一切都收在「模型配置」一个入口里，不让用户在设置首页
/// 面对一堆平级的技术选项。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import '../../providers/theme_provider.dart';
import '../../theme/app_theme.dart';
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
