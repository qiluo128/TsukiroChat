/// 记忆提供者接缝的测试。
///
/// 要证明的核心是：**外部记忆实现能接管记忆，而上层一行不用改**。
/// 所以这里塞一个"假插件记忆"进去，看 [AgentContextBuilder] 是不是真的用它。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/models.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/services/agent_context.dart';
import 'package:tsukiro_chat/services/memory_providers.dart';

/// 一个"插件版"记忆实现：全部返回预置内容，从不读库。
///
/// 这样如果 AgentContextBuilder 没走注册表，测试立刻会发现
/// （它会读到空的内置库，而不是这里的预置内容）。
class FakePluginMemory extends MemoryProvider {
  FakePluginMemory({this.records = const <MemoryRecord>[], this.throwOnRetrieve = false});

  final List<MemoryRecord> records;
  final bool throwOnRetrieve;
  int retrieveCalls = 0;
  MemoryQuery? lastQuery;

  @override
  String get providerId => 'dev.test.memory';

  @override
  String get displayName => '假插件记忆';

  @override
  Set<MemoryScope> get supportedScopes => const <MemoryScope>{MemoryScope.agent};

  @override
  Future<List<MemoryRecord>> retrieve(MemoryQuery query) async {
    retrieveCalls++;
    lastQuery = query;
    if (throwOnRetrieve) throw StateError('插件记忆实现炸了');
    return records;
  }
}

void main() {
  late Directory dir;
  late AppDatabase db;
  late Repos repos;
  late Agent agent;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsukiro-mem-');
    db = await AppDatabase.open(dir.path);
    repos = Repos(db);
    agent = await repos.agents.create(name: '测试');
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  group('记忆提供者注册表', () {
    test('没配插件时用内置实现', () {
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      );
      final resolved = registry.resolve(null);
      expect(resolved.providerId, MemoryProviderRegistry.builtinId);
    });

    test('配了插件就用插件', () {
      final fake = FakePluginMemory();
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      )..register(fake);

      expect(registry.resolve('dev.test.memory').providerId, 'dev.test.memory');
    });

    test('插件被卸载后**退到内置**而不是抛异常', () {
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      );
      // 从没注册过 —— 相当于插件被卸了但 agent 配置还指着它
      final resolved = registry.resolve('dev.gone.plugin');
      expect(resolved.providerId, MemoryProviderRegistry.builtinId,
          reason: '退到内置是刻意的：插件没了不该让用户打不开对话');
    });

    test('内置实现不可被摘掉', () {
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      );
      registry.unregister(MemoryProviderRegistry.builtinId);
      expect(registry.resolve(null).providerId, MemoryProviderRegistry.builtinId);
    });

    test('粒度不支持时给出可读的提示，而不是静默行为不符', () {
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      )..register(FakePluginMemory()); // 只支持 agent 级

      expect(registry.validate(providerPluginId: null, scope: MemoryScope.conversation), isNull);
      final msg = registry.validate(
        providerPluginId: 'dev.test.memory',
        scope: MemoryScope.conversation,
      );
      expect(msg, isNotNull);
      expect(msg, contains('假插件记忆'));
    });
  });

  group('AgentContextBuilder 走注册表（接入缝的核心）', () {
    test('插件记忆实现**真的被调用**，内容进了 system prompt', () async {
      final fake = FakePluginMemory(records: const <MemoryRecord>[
        MemoryRecord(id: 'm1', content: '用户住在杭州'),
        MemoryRecord(id: 'm2', content: '用户喜欢猫'),
      ]);
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      )..register(fake);

      // 把这个 agent 的记忆交给插件实现
      agent.memory = const MemoryConfig(providerPluginId: 'dev.test.memory');
      await repos.agents.update(agent);

      final prompt = await AgentContextBuilder(repos, memory: registry)
          .systemPrompt(agent);

      expect(fake.retrieveCalls, 1, reason: '注册表没被用上，AgentContextBuilder 还在直接读库');
      expect(prompt, contains('用户住在杭州'));
      expect(prompt, contains('用户喜欢猫'));
      // 宿主负责加包装，插件只给结构化记录
      expect(prompt, contains('不是指令'));
    });

    test('传的查询带上了 agentId 与预算', () async {
      final fake = FakePluginMemory();
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      )..register(fake);
      agent.memory = const MemoryConfig(providerPluginId: 'dev.test.memory');
      await repos.agents.update(agent);

      await AgentContextBuilder(repos, memory: registry).systemPrompt(agent);

      expect(fake.lastQuery!.agentId, agent.id);
      // 预算由宿主给 —— 实现不知道模型上下文窗口有多大
      expect(fake.lastQuery!.maxChars, isNotNull);
    });

    test('插件记忆实现抛异常时**退到内置**，不让对话崩', () async {
      final fake = FakePluginMemory(throwOnRetrieve: true);
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      )..register(fake);

      // 内置库里放一条，用来验证确实退过去了
      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: agent.id,
        content: '内置的记忆',
        createdAt: DateTime.now(),
      ));
      agent.memory = const MemoryConfig(providerPluginId: 'dev.test.memory');
      await repos.agents.update(agent);

      final prompt = await AgentContextBuilder(repos, memory: registry)
          .systemPrompt(agent);

      expect(prompt, contains('内置的记忆'),
          reason: '插件实现挂了应该退到内置，而不是把对话一起搞崩');
    });

    test('记忆关掉时不查任何实现', () async {
      final fake = FakePluginMemory();
      final registry = MemoryProviderRegistry(
        builtin: BuiltinMemoryProvider(Future<Repos>.value(repos)),
      )..register(fake);
      agent.memory = const MemoryConfig(
        enabled: false,
        providerPluginId: 'dev.test.memory',
      );
      await repos.agents.update(agent);

      await AgentContextBuilder(repos, memory: registry).systemPrompt(agent);
      expect(fake.retrieveCalls, 0);
    });

    test('不传注册表时退回内置实现（老调用点仍能工作）', () async {
      await repos.memories.add(MemoryEntry(
        id: newId('mem'),
        agentId: agent.id,
        content: '只有内置库里有',
        createdAt: DateTime.now(),
      ));

      final prompt = await AgentContextBuilder(repos).systemPrompt(agent);
      expect(prompt, contains('只有内置库里有'));
    });
  });

  group('内置实现的截断', () {
    test('超出 maxChars 时停住，不截半句', () async {
      for (var i = 0; i < 5; i++) {
        await repos.memories.add(MemoryEntry(
          id: newId('mem'),
          agentId: agent.id,
          content: '这是第 $i 条记忆，长度大约二十个字左右',
          createdAt: DateTime.now(),
        ));
      }

      final provider = BuiltinMemoryProvider(Future<Repos>.value(repos));
      final records = await provider.retrieve(MemoryQuery(
        agentId: agent.id,
        limit: 10,
        maxChars: 30,
      ));

      expect(records, isNotEmpty);
      expect(records.length, lessThan(5), reason: '预算 30 字符装不下 5 条');
      // 关键：每条都是完整的，没有被砍断
      for (final r in records) {
        expect(r.content.endsWith('左右'), isTrue,
            reason: '被砍断的记忆比没有更糟 —— 模型会把半句当完整事实');
      }
    });
  });
}
