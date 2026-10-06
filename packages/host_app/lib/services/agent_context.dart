/// 当前智能体模型调用的统一上下文构造器。
///
/// 工具模型调用不使用这里；只有 agent-scoped 调用（主聊天、插件的
/// agent.model.chat、greet）才自动带人设与记忆。
library;

import '../data/models.dart';
import '../data/repositories.dart';
import 'package:plugin_core/plugin_core.dart';

class AgentContextBuilder {
  AgentContextBuilder(this.repos);

  final Repos repos;

  /// 把 Agent 人设和受控记忆组装成 system prompt。
  Future<String> systemPrompt(Agent agent, {String? conversationId}) async {
    final base = agent.persona.buildSystemPrompt().trim();
    if (!agent.memory.enabled) return base;

    final limit = (agent.memory.maxEntries ?? 20).clamp(1, 100);
    final memories = await repos.memories.listFor(
      agent.id,
      conversationId: conversationId,
      scope: agent.memory.scope,
      limit: limit,
    );
    if (memories.isEmpty) return base;

    final lines = memories
        .map((memory) => '- ${memory.content.replaceAll(RegExp(r'\s+'), ' ').trim()}')
        .join('\n');
    final memoryText = '长期记忆（仅供参考）：\n$lines';
    return base.isEmpty ? memoryText : '$base\n\n$memoryText';
  }

  /// 在插件任务消息前插入 Agent 上下文。
  Future<List<ChatMessage>> messages(
    Agent agent,
    List<ChatMessage> taskMessages, {
    String? conversationId,
  }) async {
    final prompt = await systemPrompt(agent, conversationId: conversationId);
    return <ChatMessage>[
      if (prompt.isNotEmpty) ChatMessage.system(prompt),
      ...taskMessages,
    ];
  }
}
