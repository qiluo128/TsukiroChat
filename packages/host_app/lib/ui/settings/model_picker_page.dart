/// 选模型。
///
/// **每一项都显示它来自哪个服务商** —— 这是用户明确要求的：
/// 同一个模型名可能来自多个服务商，不标来源就会选错。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../providers/app_providers.dart';
import '../../theme/app_theme.dart';

class ModelPickerPage extends ConsumerWidget {
  const ModelPickerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final choices = ref.watch(modelChoicesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('选择模型')),
      body: choices.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) return const _Empty();

          // 按服务商分组 —— 这样"来自哪家"是一眼可见的层次，不用逐条读副标题
          final grouped = <String, List<ModelChoice>>{};
          for (final c in list) {
            grouped.putIfAbsent(c.provider.name, () => <ModelChoice>[]).add(c);
          }

          return ListView(
            padding: EdgeInsets.symmetric(vertical: t.spacing.page.toDouble() / 2),
            children: <Widget>[
              for (final entry in grouped.entries) ...<Widget>[
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    t.spacing.page.toDouble(),
                    12,
                    t.spacing.page.toDouble(),
                    4,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        entry.value.first.isOfficial
                            ? Icons.verified_outlined
                            : Icons.cloud_outlined,
                        size: 14,
                        color: entry.value.first.isOfficial ? t.primary : t.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: entry.value.first.isOfficial ? t.primary : t.textMuted,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${entry.value.length} 个模型',
                        style: TextStyle(fontSize: 11, color: t.textMuted),
                      ),
                    ],
                  ),
                ),
                for (final c in entry.value)
                  ListTile(
                    dense: true,
                    title: Text(c.modelId, style: const TextStyle(fontSize: 14)),
                    subtitle: c.model.displayName != null
                        ? Text(c.model.displayName!,
                            style: Theme.of(context).textTheme.bodySmall)
                        : null,
                    trailing: c.model.isManual
                        ? Tooltip(
                            message: '手动添加',
                            child: Icon(Icons.push_pin_outlined, size: 14, color: t.textMuted),
                          )
                        : null,
                    onTap: () => Navigator.of(context).pop(c),
                  ),
              ],
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(t.spacing.page.toDouble() * 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off_outlined, size: 44, color: t.textMuted),
            const SizedBox(height: 14),
            Text('还没有可用的模型', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '去「设置 → 模型配置 → 配置 API」\n添加一个服务商并填入 API Key。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
