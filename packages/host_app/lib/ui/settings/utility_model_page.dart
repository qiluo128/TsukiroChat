/// 工具模型配置。
///
/// 入口：设置 → 模型配置 → 高级 → 工具模型。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../providers/app_providers.dart';
import '../../services/utility_model.dart';
import '../../theme/app_theme.dart';
import 'model_picker_page.dart';

class UtilityModelPage extends ConsumerWidget {
  const UtilityModelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final config = ref.watch(utilityModelConfigProvider).valueOrNull;
    final effective = ref.watch(effectiveUtilityModelProvider);
    final choices = ref.watch(modelChoicesProvider).valueOrNull ?? const <ModelChoice>[];

    return Scaffold(
      appBar: AppBar(title: const Text('工具模型')),
      body: ListView(
        padding: EdgeInsets.symmetric(vertical: t.spacing.section.toDouble() / 2),
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.auto_fix_high_outlined, size: 16, color: t.primary),
                      const SizedBox(width: 6),
                      Text(
                        '这个模型用来干什么',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: t.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '生成对话标题、做长对话摘要、抽标签这类「副任务」。\n\n'
                    '它们短、快、要求低 —— 用你主聊天的那个模型来干，'
                    '既慢又费钱。所以单独配一个便宜的。',
                    style: TextStyle(fontSize: 12.5, color: t.text, height: 1.6),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),
          _SectionTitle('当前使用'),
          ListTile(
            leading: Icon(
              effective == null ? Icons.error_outline : Icons.auto_awesome,
              color: effective == null ? t.danger : t.success,
            ),
            title: Text(
              effective?.label ?? '没有可用的模型',
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              effective == null
                  ? '先去「配置 API」添加一个服务商'
                  : (config?.isAuto ?? true
                      ? '自动选择 —— 点这里可以指定成别的'
                      : '已手动指定'),
              style: TextStyle(fontSize: 12.5, color: t.textMuted),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: choices.isEmpty ? null : () => _pick(context, ref),
          ),

          if (config != null && !config.isAuto)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
              child: OutlinedButton.icon(
                onPressed: () => _resetToAuto(ref),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('改回自动选择'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
              ),
            ),

          const SizedBox(height: 8),
          _SectionTitle('自动选择的规则'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: Text(
              '1. 你在这里指定的模型\n'
              '2. 官方服务（未上线）\n'
              '3. 任意一个可用的服务商',
              style: TextStyle(fontSize: 12.5, color: t.textMuted, height: 1.8),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              t.spacing.page.toDouble(), 8, t.spacing.page.toDouble(), 0,
            ),
            child: Text(
              '第 3 条是刻意的宽松：工具模型跑不起来时标题生成会**静默失败**，'
              '用户根本不知道哪里错了。宁可借用主模型，也不要让功能悄悄坏掉。',
              style: TextStyle(fontSize: 11.5, color: t.textMuted, height: 1.6),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final choice = await Navigator.of(context).push<ModelChoice>(
      MaterialPageRoute<ModelChoice>(builder: (_) => const ModelPickerPage()),
    );
    if (choice == null) return;

    final repos = await ref.read(reposProvider.future);
    await repos.settings.set(UtilityModelKeys.providerId, choice.provider.id);
    await repos.settings.set(UtilityModelKeys.modelId, choice.modelId);
    ref.invalidate(utilityModelConfigProvider);
  }

  Future<void> _resetToAuto(WidgetRef ref) async {
    final repos = await ref.read(reposProvider.future);
    await repos.settings.set(UtilityModelKeys.providerId, '');
    await repos.settings.set(UtilityModelKeys.modelId, '');
    ref.invalidate(utilityModelConfigProvider);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.spacing.page.toDouble(), 12, t.spacing.page.toDouble(), 6),
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
