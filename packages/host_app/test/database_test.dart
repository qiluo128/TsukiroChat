/// 数据层测试。
///
/// 重点验证 `docs/18-agent-and-memory.md` 的几条硬性规则：
///   - 一轮对话的准备是**原子**的（不会留下孤儿用户消息）
///   - 并发准备一轮**不会重号**（seq 在事务里算）
///   - 删对话级联删消息，但**不删记忆**
///   - 删智能体级联删对话与记忆
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:model_gateway/model_gateway.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/models.dart';
import 'package:tsukiro_chat/data/repositories.dart';

void main() {
  late Directory directory;
  late AppDatabase database;
  late Repos repos;
  late Agent agent;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tsukiro-db-test-');
    database = await AppDatabase.open(directory.path);
    repos = Repos(database);
    agent = await repos.agents.create(name: '测试智能体');
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  group('智能体', () {
    test('新建的智能体人设是空的（不预置任何角色）', () async {
      final a = await repos.agents.get(agent.id);
      expect(a, isNotNull);
      expect(a!.persona.isEmpty, isTrue);
      expect(a.persona.systemPrompt, isEmpty);
      expect(a.persona.buildSystemPrompt(), isEmpty);
      expect(a.hasPersona, isFalse);
    });

    test('人设可以存下来并读回', () async {
      agent.persona = const Persona(
        systemPrompt: '你是一只猫。',
        greeting: '喵。',
        worldBook: '这个世界只有猫。',
      );
      await repos.agents.update(agent);

      final reloaded = await repos.agents.get(agent.id);
      expect(reloaded!.persona.systemPrompt, '你是一只猫。');
      expect(reloaded.persona.greeting, '喵。');
      expect(reloaded.persona.buildSystemPrompt(), contains('这个世界只有猫。'));
      expect(reloaded.hasPersona, isTrue);
    });

    test('模型配置与记忆配置可以存下来', () async {
      agent.model = const AgentModelConfig(providerId: 'p1', modelId: 'm1', temperature: 0.7);
      agent.memory = const MemoryConfig(scope: MemoryScope.conversation, maxEntries: 50);
      await repos.agents.update(agent);

      final reloaded = await repos.agents.get(agent.id);
      expect(reloaded!.model.providerId, 'p1');
      expect(reloaded.model.modelId, 'm1');
      expect(reloaded.model.temperature, 0.7);
      expect(reloaded.memory.scope, MemoryScope.conversation);
      expect(reloaded.memory.maxEntries, 50);
    });

    test('删除智能体会级联删除它的对话、消息与记忆', () async {
      final conv = await repos.conversations.create(agent.id);
      await repos.messages.prepareTurn(conv.id, userText: '你好');
      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: agent.id,
        content: '用户喜欢猫',
        createdAt: DateTime.now(),
      ));

      await repos.agents.delete(agent.id);

      expect(await repos.agents.get(agent.id), isNull);
      expect(await repos.conversations.get(conv.id), isNull);
      expect(await database.db.query('messages'), isEmpty);
      expect(await database.db.query('memories'), isEmpty);
    });
  });

  group('对话与消息', () {
    test('prepareTurn 原子地写入用户消息与助手占位', () async {
      final conv = await repos.conversations.create(agent.id);
      final prepared = await repos.messages.prepareTurn(
        conv.id,
        userText: '你好',
        userId: 'user-1',
        assistantId: 'assistant-1',
        now: DateTime(2026, 1, 1),
      );

      expect(prepared.userMessageId, 'user-1');
      expect(prepared.assistantMessageId, 'assistant-1');
      expect(prepared.userSeq, 1);
      expect(prepared.assistantSeq, 2);

      final messages = await repos.messages.list(conv.id);
      expect(messages.map((m) => m.seq), <int>[1, 2]);
      expect(messages[0].role, ChatRole.user);
      expect(messages[0].content, '你好');
      expect(messages[1].role, ChatRole.assistant);
      expect(messages[1].status, MessageStatus.streaming);

      // 计数器与标题也在同一个事务里更新了
      final reloaded = await repos.conversations.get(conv.id);
      expect(reloaded!.messageCount, 2);
      expect(reloaded.title, '你好');
    });

    test('prepareTurn 并发调用不重号', () async {
      final conv = await repos.conversations.create(agent.id);

      await Future.wait(<Future<PreparedChatTurn>>[
        repos.messages.prepareTurn(
          conv.id,
          userText: '第一条',
          userId: 'user-1',
          assistantId: 'assistant-1',
          now: DateTime(2026, 1, 1),
        ),
        repos.messages.prepareTurn(
          conv.id,
          userText: '第二条',
          userId: 'user-2',
          assistantId: 'assistant-2',
          now: DateTime(2026, 1, 1),
        ),
      ]);

      final messages = await repos.messages.list(conv.id);
      expect(messages.map((m) => m.seq), <int>[1, 2, 3, 4]);
      expect((await repos.conversations.get(conv.id))!.messageCount, 4);
    });

    test('第一条消息设标题，第二条不会覆盖', () async {
      final conv = await repos.conversations.create(agent.id);
      await repos.messages.prepareTurn(conv.id, userText: '第一句');
      await repos.messages.prepareTurn(conv.id, userText: '第二句');
      expect((await repos.conversations.get(conv.id))!.title, '第一句');
    });

    test('归档与恢复', () async {
      final conv = await repos.conversations.create(agent.id);
      expect((await repos.conversations.listByAgent(agent.id)).length, 1);

      await repos.conversations.setStatus(conv.id, ConversationStatus.archived);
      expect(await repos.conversations.listByAgent(agent.id), isEmpty);
      expect(
        (await repos.conversations.listByAgent(agent.id, status: ConversationStatus.archived))
            .length,
        1,
      );

      await repos.conversations.setStatus(conv.id, ConversationStatus.active);
      expect((await repos.conversations.listByAgent(agent.id)).length, 1);
    });

    test('删除对话会级联删除它的消息', () async {
      final conv = await repos.conversations.create(agent.id);
      await repos.messages.prepareTurn(conv.id, userText: '待删除');

      await repos.conversations.delete(conv.id);

      expect(await repos.conversations.get(conv.id), isNull);
      expect(await database.db.query('messages'), isEmpty);
    });

    test('删除对话**不会**删除记忆', () async {
      final conv1 = await repos.conversations.create(agent.id);
      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: agent.id,
        content: '用户住在杭州',
        createdAt: DateTime.now(),
      ));

      await repos.conversations.delete(conv1.id);

      // 记忆属于智能体，不属于某一次对话
      expect(await repos.memories.countOf(agent.id), 1);
    });

    test('把上次被中断的流式消息标为 error', () async {
      final conv = await repos.conversations.create(agent.id);
      await repos.messages.prepareTurn(conv.id, userText: '你好');

      expect(await repos.messages.failStaleStreaming(), 1);

      final messages = await repos.messages.list(conv.id);
      expect(messages[1].status, MessageStatus.error);
      expect(messages[1].errorCode, 'INTERRUPTED');
    });
  });

  group('记忆', () {
    test('默认是智能体级，所有对话都能看到', () async {
      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: agent.id,
        content: '共享记忆',
        createdAt: DateTime.now(),
      ));

      final conv = await repos.conversations.create(agent.id);
      final seen = await repos.memories.listFor(
        agent.id,
        conversationId: conv.id,
        scope: MemoryScope.conversation,
      );
      expect(seen.length, 1);
      expect(seen.first.isAgentLevel, isTrue);
    });

    test('对话级记忆只在那个对话里可见', () async {
      final convA = await repos.conversations.create(agent.id);
      final convB = await repos.conversations.create(agent.id);

      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: agent.id,
        conversationId: convA.id,
        content: '只属于 A',
        createdAt: DateTime.now(),
      ));

      final inA = await repos.memories.listFor(
        agent.id, conversationId: convA.id, scope: MemoryScope.conversation);
      final inB = await repos.memories.listFor(
        agent.id, conversationId: convB.id, scope: MemoryScope.conversation);

      expect(inA.length, 1);
      expect(inB, isEmpty);
    });

    test('不同智能体的记忆互相隔离', () async {
      final other = await repos.agents.create(name: '另一个');
      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: agent.id,
        content: 'A 的记忆',
        createdAt: DateTime.now(),
      ));
      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: other.id,
        content: 'B 的记忆',
        createdAt: DateTime.now(),
      ));

      final mine = await repos.memories.listFor(agent.id);
      expect(mine.length, 1);
      expect(mine.first.content, 'A 的记忆');
    });

    test('未知的记忆类型不丢，归为 custom', () async {
      await repos.memories.add(MemoryEntry(
        id: 'mem-x',
        agentId: agent.id,
        type: MemoryType.custom,
        content: '插件自定义的记忆',
        createdAt: DateTime.now(),
        metadata: <String, dynamic>{'myplugin': <String, dynamic>{'score': 3}},
      ));

      final loaded = (await repos.memories.listFor(agent.id)).single;
      expect(loaded.content, '插件自定义的记忆');
      expect(loaded.metadata['myplugin'], isNotNull);
    });
  });

  group('服务商', () {
    test('官方服务置顶且不可删除', () async {
      await repos.providers.ensureOfficial();
      final list = await repos.providers.list();
      expect(list.first.isOfficial, isTrue);

      await repos.providers.delete(ProviderRepository.officialId);
      expect(await repos.providers.get(ProviderRepository.officialId), isNotNull);
    });

    test('刷新模型表不会删掉手动添加的模型', () async {
      final p = await repos.providers.create(
        name: '测试中转站',
        protocol: ProviderProtocol.openai,
        baseUrl: 'https://example.test/v1',
        apiKey: 'k',
      );

      await repos.providers.addManualModel(p.id, 'manual-model');
      await repos.providers.replaceDiscovered(p.id, <ModelInfo>[
        const ModelInfo(id: 'auto-model'),
      ]);

      var models = await repos.providers.modelsOf(p.id);
      expect(models.map((m) => m.id), containsAll(<String>['auto-model', 'manual-model']));
      expect(models.firstWhere((m) => m.id == 'manual-model').isManual, isTrue);

      // 再刷一次，手动那条仍在
      await repos.providers.replaceDiscovered(p.id, <ModelInfo>[
        const ModelInfo(id: 'auto-model-2'),
      ]);
      models = await repos.providers.modelsOf(p.id);
      expect(models.map((m) => m.id), containsAll(<String>['auto-model-2', 'manual-model']));
      expect(models.any((m) => m.id == 'auto-model'), isFalse);
    });

    test('模型选项带着来源服务商', () async {
      final a = await repos.providers.create(
        name: '甲', protocol: ProviderProtocol.openai, baseUrl: 'https://a.test/v1', apiKey: 'k');
      final b = await repos.providers.create(
        name: '乙', protocol: ProviderProtocol.openai, baseUrl: 'https://b.test/v1', apiKey: 'k');

      // 同一个模型名来自两个服务商 —— 所以模型名不是全局唯一键
      await repos.providers.addManualModel(a.id, 'shared-model');
      await repos.providers.addManualModel(b.id, 'shared-model');

      final choices = await repos.providers.allChoices();
      final shared = choices.where((c) => c.modelId == 'shared-model').toList();
      expect(shared.length, 2);
      expect(shared.map((c) => c.providerName).toSet(), <String>{'甲', '乙'});
    });
  });
}
