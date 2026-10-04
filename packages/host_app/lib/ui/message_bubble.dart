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

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.agentInitial = '?',
    this.streaming,
    this.showReasoning = false,
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
              if (!isUser) _Avatar(name: agentInitial),
              if (!isUser) const SizedBox(width: 8),
              Flexible(
                child: GestureDetector(
                  onLongPress: () => _copy(context, text),
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

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // 名字可能是空的；用 runes.first 而不是 [0] —— 后者会把 emoji
    // 或某些中文字截成半个码点，渲染出乱码方块
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : String.fromCharCode(trimmed.runes.first);
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: <Color>[t.primary.withValues(alpha: 0.85), t.primary.withValues(alpha: 0.55)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        // 不能是 const —— color 来自令牌，亮主色下要换成深色前景
        style: TextStyle(
          fontSize: 14,
          color: t.onPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
