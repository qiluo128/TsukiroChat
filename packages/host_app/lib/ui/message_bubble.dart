/// 消息气泡。
///
/// 三种状态各有一套视觉：
///   - 用户消息：右对齐，主色系气泡
///   - AI 消息：左对齐，surface 气泡
///   - 流式中：多一个"光标"和"思考中"指示
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../providers/chat_controller.dart';
import '../theme/app_theme.dart';
import 'agent_avatar.dart';

/// 消息上能做的操作。
enum MessageAction { copy, selectText, retract, edit, regenerate }

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.agentInitial = '?',
    this.streaming,
    this.showReasoning = false,
    this.onAction,
    this.isLastAssistant = false,
    this.agentAvatarPath,
  });

  final StoredChatMessage message;

  /// 头像上那个字 —— 来自智能体的名字首字。
  ///
  /// **不再是写死的**：以前这里硬编码了内置人设的名字，那与
  /// 「AI 不要有默认人设」冲突（见 `docs/18-agent-and-memory.md` §6）。
  final String agentInitial;

  /// 流式缓冲（只有正在输出的那一条才有）。
  final StreamingBuffer? streaming;

  /// 是否展开思维链。
  final bool showReasoning;

  /// 长按菜单选了哪一项。
  ///
  /// **用回调 + 枚举，而不是在气泡里直接操作**：
  /// 气泡只负责"用户想干什么"，怎么干（落库、发钩子、重跑模型）
  /// 属于控制器。而且「重说」作用于整轮，不该由单个气泡决定。
  final void Function(MessageAction action)? onAction;

  /// 智能体的头像标识（emoji:… / file:… / null=首字）。
  final String? agentAvatarPath;

  /// 是不是这条对话里**最后一条**助手消息。
  ///
  /// 「重说」作用于整轮，只能对最后一条回复用 ——
  /// 对中间某条回复重说会把它之后的整段对话都作废，
  /// 那不是用户按下"重说"时想要的。
  final bool isLastAssistant;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isUser = message.isUser;

    // 流式时正文以缓冲为准 —— 数据库那条还是空的
    final text = streaming?.text ?? message.content ?? '';
    final reasoning = streaming?.reasoning ?? message.reasoning;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: t.spacing.page.toDouble(),
        vertical: t.spacing.messageGap.toDouble() / 2,
      ),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!isUser)
                AgentAvatar(name: agentInitial, avatarPath: agentAvatarPath),
              if (!isUser) const SizedBox(width: 8),
              Flexible(
                child: GestureDetector(
                  // **opaque**：让这一层在命中测试里吃掉事件。
                  //
                  // 默认的 deferToChild 只在子节点没处理时才响应，
                  // 于是"长按到底算谁的"取决于子节点的实现细节 ——
                  // 表现就是长按时灵时不灵。
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => _showMenu(context, text),
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.76,
                    ),
                    decoration: BoxDecoration(
                      color: isUser ? t.userBubble : t.assistantBubble,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(t.radius.bubble.toDouble()),
                        topRight: Radius.circular(t.radius.bubble.toDouble()),
                        bottomLeft: Radius.circular(isUser ? t.radius.bubble.toDouble() : 4),
                        bottomRight: Radius.circular(isUser ? 4 : t.radius.bubble.toDouble()),
                      ),
                      boxShadow: isUser ? const <BoxShadow>[] : t.shadowFor('shadow.card'),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: _BubbleBody(
                      text: text,
                      isUser: isUser,
                      isStreaming: message.isStreaming,
                      hasText: streaming?.hasText ?? text.trim().isNotEmpty,
                      isThinkingOnly: streaming?.isThinkingOnly ?? false,
                      errorCode: message.errorCode,
                    ),
                  ),
                ),
              ),
            ],
          ),

          // 思维链（默认折叠）
          if (!isUser && showReasoning && (reasoning?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: _ReasoningPanel(text: reasoning!),
            ),

          if (!isUser && message.isStreaming && streaming?.isThinkingOnly == true)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Text(
                '正在思考…',
                style: TextStyle(fontSize: 12, color: t.textMuted),
              ),
            ),

          // 用量（只在非流式、有数据时显示，克制一点）
          if (!isUser &&
              !message.isStreaming &&
              message.tokensCompletion != null &&
              message.tokensCompletion! > 0)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 4),
              child: Text(
                '${message.tokensPrompt ?? 0} + ${message.tokensCompletion} tokens',
                style: TextStyle(fontSize: 11, color: t.textMuted.withValues(alpha: 0.8)),
              ),
            ),
        ],
      ),
    );
  }

  /// 长按菜单。
  ///
  /// 只列出**当前这条消息上说得通**的操作：
  ///   - 正在流式输出的消息不给操作（内容还没定稿）
  ///   - 只有用户消息能"编辑"
  ///   - 只有助手消息能"重说"
  ///   - 只有最后一条助手消息能"重说"（重说作用于整轮）
  ///
  /// 把不能用的项**列出来但禁用**，比直接不显示好：用户能知道
  /// "这个功能存在，只是现在不适用"，而不是以为没有这个功能。
  void _showMenu(BuildContext context, String text) {
    if (message.isStreaming) return;
    final t = context.tokens;
    final canEdit = message.isUser;
    final canRegenerate = message.isAssistant && isLastAssistant;

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.copy_outlined, size: 20),
              title: const Text('复制'),
              enabled: text.trim().isNotEmpty,
              onTap: () {
                Navigator.pop(ctx);
                _copy(context, text);
              },
            ),

            // 「选择文本」放进菜单，而不是让长按直接进选择模式。
            //
            // 长按既要开菜单又要选文本，两者会打架 —— 结果是
            // "有时弹菜单、有时弹选择手柄"，用户觉得长按不灵。
            // 所以让**菜单独占长按**，选择变成一个明确的选择。
            //
            // 这也是微信/Telegram 的做法，用户对它有肌肉记忆。
            ListTile(
              leading: const Icon(Icons.text_fields, size: 20),
              title: const Text('选择文本'),
              subtitle: const Text('可以挑一段复制，或全选',
                  style: TextStyle(fontSize: 12)),
              enabled: text.trim().isNotEmpty,
              onTap: () {
                Navigator.pop(ctx);
                _showSelectable(context, text);
              },
            ),
            ListTile(
              leading: const Icon(Icons.undo_outlined, size: 20),
              title: const Text('撤回'),
              subtitle: message.isUser
                  ? const Text('连同它的回复一起删掉', style: TextStyle(fontSize: 12))
                  : const Text('删掉这条回复', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                onAction?.call(MessageAction.retract);
              },
            ),
            ListTile(
              leading: Icon(Icons.edit_outlined, size: 20, color: canEdit ? null : t.textMuted),
              title: const Text('编辑'),
              enabled: canEdit,
              subtitle: canEdit ? null : const Text('只能编辑自己发的消息', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                onAction?.call(MessageAction.edit);
              },
            ),
            ListTile(
              leading: Icon(Icons.refresh_outlined,
                  size: 20, color: canRegenerate ? null : t.textMuted),
              title: const Text('重说'),
              enabled: canRegenerate,
              subtitle: canRegenerate
                  ? const Text('让它重新回答一次', style: TextStyle(fontSize: 12))
                  : const Text('只能对最后一条回复重说', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                onAction?.call(MessageAction.regenerate);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 打开一个可选中的文本视图。
  ///
  /// 为什么不直接在气泡里用 `SelectableText`：那样长按会被它抢走，
  /// 菜单就时灵时不灵。放到独立对话框里，两个需求各自有明确的入口。
  void _showSelectable(BuildContext context, String text) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择文本'),
        content: SingleChildScrollView(
          child: SelectableText(text, style: const TextStyle(fontSize: 14.5)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制全部'), duration: Duration(seconds: 1)),
              );
            },
            child: const Text('全选并复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, String text) {
    if (text.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }
}

class _BubbleBody extends StatelessWidget {
  const _BubbleBody({
    required this.text,
    required this.isUser,
    required this.isStreaming,
    required this.hasText,
    required this.isThinkingOnly,
    this.errorCode,
  });

  final String text;
  final bool isUser;
  final bool isStreaming;
  final bool hasText;
  final bool isThinkingOnly;
  final String? errorCode;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = Theme.of(context).textTheme.bodyLarge;

    if (!hasText && isStreaming) {
      // 还没收到正文 —— 用三个点，避免一块空白气泡
      return SizedBox(
        width: 34,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (i) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5),
              child: _Dot(delayMs: i * 160, color: t.textMuted),
            );
          }),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (isThinkingOnly)
          Text('（思考中）', style: style?.copyWith(color: t.textMuted)),
        SelectableText(
          text,
          style: style,
        ),
        if (isStreaming && hasText)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _BlinkingCursor(color: t.primary),
          ),
        if (errorCode != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: <Widget>[
                Icon(Icons.error_outline, size: 14, color: t.danger),
                const SizedBox(width: 4),
                Text(
                  _errorText(errorCode!),
                  style: TextStyle(fontSize: 12, color: t.danger),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 把错误码翻成人话。
  ///
  /// 直接把 `NETWORK_ERROR` 甩给用户是不负责任的 —— 他既不知道这是什么，
  /// 也不知道该干什么。
  static String _errorText(String code) {
    switch (code) {
      case 'NETWORK_ERROR':
        return '网络连不上，检查一下网络或 Base URL';
      case 'TIMEOUT':
        return '响应超时，可以重试';
      case 'PERMISSION_DENIED':
        return 'API Key 不正确或没有权限';
      case 'NOT_FOUND':
        return '模型不存在，去设置里核对模型名';
      case 'RATE_LIMITED':
        return '触发限流或余额不足，稍后再试';
      case 'INTERRUPTED':
        return '上一条回复被中断';
      default:
        return '回复失败（$code）';
    }
  }
}

/// 呼吸点。
class _Dot extends StatefulWidget {
  const _Dot({required this.delayMs, required this.color});

  final int delayMs;
  final Color color;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final phase = (_c.value * 3 - widget.delayMs / 900) % 3;
        final v = phase < 1 ? (phase < 0.5 ? phase * 2 : (1 - phase) * 2) : 0.0;
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.3 + v.clamp(0.0, 1.0) * 0.6),
          ),
        );
      },
    );
  }
}

/// 流式输出末尾的光标。
class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor({required this.color});

  final Color color;

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: Container(width: 2, height: 14, color: widget.color),
    );
  }
}

/// 思维链面板。
class _ReasoningPanel extends StatelessWidget {
  const _ReasoningPanel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.psychology_outlined, size: 13, color: t.textMuted),
              const SizedBox(width: 4),
              Text('思维链', style: TextStyle(fontSize: 11, color: t.textMuted)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            text,
            style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

