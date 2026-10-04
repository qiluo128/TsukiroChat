/// 某智能体的对话列表。
///
/// 进入智能体之后才看得到这个页面 —— 对话从属于智能体
/// （见 `docs/18-agent-and-memory.md`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:plugin_core/plugin_core.dart' show ChatRole;

import '../data/models.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import 'agent_edit_page.dart';
import 'chat_page.dart';

class ConversationListPage extends ConsumerStatefulWidget {
  const ConversationListPage({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<ConversationListPage> createState() => _ConversationListPageState();
}

class _ConversationListPageState extends ConsumerState<ConversationListPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final agent = ref.watch(agentProvider(widget.agentId)).valueOrNull;
    final resolved = ref.watch(resolvedModelProvider(widget.agentId));

    return Scaffold(
      appBar: AppBar(
        title: Text(agent?.name ?? '智能体'),
        actions: <Widget>[
          IconButton(
            tooltip: '编辑智能体',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AgentEditPage(agentId: widget.agentId),
                ),
              );
              ref.invalidate(agentProvider(widget.agentId));
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: t.primary,
          unselectedLabelColor: t.textMuted,
          indicatorColor: t.primary,
          tabs: const <Widget>[Tab(text: '对话'), Tab(text: '归档')],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newConversation(context),
        backgroundColor: t.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('新对话'),
      ),
      body: Column(
        children: <Widget>[
          // 顶部一条状态带：当前用哪个模型 —— 用户不必点进设置才知道
          if (agent != null)
            _AgentStatusBar(
              agent: agent,
              modelLabel: resolved?.label,
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _ConversationTab(
                  agentId: widget.agentId,
                  status: ConversationStatus.active,
                  onOpen: _openConversation,
                  onChanged: _refresh,
                ),
                _ConversationTab(
                  agentId: widget.agentId,
                  status: ConversationStatus.archived,
                  onOpen: _openConversation,
                  onChanged: _refresh,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _refresh() {
    ref.invalidate(conversationListProvider);
    ref.invalidate(agentProvider(widget.agentId));
  }

  Future<void> _newConversation(BuildContext context) async {
    final repos = await ref.read(reposProvider.future);
    final conversation = await repos.conversations.create(widget.agentId);
    _refresh();

    // 开场白：智能体设了就在新对话里先放一条
    final agent = await repos.agents.get(widget.agentId);
    final greeting = agent?.persona.greeting?.trim();
    if (greeting != null && greeting.isNotEmpty) {
      await repos.messages.insert(StoredChatMessage(
        id: newId('m'),
        conversationId: conversation.id,
        role: ChatRole.assistant,
        content: greeting,
        seq: 1,
        createdAt: DateTime.now(),
      ));
      await repos.conversations.touch(conversation.id);
    }

    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(conversationId: conversation.id),
      ),
    );
    _refresh();
  }

  Future<void> _openConversation(Conversation conversation) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(conversationId: conversation.id),
      ),
    );
    _refresh();
  }
}

class _ConversationTab extends ConsumerWidget {
  const _ConversationTab({
    required this.agentId,
    required this.status,
    required this.onOpen,
    required this.onChanged,
  });

