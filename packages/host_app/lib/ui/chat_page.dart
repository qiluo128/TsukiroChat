/// 聊天页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../providers/app_providers.dart';
import '../providers/chat_controller.dart';
import '../providers/plugin_providers.dart';
import '../theme/app_theme.dart';
import 'message_bubble.dart';
import 'plugin_slot.dart';
import 'user_error.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  bool _showReasoning = false;

  @override
  void initState() {
    super.initState();
    // 告诉宿主"用户现在在看这个对话" ——
    // 插件调 chat.lastMessage() 时不带会话 id，靠的就是这里设的值。
    // 放在 postFrame 里：provider 要等 widget 树就绪才安全。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final chatContext = ref.read(chatContextProvider);
      chatContext.activeConversationId = widget.conversationId;
      final conversation = ref.read(conversationProvider(widget.conversationId)).valueOrNull;
      // provider 仍在 loading 时不能把父页面已经绑定的 agentId 清空。
      if (conversation != null) {
        chatContext.activeAgentId = conversation.agentId;
      }
    });
  }

  @override
  void dispose() {
    // **退出时要清掉**，否则插件会拿到一个已经关掉的对话：
    // 它的 chat.lastMessage() 会读到旧对话的内容，
    // 而用户以为自己已经不在那个对话里了。
    final chatContext = ref.read(chatContextProvider);
    if (chatContext.activeConversationId == widget.conversationId) {
      chatContext.activeConversationId = null;
    }
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final conversation =
        ref.watch(conversationProvider(widget.conversationId)).valueOrNull;
    final agentId = conversation?.agentId;

    final messagesAsync = ref.watch(messagesProvider(widget.conversationId));
    final streaming = ref.watch(streamingBufferProvider);
    final sending = ref.watch(sendingProvider);
    final ready = agentId != null && ref.watch(gatewayForAgentProvider(agentId)) != null;
    final agent =
        agentId == null ? null : ref.watch(agentProvider(agentId)).valueOrNull;

    ref.listen<AsyncValue<List<StoredChatMessage>>>(
      messagesProvider(widget.conversationId),
      (_, next) {
        if (next.hasValue) _scrollToBottom();
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(conversation?.title ?? '对话'),
        actions: <Widget>[
          IconButton(
            tooltip: _showReasoning ? '隐藏思维链' : '显示思维链',
            icon: Icon(
              _showReasoning ? Icons.psychology : Icons.psychology_outlined,
              color: _showReasoning ? t.primary : null,
            ),
            onPressed: () => setState(() => _showReasoning = !_showReasoning),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!ready) const _NoModelBanner(),

          // 插件插槽：聊天工具栏。
          // 上下文告诉插件"现在有没有消息、是不是正在流式输出"，
          // 声明里的 `when` 就靠它求值 —— 比如翻译按钮在没有消息时不显示。
          PluginSlot(
            slot: 'chat.toolbar',
            context: <String, dynamic>{
              'hasMessages': (messagesAsync.valueOrNull ?? const []).isNotEmpty,
              'isStreaming': sending,
            },
          ),

          Expanded(
            child: messagesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(userFacingError(e))),
              data: (messages) => messages.isEmpty
                  ? _EmptyState(
                      agentName: agent?.name,
                      onPick: _fillInput,
                    )
                  : _MessageList(
                      controller: _scroll,
                      messages: messages,
                      streaming: streaming,
                      showReasoning: _showReasoning,
                      agentInitial: agent?.initial ?? '?',
                      onAction: (m, action) => _handleMessageAction(m, action),
                    ),
            ),
          ),
          _Composer(
            controller: _input,
            focusNode: _inputFocus,
            sending: sending,
            enabled: ready,
            onSend: _send,
            onCancel: () => ref.read(chatControllerProvider).cancel(),
          ),
        ],
      ),
    );
  }

  void _fillInput(String text) {
    _input.text = text;
    _inputFocus.requestFocus();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;

    final controller = ref.read(chatControllerProvider);
    _input.clear();
    _scrollToBottom();

    try {
      await controller.send(conversationId: widget.conversationId, text: text);
    } catch (e) {
      if (!mounted) return;
      // 错误已经写进消息里了（气泡上有提示），这里只补一个轻提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e)), duration: const Duration(seconds: 4)),
      );
    }
  }

  void _scrollToBottom() {
    // 等这一帧布局完成再滚 —— 否则新气泡还没测量高度，滚不到底
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// 处理消息上的操作。
  ///
  /// 每一种都**先落库再刷新**，失败时给明确提示 ——
  /// 撤回/编辑是对用户数据的破坏性操作，"点了没反应"最让人不安。
  Future<void> _handleMessageAction(
    StoredChatMessage message,
    MessageAction action,
  ) async {
    final controller = ref.read(chatControllerProvider);
    final t = context.tokens;

    try {
      switch (action) {
        case MessageAction.copy:
          return;

        case MessageAction.retract:
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('撤回这条消息？'),
              content: Text(message.isUser
                  ? '这条消息和它的回复都会被删除，无法恢复。'
                  : '这条回复会被删除。'),
              actions: <Widget>[
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: TextButton.styleFrom(foregroundColor: t.danger),
                  child: const Text('撤回'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          final n = await controller.retract(
            conversationId: widget.conversationId,
            messageId: message.id,
          );
          if (mounted && n > 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已撤回 $n 条'), duration: const Duration(seconds: 1)),
            );
          }

        case MessageAction.edit:
          final text = await _promptEdit(message.content ?? '');
          if (text == null || text.trim().isEmpty) return;
          await controller.edit(
            conversationId: widget.conversationId,
            messageId: message.id,
            newText: text,
          );

        case MessageAction.regenerate:
          await controller.regenerate(widget.conversationId);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e)), duration: const Duration(seconds: 4)),
      );
    }
  }

  Future<String?> _promptEdit(String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '改完会让它重新回答'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存并重答'),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.controller,
    required this.messages,
    required this.streaming,
    required this.showReasoning,
    required this.agentInitial,
    required this.onAction,
  });

  final ScrollController controller;
  final List<StoredChatMessage> messages;
  final StreamingBuffer? streaming;
  final bool showReasoning;
  final String agentInitial;
  final void Function(StoredChatMessage message, MessageAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListView.builder(
      controller: controller,
      padding: EdgeInsets.symmetric(vertical: t.spacing.page.toDouble() / 2),
      itemCount: messages.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return const SizedBox(height: 4);
        final m = messages[index - 1];
        // 「重说」只对最后一条助手消息可用 —— 对中间某条重说
        // 会作废它之后的整段对话，那不是用户按下按钮时想要的
        final isLastAssistant = m.isAssistant &&
            !messages.skip(index).any((x) => x.isAssistant);
        return MessageBubble(
          key: ValueKey<String>(m.id),
          message: m,
          agentInitial: agentInitial,
          isLastAssistant: isLastAssistant,
          onAction: (action) => onAction(m, action),
          // 只有正在流式输出那一条才吃缓冲
          streaming: (streaming != null && streaming!.messageId == m.id) ? streaming : null,
          showReasoning: showReasoning,
        );
      },
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.enabled,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool enabled;
  final Future<void> Function() onSend;
  final VoidCallback onCancel;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final canSend = widget.enabled && _hasText && !widget.sending;

    return Container(
      decoration: BoxDecoration(
        color: t.background,
        border: Border(top: BorderSide(color: t.divider)),
      ),
      padding: EdgeInsets.fromLTRB(
        t.spacing.page.toDouble(),
        10,
        t.spacing.page.toDouble(),
        10 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              enabled: widget.enabled,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              style: Theme.of(context).textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: widget.enabled ? '说点什么…' : '先配置模型',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 发送中变成"停止" —— 推理模型一次 20–30 秒，用户需要能中断
          if (widget.sending)
            _RoundButton(
              icon: Icons.stop_rounded,
              background: t.danger,
              // 红底上用白字是对的（红是暗色）
              foreground: Colors.white,
              onTap: widget.onCancel,
            )
          else
            _RoundButton(
              icon: Icons.arrow_upward_rounded,
              background: canSend ? t.primary : t.divider,
              // 亮主色上必须用深色前景；禁用态用中灰
              foreground: canSend ? t.onPrimary : t.textMuted,
              onTap: canSend
                  ? () {
                      widget.onSend();
                      // 连续发消息时保持焦点
                      widget.focusNode.requestFocus();
                    }
                  : null,
            ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.background,
    required this.foreground,
    this.onTap,
  });

  final IconData icon;
  final Color background;

  /// 图标颜色。**不能写死白色** —— 亮主色上的白图标对比度只有约 1.5:1。
  final Color foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: foreground, size: 21),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick, this.agentName});

  final void Function(String) onPick;
  final String? agentName;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    const starters = <String>['你好', '在吗', '介绍一下你自己'];

    return Center(
      child: Padding(
        padding: EdgeInsets.all(t.spacing.page.toDouble()),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.auto_awesome_outlined, size: 40, color: t.textMuted),
            const SizedBox(height: 12),
            Text(
              agentName == null ? '开始聊天' : '和「$agentName」开始聊天',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: starters.map((s) {
                return ActionChip(
                  label: Text(s),
                  onPressed: () => onPick(s),
                  backgroundColor: t.surface,
                  side: BorderSide(color: t.divider),
                  labelStyle: TextStyle(fontSize: 13, color: t.text),
                );
              }).toList(growable: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoModelBanner extends StatelessWidget {
  const _NoModelBanner();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: double.infinity,
      color: t.danger.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, size: 18, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '还没有可用的模型',
              style: TextStyle(fontSize: 13, color: t.danger),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
            child: const Text('去配置'),
          ),
        ],
      ),
    );
  }
}
