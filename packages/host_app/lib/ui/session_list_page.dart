/// 会话列表。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import 'chat_page.dart';

class SessionListPage extends ConsumerWidget {
  const SessionListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final sessions = ref.watch(sessionListProvider);
    final config = ref.watch(appConfigProvider).valueOrNull;

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
        onPressed: () => _newSession(context, ref),
        backgroundColor: t.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('新对话'),
      ),
      body: Column(
        children: <Widget>[
          if (config != null && !config.isReady) _ConfigBanner(note: config.loadNote),
          Expanded(
            child: sessions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _ErrorView(error: e, onRetry: () => ref.invalidate(sessionListProvider)),
              data: (list) => list.isEmpty
                  ? const _EmptyView()
                  : RefreshIndicator(
                      onRefresh: () async => ref.invalidate(sessionListProvider),
                      child: ListView.separated(
                        padding: EdgeInsets.symmetric(vertical: t.spacing.page.toDouble() / 2),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          indent: t.spacing.page.toDouble(),
                          endIndent: t.spacing.page.toDouble(),
                        ),
                        itemBuilder: (context, i) => _SessionTile(
                          session: list[i],
                          onTap: () => _openSession(context, ref, list[i]),
                          onDelete: () => _deleteSession(context, ref, list[i]),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _newSession(BuildContext context, WidgetRef ref) async {
    final db = await ref.read(databaseProvider.future);
    final session = await ChatRepository(db).createSession();
    ref.invalidate(sessionListProvider);
    if (context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: session.id)),
      );
      ref.invalidate(sessionListProvider);
    }
  }

  Future<void> _openSession(BuildContext context, WidgetRef ref, ChatSession session) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: session.id)),
    );
    ref.invalidate(sessionListProvider);
  }

  Future<void> _deleteSession(BuildContext context, WidgetRef ref, ChatSession session) async {
    final t = context.tokens;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('「${session.title}」及其中的 ${session.messageCount} 条消息会被删除，无法恢复。'),
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
    if (confirmed != true) return;
    if (!context.mounted) return;

    final db = await ref.read(databaseProvider.future);
    await ChatRepository(db).deleteSession(session.id);
    ref.invalidate(sessionListProvider);
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.onTap, required this.onDelete});

  final ChatSession session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListTile(
      onTap: onTap,
      onLongPress: onDelete,
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          session.messageCount == 0
              ? '还没有消息'
              : '${session.messageCount} 条 · ${_formatTime(session.sortTime)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, color: t.textMuted),
        onPressed: onDelete,
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

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.chat_bubble_outline, size: 48, color: t.textMuted),
          const SizedBox(height: 14),
          Text('还没有对话', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text('点右下角开始', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ConfigBanner extends StatelessWidget {
  const _ConfigBanner({this.note});

  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: double.infinity,
      color: t.danger.withValues(alpha: 0.08),
      padding: EdgeInsets.symmetric(
        horizontal: t.spacing.page.toDouble(),
        vertical: 10,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 18, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note ?? '还没有配置模型，去设置里填一下才能聊天',
              style: TextStyle(fontSize: 13, color: t.danger),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
