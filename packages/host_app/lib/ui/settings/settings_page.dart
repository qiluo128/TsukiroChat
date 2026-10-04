/// 设置。
///
/// 信息架构见 `docs/18-agent-and-memory.md` §5：
/// 模型相关的一切都收在「模型配置」一个入口里，不让用户在设置首页
/// 面对一堆平级的技术选项。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
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