  final String agentId;
  final ConversationStatus status;
  final void Function(Conversation) onOpen;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final query = (agentId: agentId, status: status);
    final list = ref.watch(conversationListProvider(query));

    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  status == ConversationStatus.active
                      ? Icons.chat_bubble_outline
                      : Icons.archive_outlined,
                  size: 44,
                  color: t.textMuted,
                ),
                const SizedBox(height: 14),
                Text(
                  status == ConversationStatus.active ? '还没有对话' : '归档是空的',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (status == ConversationStatus.active) ...<Widget>[
                  const SizedBox(height: 6),
                  Text('点右下角开始', style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(conversationListProvider(query)),
          child: ListView.separated(
            padding: EdgeInsets.symmetric(vertical: t.spacing.page.toDouble() / 2),
            itemCount: items.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: t.spacing.page.toDouble(),
              endIndent: t.spacing.page.toDouble(),
            ),
            itemBuilder: (context, i) => _ConversationTile(
              conversation: items[i],
              onTap: () => onOpen(items[i]),
              onAction: (action) => _handleAction(context, ref, items[i], action),
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    Conversation c,
    _ConvAction action,
  ) async {
    final repos = await ref.read(reposProvider.future);
    // 跨 await 之后 context 可能已经失效（用户返回了），必须显式检查 ——
    // 否则会在已卸载的树上弹对话框，直接崩
    if (!context.mounted) return;
    final t = context.tokens;

    switch (action) {
      case _ConvAction.rename:
        final name = await _promptText(context, title: '重命名对话', initial: c.title);
        if (name == null || name.trim().isEmpty) return;
        await repos.conversations.rename(c.id, name.trim());

      case _ConvAction.archive:
        await repos.conversations.setStatus(c.id, ConversationStatus.archived);

      case _ConvAction.unarchive:
        await repos.conversations.setStatus(c.id, ConversationStatus.active);

      case _ConvAction.delete:
        if (!context.mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除对话'),
            content: Text(
              '「${c.title}」及其中的 ${c.messageCount} 条消息会被永久删除。\n\n'
              '这个智能体的记忆**不会**被删 —— 记忆属于智能体，不属于某次对话。',
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: t.danger),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await repos.conversations.delete(c.id);
    }
    onChanged();
  }

  static Future<String?> _promptText(
    BuildContext context, {
    required String title,
    String initial = '',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

enum _ConvAction { rename, archive, unarchive, delete }

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.onTap,
    required this.onAction,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final void Function(_ConvAction) onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final archived = conversation.isArchived;

    return ListTile(
      onTap: onTap,
      leading: Icon(
        archived ? Icons.archive_outlined : Icons.chat_bubble_outline,
        color: t.textMuted,
        size: 20,
      ),
      title: Text(
        conversation.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          conversation.messageCount == 0
              ? '还没有消息'
              : '${conversation.messageCount} 条 · ${_formatTime(conversation.sortTime)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      trailing: PopupMenuButton<_ConvAction>(
        icon: Icon(Icons.more_horiz, color: t.textMuted),
        onSelected: onAction,
        itemBuilder: (ctx) => <PopupMenuEntry<_ConvAction>>[
          const PopupMenuItem<_ConvAction>(
            value: _ConvAction.rename,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined, size: 18),
              title: Text('重命名'),
            ),
          ),
          if (archived)
            const PopupMenuItem<_ConvAction>(
              value: _ConvAction.unarchive,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.unarchive_outlined, size: 18),
                title: Text('移出归档'),
              ),
            )
          else
            const PopupMenuItem<_ConvAction>(
              value: _ConvAction.archive,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.archive_outlined, size: 18),
                title: Text('归档'),
              ),
            ),
          PopupMenuItem<_ConvAction>(
            value: _ConvAction.delete,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, size: 18, color: t.danger),
              title: Text('删除', style: TextStyle(color: t.danger)),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (now.year == t.year && now.month == t.month && now.day == t.day) {
      return DateFormat('HH:mm').format(t);
    }
    if (now.year == t.year) return DateFormat('M月d日').format(t);
    return DateFormat('yyyy年M月d日').format(t);
  }
}

/// 顶部状态带：人设 / 模型 / 记忆一目了然。
class _AgentStatusBar extends StatelessWidget {
  const _AgentStatusBar({required this.agent, this.modelLabel});

  final Agent agent;
  final String? modelLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final chips = <Widget>[
      if (modelLabel != null)
        _Chip(icon: Icons.memory, text: modelLabel!)
      else
        _Chip(icon: Icons.error_outline, text: '未配置模型', danger: true),
      if (!agent.hasPersona)
        _Chip(icon: Icons.person_off_outlined, text: '未设人设', danger: true),
      _Chip(
        icon: Icons.psychology_outlined,
        text: '记忆${agent.memory.scope.label}',
      ),
    ];

    return Container(
      width: double.infinity,
      color: t.surface,
      padding: EdgeInsets.symmetric(
        horizontal: t.spacing.page.toDouble(),
        vertical: 8,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            for (var i = 0; i < chips.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 8),
              chips[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, this.danger = false});

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = danger ? t.danger : t.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: danger ? t.danger.withValues(alpha: 0.08) : t.background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11.5, color: color)),
        ],
      ),
    );
  }
}
