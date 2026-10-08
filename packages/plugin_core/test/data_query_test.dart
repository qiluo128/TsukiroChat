/// 声明式数据查询编译器的测试。
///
/// 这个文件守的是**整个数据访问的安全边界**。
/// 编译器负责拼 SQL，所以：
///   - 列名必须过白名单（不能把 `api_key` 查出来）
///   - 值必须走占位符（不能注入）
///   - **作用域必须无条件注入**（这是门）
///
/// 它跑在纯 Dart 里，不需要数据库 —— 这正是把编译器放进内核的理由。
library;

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  const compiler = DataQueryCompiler();

  DataQuery q(
    String entity, {
    Map<String, dynamic> where = const <String, dynamic>{},
    String? order,
    int limit = 50,
    int offset = 0,
    List<String>? select,
  }) =>
      DataQuery(
        entity: entity,
        where: where,
        order: order,
        limit: limit,
        offset: offset,
        select: select,
      );

  QueryPlan compile(DataQuery query, {String? agentId, bool crossAgent = false}) =>
      compiler.compileScoped(
        query,
        DataScope(agentId: agentId, crossAgent: crossAgent),
      );

  // ═══════════════════════ 作用域：这是门 ═══════════════════════

  group('作用域注入（安全边界的核心）', () {
    test('限定智能体时无条件加上 agent_id 过滤', () {
      final plan = compile(q('message'), agentId: 'a1');

      expect(plan.sql, contains('conversation_id IN (SELECT id FROM conversations'));
      expect(plan.args, contains('a1'),
          reason: '作用域值必须进参数表，不能拼进 SQL');
      expect(plan.scope, DataScopeKind.ownAgent);
    });

    test('memory 实体直接用 agent_id 列', () {
      final plan = compile(q('memory'), agentId: 'a1');
      expect(plan.sql, contains('agent_id = ?'));
      expect(plan.args, contains('a1'));
    });

    test('**没有任何作用域时返回空结果，不是全部数据**', () {
      // 全局启用的插件只有 data.read —— 它没有"自己的"智能体。
      // 这一条如果不成立，就是**静默的全量泄露**。
      final plan = compile(q('message'));

      expect(plan.scope, DataScopeKind.none);
      expect(plan.sql, contains('1 = 0'),
          reason: 'fail-closed：拿不到作用域时必须什么都查不到');
    });

    test('持有 crossAgent 时不加过滤', () {
      final plan = compile(q('message'), agentId: 'a1', crossAgent: true);

      expect(plan.scope, DataScopeKind.all);
      expect(plan.sql, isNot(contains('1 = 0')));
      expect(plan.sql, isNot(contains('conversation_id IN')));
    });

    test('crossAgent 时**连自己那个也不加** —— 它就是全量视图', () {
      final plan = compile(q('memory'), agentId: 'a1', crossAgent: true);
      expect(plan.args, isNot(contains('a1')));
    });

    test('作用域条件与插件自己的条件用 AND 连起来', () {
      final plan = compile(q('memory', where: <String, dynamic>{'type': 'fact'}),
          agentId: 'a1');
      expect(plan.sql, contains('type = ?'));
      expect(plan.sql, contains('agent_id = ?'));
      expect(plan.sql, contains(' AND '));
    });
  });

  // ═══════════════════════ 列白名单 ═══════════════════════

  group('列白名单', () {
    test('查询不存在的列**报错而不是忽略**', () {
      // 忽略的话插件以为查到了，实际拿到 null —— 更难查
      expect(
        () => compile(q('agent', where: <String, dynamic>{'apiKey': 'sk-x'})),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('select 里的列也过白名单', () {
      expect(
        () => compile(q('agent', select: <String>['id', 'persona'])),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('**密文字段没有暴露给插件**', () {
      // agents 表有 persona / model_config / memory_config，
      // 这些都不该在插件的可见列里
      final described = compiler.describe();
      final agent = described.firstWhere((e) => e['entity'] == 'agent');
      final cols = (agent['columns'] as List).cast<String>();

      expect(cols, contains('name'));
      expect(cols, isNot(contains('persona')));
      expect(cols, isNot(contains('modelConfig')));
      expect(cols, isNot(contains('memoryConfig')));
    });

    test('暴露的密文字段只给"有没有"，不给内容', () {
      final plan = compile(q('agent', select: <String>['hasPersona']), agentId: 'a1');
      expect(plan.sql, contains('persona AS hasPersona'),
          reason: '选的是 persona 列但对外叫 hasPersona —— 内容不该原样给出');
    });
  });

  // ═══════════════════════ 注入面 ═══════════════════════

  group('SQL 注入面', () {
    test('值全部走占位符', () {
      final plan = compile(
        q('memory', where: <String, dynamic>{'content': "'; DROP TABLE agents; --"}),
        agentId: 'a1',
      );

      expect(plan.sql, isNot(contains('DROP')));
      expect(plan.args, contains("'; DROP TABLE agents; --"));
    });

    test('like 的通配符被转义（防全表扫描）', () {
      final plan = compile(
        q('memory', where: <String, dynamic>{
          'content': <String, dynamic>{'like': '%'},
        }),
        agentId: 'a1',
      );

      // 原样传 `%` 等于 MATCH ALL —— 插件能借此把整表拉走
      expect(plan.args, contains(r'\%'));
      expect(plan.sql, contains('ESCAPE'));
    });

    test('like 模式有长度上限', () {
      expect(
        () => compile(q('memory', where: <String, dynamic>{
          'content': <String, dynamic>{'like': 'x' * 200},
        })),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('未知操作符被拒绝，不静默忽略', () {
      expect(
        () => compile(q('memory', where: <String, dynamic>{
          'content': <String, dynamic>{'regexp': '.*'},
        })),
        throwsA(isA<TsukiroException>()),
      );
    });
  });

  // ═══════════════════════ 成本边界 ═══════════════════════

  group('成本边界（宿主说了算，不是插件）', () {
    test('limit 被夹到上限', () {
      final plan = compile(q('message', limit: 999999), agentId: 'a1');
      expect(plan.limit, DataQueryCompiler.maxLimit);
      expect(plan.sql, contains('LIMIT ${DataQueryCompiler.maxLimit}'));
    });

    test('limit 至少为 1', () {
      expect(compile(q('message', limit: 0), agentId: 'a1').limit, 1);
      expect(compile(q('message', limit: -5), agentId: 'a1').limit, 1);
    });

    test('负 offset 归零', () {
      expect(compile(q('message', offset: -10), agentId: 'a1').sql, contains('OFFSET 0'));
    });

    test('in 的项数有上限', () {
      expect(
        () => compile(q('memory', where: <String, dynamic>{
          'id': <String, dynamic>{'in': List.generate(500, (i) => 'm$i')},
        })),
        throwsA(isA<TsukiroException>()),
      );
    });
  });

  // ═══════════════════════ 排序与未知实体 ═══════════════════════

  group('排序与实体校验', () {
    test('未知实体报错并列出可用的', () {
      try {
        compile(q('user'));
        fail('应该抛异常');
      } on TsukiroException catch (e) {
        expect(e.message, contains('user'));
        expect(e.message, contains('message'), reason: '要告诉插件能用什么');
      }
    });

    test('order 方向必须合法', () {
      expect(() => compile(q('message', order: 'createdAt.up'), agentId: 'a1'),
          throwsA(isA<TsukiroException>()));
      expect(() => compile(q('message', order: 'createdAt'), agentId: 'a1'),
          throwsA(isA<TsukiroException>()));
    });

    test('order 的列也过白名单', () {
      expect(() => compile(q('message', order: 'reasoning.desc'), agentId: 'a1'),
          throwsA(isA<TsukiroException>()));
    });

    test('合法 order 生成 ORDER BY', () {
      final plan = compile(q('message', order: 'createdAt.asc'), agentId: 'a1');
      expect(plan.sql, contains('ORDER BY created_at ASC'));
    });

    test('不写 order 时用实体默认排序（分页不能没有确定顺序）', () {
      final plan = compile(q('message'), agentId: 'a1');
      expect(plan.sql, contains('ORDER BY'));
    });
  });

  group('自省', () {
    test('describe 列出实体、列与可过滤性', () {
      final list = compiler.describe();
      final names = list.map((e) => e['entity']).toList();

      expect(names, containsAll(<String>['agent', 'conversation', 'message', 'memory']));
      final message = list.firstWhere((e) => e['entity'] == 'message');
      expect(message['scopable'], isTrue);
      expect((message['columns'] as List), contains('content'));
    });

    test('每个内置实体都**能**做作用域过滤', () {
      // 不能过滤的实体在"只有 data.read"时无从限制，
      // 等于开了个没有门的查询口
      for (final e in compiler.describe()) {
        expect(e['scopable'], isTrue, reason: '${e['entity']} 无法作用域过滤');
      }
    });
  });
}
