/// 模型返回了空正文时的诊断。
///
/// ## 为什么需要单独一个文件
///
/// 空正文有**好几种完全不同的原因**，而它们对用户意味着完全不同的事：
///
/// | 现象 | 原因 | 该怎么办 |
/// |---|---|---|
/// | 有思维链、正文空 | **思维链把 `max_tokens` 吃光了** | 调大预算，不是重试 |
/// | 思维链也空、`finish_reason=length` | 预算太小，连思维链都没写完 | 调大预算 |
/// | 都空、`finish_reason=stop` | 模型真的回了个空串 | 换个说法 |
/// | `extra` 里有中转站字段 | 上游可能有话要说 | 看原始字段 |
///
/// 统一报「返回了空内容」等于把这些全糊成一团 —— 用户只能反复重试，
/// 而重试永远不会让预算变大。
///
/// 见 `docs/17-model-access.md`：
/// 「`max_tokens=16` 时正文为空、思维链有内容 → max_tokens **包含思维链**。
///   预算给小了，钱花了但用户看不到回复」
library;

import 'package:plugin_core/plugin_core.dart';

/// 把一个空正文的 [ModelReply] 变成**可诊断**的错误消息。
///
/// [where] 是调用点（如 `agent.greet`），让用户知道是哪条路径出的问题。
/// [requestedMaxTokens] 是当初要的预算 —— 这是最可能的元凶，要带上。
String describeEmptyReply(
  ModelReply reply, {
  required String where,
  int? requestedMaxTokens,
}) {
  final parts = <String>['$where：模型返回了空正文'];

  final reasoning = reply.reasoning?.trim() ?? '';
  if (reasoning.isNotEmpty) {
    // **最常见的一种**，而且最容易被误判成"模型坏了"
    parts.add('模型产出了 ${reasoning.length} 字的思维链，但正文是空的 —— '
        '这几乎总是 token 预算被思维链吃光了。');
    if (requestedMaxTokens != null) {
      parts.add('本次预算是 $requestedMaxTokens，'
          '推理模型的思维链也计入这个预算，建议调到 2000 以上。');
    }
  } else if (reply.finishReason == 'length') {
    parts.add('模型在写思维链时就用完了预算（finish_reason=length）。');
    if (requestedMaxTokens != null) {
      parts.add('本次预算是 $requestedMaxTokens，请调大。');
    }
  } else {
    parts.add('模型这次就是回了个空串（finish_reason=${reply.finishReason ?? "未知"}），换个说法再试。');
  }

  // token 用量是判断"预算不够"最直接的证据
  if (reply.completionTokens > 0) {
    parts.add('本次输出 ${reply.completionTokens} tokens'
        '${reply.promptTokens > 0 ? "，输入 ${reply.promptTokens} tokens" : ""}。');
  }

  // 中转站的私有字段（cost_cny / trace_id / reasoning_available…）里
  // 常藏着上游真正的说法。**原样带出来**，别让用户去抓包。
  if (reply.extra.isNotEmpty) {
    final keys = reply.extra.keys.take(6).join(', ');
    parts.add('上游附加字段：$keys');
  }

  return parts.join('');
}

/// 判断一个回复是不是"该报错"的空正文。
///
/// 有工具调用但没正文是**正常的**（模型决定先调工具再说），
/// 所以不能只看正文是否为空。
bool isEmptyReply(ModelReply reply) =>
    reply.text.trim().isEmpty && reply.toolCalls.isEmpty;
