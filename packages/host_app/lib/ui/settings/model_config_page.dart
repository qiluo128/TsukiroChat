/// 模型配置。
///
/// 结构（用户明确要求）：
///   1. 顶部是**官方服务** —— 不必选分区，充值即用。本期只留 UI。
///   2. 往下是**配置 API** —— 已添加的服务商 + 添加服务商。
///
/// 刻意**不做「选分区」**：默认就走官方，想折腾的用户往下拉自己配。
/// 把默认路径做到零决策，是这类产品能不能被普通人用起来的关键。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_gateway/model_gateway.dart';

import '../../providers/app_providers.dart';
import '../../services/utility_model.dart';
import '../../theme/app_theme.dart';
import 'provider_edit_page.dart';
import 'utility_model_page.dart';

class ModelConfigPage extends ConsumerWidget {
  const ModelConfigPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final providers = ref.watch(providerListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('模型配置')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(providerListProvider),
        child: providers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            final custom = list.where((p) => !p.isOfficial).toList(growable: false);

            return ListView(
              padding: EdgeInsets.only(bottom: t.spacing.section.toDouble()),
              children: <Widget>[
                const SizedBox(height: 12),

                // ── ① 官方服务 ──
                const _OfficialServiceCard(),

                const SizedBox(height: 20),

                // ── ② 配置 API ──
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '配置 API',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: t.textMuted,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const Spacer(),
                      if (custom.isNotEmpty)
                        Text(
                          '${custom.length} 个服务商',
                          style: TextStyle(fontSize: 11.5, color: t.textMuted),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    t.spacing.page.toDouble(),
                    4,
                    t.spacing.page.toDouble(),
                    8,
                  ),
                  child: Text(
                    '用自己的 API Key，直连上游。费用由上游服务商收取，与本应用无关。',
                    style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
                  ),
                ),

                if (custom.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: t.spacing.page.toDouble(),
                      vertical: 8,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
                        border: Border.all(color: t.divider),
                      ),
                      child: Column(
                        children: <Widget>[
                          Icon(Icons.cloud_off_outlined, size: 32, color: t.textMuted),
                          const SizedBox(height: 8),
                          Text(
                            '还没有添加服务商',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '支持 OpenAI / Anthropic / Google 三种协议',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  for (final p in custom)
                    ListTile(
                      leading: Icon(
                        p.isUsable ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                        color: p.isUsable ? t.success : t.textMuted,
                      ),
                      title: Text(p.name),
                      subtitle: Text(
                        '${_protocolLabel(p.protocol)} · ${p.modelCount} 个模型'
                        '${p.isUsable ? '' : ' · 缺少 Key'}',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: p.isUsable ? t.textMuted : t.danger,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ProviderEditPage(providerId: p.id),
                          ),
                        );
                        ref.invalidate(providerListProvider);
                        ref.invalidate(modelChoicesProvider);
                      },
                    ),

                Padding(
                  padding: EdgeInsets.fromLTRB(
                    t.spacing.page.toDouble(),
                    12,
                    t.spacing.page.toDouble(),
                    0,
                  ),
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ProviderEditPage(),
                        ),
                      );
                      ref.invalidate(providerListProvider);
                      ref.invalidate(modelChoicesProvider);
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加服务商'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // ── ③ 高级 ──
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
                  child: Text(
                    '高级',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.textMuted,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.auto_fix_high_outlined),
                  title: const Text('工具模型'),
                  subtitle: Text(
                    ref.watch(effectiveUtilityModelProvider)?.label ?? '自动选择',
                    style: TextStyle(fontSize: 12.5, color: t.textMuted),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const UtilityModelPage()),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    t.spacing.page.toDouble(), 0, t.spacing.page.toDouble(), 0,
                  ),
                  child: Text(
                    '生成对话标题、做摘要这类副任务用的模型。默认自动选择。',
                    style: TextStyle(fontSize: 11.5, color: t.textMuted, height: 1.5),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _protocolLabel(ProviderProtocol p) => switch (p) {
        ProviderProtocol.openai => 'OpenAI 兼容',
        ProviderProtocol.anthropic => 'Anthropic',
        ProviderProtocol.google => 'Google Gemini',
      };
}

/// 官方服务卡片。
///
/// **本期只留 UI**（见 `docs/18` §8 落地清单第 8 项）——
/// 真正的额度、兑换码、充值要等网关上线（阶段 3）。
/// 现在显示"未开放"而不是假数据：假余额比没有余额更糟。
class _OfficialServiceCard extends StatelessWidget {
  const _OfficialServiceCard();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      margin: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            t.primary.withValues(alpha: 0.12),
            t.primary.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(t.radius.card.toDouble() + 2),
        border: Border.all(color: t.primary.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.verified, size: 18, color: t.primary),
              const SizedBox(width: 6),
              Text(
                '官方服务',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: t.primary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.textMuted.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '即将开放',
                  style: TextStyle(fontSize: 11, color: t.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '开箱即用，不用自己配 Key。',
            style: TextStyle(fontSize: 12.5, color: t.textMuted),
          ),

          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '--',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('可用额度', style: TextStyle(fontSize: 12, color: t.textMuted)),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  // 未实现 —— 按钮点了给明确反馈，而不是假装在转圈
                  onPressed: () => _notYet(context, '充值'),
                  child: const Text('充值'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _notYet(context, '兑换码'),
                  child: const Text('兑换码'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static void _notYet(BuildContext context, String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what功能还没开放 —— 需要后端网关支持'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
