/// 智能体列表 —— 首页。
///
/// 智能体是核心单位（`docs/18-agent-and-memory.md`）：进入某个智能体之后
/// 才看得到它的对话列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import 'agent_edit_page.dart';
import 'conversation_list_page.dart';
import 'plugin_slot.dart';

class AgentListPage extends ConsumerWidget {
  const AgentListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final agents = ref.watch(agentListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tsukiro Chat'),
        actions: <Widget>[
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createAgent(context, ref),
        backgroundColor: t.primary,
        foregroundColor: t.onPrimary,
        icon: const Icon(Icons.add),
        label: const Text('新建智能体'),
      ),
      body: agents.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('$e', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.invalidate(agentListProvider),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (list) => Column(
          children: <Widget>[
            // 插件插槽：首页卡片区。
            //
            // 之前 home.cards 和 agent.sections **完全没放进任何界面** ——
            // 插件声明了也永远看不到。用户以为插件坏了，其实是宿主没给位置。
            PluginSlot(
              slot: 'home.cards',
              axis: Axis.vertical,
              context: <String, dynamic>{'agentCount': list.length},
            ),
            Expanded(
              child: list.isEmpty
                  ? const _EmptyGuide()
                  : RefreshIndicator(
                      onRefresh: () async => ref.invalidate(agentListProvider),
                      child: ListView.separated(
                        padding:
                            EdgeInsets.symmetric(vertical: t.spacing.page.toDouble() / 2),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          indent: t.spacing.page.toDouble() + 56,
                          endIndent: t.spacing.page.toDouble(),
                        ),
                        itemBuilder: (context, i) => _AgentTile(
                          agent: list[i],
                          onTap: () => _openAgent(context, ref, list[i]),
                          onEdit: () => _editAgent(context, ref, list[i]),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createAgent(BuildContext context, WidgetRef ref) async {
    final repos = await ref.read(reposProvider.future);
    final agent = await repos.agents.create();
    ref.invalidate(agentListProvider);
    if (!context.mounted) return;

    // 新建后直接进编辑页 —— 空人设的智能体需要用户填点什么才有意义
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AgentEditPage(agentId: agent.id)),
    );
    ref.invalidate(agentListProvider);
  }

  Future<void> _openAgent(BuildContext context, WidgetRef ref, Agent agent) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ConversationListPage(agentId: agent.id)),
    );
    ref.invalidate(agentListProvider);
  }

  Future<void> _editAgent(BuildContext context, WidgetRef ref, Agent agent) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AgentEditPage(agentId: agent.id)),
    );
    ref.invalidate(agentListProvider);
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({required this.agent, required this.onTap, required this.onEdit});

  final Agent agent;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      onTap: onTap,
      leading: _AgentAvatar(agent: agent),
      title: Text(
        agent.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '${agent.conversationCount} 个对话 · ${agent.memoryCount} 条记忆',
          style: TextStyle(fontSize: 12.5, color: t.textMuted),
        ),
      ),
      trailing: IconButton(
        icon: Icon(Icons.tune, color: t.textMuted, size: 20),
        onPressed: onEdit,
      ),
    );
  }
}

class _AgentAvatar extends StatelessWidget {
  const _AgentAvatar({required this.agent, this.size = 44});

  final Agent agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: <Color>[
            t.primary.withValues(alpha: 0.85),
            t.primary.withValues(alpha: 0.5),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        agent.initial,
        style: TextStyle(
          fontSize: size * 0.4,
          color: t.onPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyGuide extends StatelessWidget {
  const _EmptyGuide();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(t.spacing.page.toDouble() * 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.face_retouching_natural_outlined, size: 52, color: t.textMuted),
            const SizedBox(height: 16),
            Text('还没有智能体', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '一个智能体就是一个独立的 AI 角色：\n'
              '它有自己的性格、自己的记忆、自己的模型。\n\n'
              '点右下角创建第一个。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 供对话列表页复用的头像。
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({super.key, required this.agent, this.size = 32});

  final Agent agent;
  final double size;

  @override
  Widget build(BuildContext context) => _AgentAvatar(agent: agent, size: size);
}
