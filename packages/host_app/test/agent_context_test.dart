import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/models.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/services/agent_context.dart';

void main() {
  late Directory directory;
  late AppDatabase database;
  late Repos repos;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tsukiro-agent-context-');
    database = await AppDatabase.open(directory.path);
    repos = Repos(database);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('builds persona and agent-scope memory into system message', () async {
    final agent = await repos.agents.create(
      name: '雪',
      persona: const Persona(systemPrompt: '你是冷淡但心软的学姐。'),
    );
    await repos.memories.add(MemoryEntry(
      id: 'memory-1',
      agentId: agent.id,
      content: '用户喜欢喝乌龙茶。',
      createdAt: DateTime.now(),
    ));

    final messages = await AgentContextBuilder(repos).messages(
      agent,
      <ChatMessage>[ChatMessage.user('请回应')],
    );

    expect(messages.first.role, ChatRole.system);
    expect(messages.first.content, contains('冷淡但心软'));
    expect(messages.first.content, contains('喜欢喝乌龙茶'));
    expect(messages.last.content, '请回应');
  });

  test('conversation scope excludes memories from another conversation', () async {
    final agent = await repos.agents.create(
      name: '角色',
      persona: const Persona(systemPrompt: '角色设定'),
    );
    final first = await repos.conversations.create(agent.id);
    final second = await repos.conversations.create(agent.id);
    agent.memory = const MemoryConfig(scope: MemoryScope.conversation);
    await repos.agents.update(agent);

    await repos.memories.add(MemoryEntry(
      id: 'memory-first',
      agentId: agent.id,
      conversationId: first.id,
      content: '第一段对话记忆',
      createdAt: DateTime.now(),
    ));
    await repos.memories.add(MemoryEntry(
      id: 'memory-second',
      agentId: agent.id,
      conversationId: second.id,
      content: '第二段对话记忆',
      createdAt: DateTime.now(),
    ));

    final prompt = await AgentContextBuilder(repos).systemPrompt(
      agent,
      conversationId: first.id,
    );
    expect(prompt, contains('第一段对话记忆'));
    expect(prompt, isNot(contains('第二段对话记忆')));
  });

  test('disabled memory is not injected', () async {
    final agent = await repos.agents.create(
      name: '无记忆',
      persona: const Persona(systemPrompt: '角色设定'),
    );
    agent.memory = const MemoryConfig(enabled: false);
    await repos.agents.update(agent);
    await repos.memories.add(MemoryEntry(
      id: 'memory-disabled',
      agentId: agent.id,
      content: '不应出现',
      createdAt: DateTime.now(),
    ));

    final prompt = await AgentContextBuilder(repos).systemPrompt(agent);
    expect(prompt, '角色设定');
    expect(prompt, isNot(contains('不应出现')));
  });
}
