/// `data.*` 查询 DSL 的端到端测试（真数据库）。
///
/// 编译器本身的测试在 plugin_core 里（纯 Dart）。
/// 这里证明的是**接上真数据库之后作用域仍然成立** ——
/// 两条链路拼起来才是完整的那道门。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/models.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/plugin/host_services_impl.dart';
import 'package:tsukiro_chat/services/data_access.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late Repos repos;
  late AppChatContext chat;
  late AppDataAccess data;

  late Agent alice;
  late Agent bob;
  late Conversation aliceConv;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsukiro-data-');
    db = await AppDatabase.open(dir.path);
    repos = Repos(db);
    chat = AppChatContext(repos: Future<Repos>.value(repos));
    data = AppDataAccess(repos: Future<Repos>.value(repos), chat: chat);

    alice = await repos.agents.create(name: 'Alice');
    bob = await repos.agents.create(name: 'Bob');
    aliceConv = await repos.conversations.create(alice.id);

    // Alice 两条消息，Bob 一条
    final t1 = await repos.messages.prepareTurn(aliceConv.id, userText: 'Alice 的第一句');
    await repos.messages.update(t1.assistantMessageId, content: 'A1', status: MessageStatus.done);
    final t2 = await repos.messages.prepareTurn(aliceConv.id, userText: 'Alice 的第二句');
    await repos.messages.update(t2.assistantMessageId, content: 'A2', status: MessageStatus.done);

    final bobConv = await repos.conversations.create(bob.id);
    final t3 = await repos.messages.prepareTurn(bobConv.id, userText: 'Bob 的秘密');
    await repos.messages.update(t3.assistantMessageId, content: 'B1', status: MessageStatus.done);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  DataQuery q(String entity, {Map<String, dynamic> where = const <String, dynamic>{}, int limit = 50}) =>
      DataQuery(entity: entity, where: where, limit: limit);

  group('作用域隔离（真数据库）', () {
    test('打开 Alice 时只查到 Alice 的消息', () async {
      chat.activeAgentId = alice.id;

      final result = await data.query('dev.test', q('message'));

      final rows = (result['rows'] as List).cast<Map<String, dynamic>>();
      expect(rows, hasLength(4), reason: 'Alice 有 2 轮 = 4 条');
      expect(result['scope'], DataScopeKind.ownAgent.name);
      expect(rows.map((r) => r['content']), isNot(contains('Bob 的秘密')));
    });

    test('打开 Bob 时只查到 Bob 的', () async {
      chat.activeAgentId = bob.id;

      final rows = ((await data.query('dev.test', q('message')))['rows'] as List)
          .cast<Map<String, dynamic>>();

      expect(rows, hasLength(2));
      expect(rows.map((r) => r['content']), contains('Bob 的秘密'));
    });

    test('crossAgent 时能看到全部', () async {
      chat.activeAgentId = alice.id;

      final rows = ((await data.query('dev.test', q('message'), crossAgent: true))['rows'] as List)
          .cast<Map<String, dynamic>>();

      expect(rows, hasLength(6), reason: '4 + 2');
      expect(rows.map((r) => r['content']), contains('Bob 的秘密'));
    });

    test('**没有当前智能体时查不到任何东西**（fail-closed）', () async {
      chat.activeAgentId = null;

      final result = await data.query('dev.test', q('message'));

      expect(result['scope'], DataScopeKind.none.name);
      expect(result['rows'], isEmpty);
    });

    test('按对话过滤仍然受作用域约束', () async {
      chat.activeAgentId = alice.id;

      final rows = ((await data.query(
        'dev.test',
        q('message', where: <String, dynamic>{'conversationId': aliceConv.id}),
      ))['rows'] as List)
          .cast<Map<String, dynamic>>();

      expect(rows, hasLength(4));
      expect(rows.every((r) => r['conversationId'] == aliceConv.id), isTrue);
    });
  });

  group('查询能力', () {
    test('条件、排序、投影、分页都能用', () async {
      chat.activeAgentId = alice.id;

      final rows = ((await data.query(
        'dev.test',
        DataQuery(
          entity: 'message',
          where: <String, dynamic>{'role': 'user'},
          order: 'seq.desc',
          limit: 1,
          select: <String>['content', 'seq'],
        ),
      ))['rows'] as List)
          .cast<Map<String, dynamic>>();

      expect(rows, hasLength(1));
      expect(rows.single['content'], 'Alice 的第二句');
      // 投影生效：只回 select 里要的列
      expect(rows.single.keys, unorderedEquals(<String>['content', 'seq']));
    });

    test('返回的每行只有白名单列', () async {
      chat.activeAgentId = alice.id;
      final rows = ((await data.query('dev.test', q('message')))['rows'] as List)
          .cast<Map<String, dynamic>>();

      // reasoning / tool_calls / metadata 这些都不该出现在返回里
      expect(rows.first.keys, isNot(contains('reasoning')));
      expect(rows.first.keys, isNot(contains('toolCalls')));
      expect(rows.first.keys, isNot(contains('metadata')));
    });

    test('limit 被夹到上限，不回整表', () async {
      chat.activeAgentId = alice.id;
      final result = await data.query('dev.test', q('message', limit: 100000));
      expect(result['limit'], DataQueryCompiler.maxLimit);
    });

    test('坏参数抛错，不静默返回空', () async {
      chat.activeAgentId = alice.id;
      await expectLater(
        () => data.query('dev.test', q('message', where: <String, dynamic>{'nope': 1})),
        throwsA(isA<TsukiroException>()),
      );
    });
  });

  group('自省', () {
    test('describeEntities 报告实体与被标为不可过滤的实体', () {
      final list = data.describeEntities();
      expect(list.map((e) => e['entity']), contains('message'));
      // 能过滤 = 有门。全都得是 true
      expect(list.every((e) => e['scopable'] == true), isTrue);
    });
  });
}
