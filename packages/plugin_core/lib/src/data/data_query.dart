/// 声明式数据查询：把插件的查询对象编译成 SQL。
///
/// ## 为什么不给插件直接写 SQL
///
/// 给 SQL 看起来最自由，但同时破坏四件事：
///
/// 1. **schema 变成对外契约** —— 以后改表就是破坏性变更
/// 2. **行级权限无处施加** —— `SELECT * FROM messages` 直接绕开授权
/// 3. **没有成本边界** —— 一个没加索引的查询能卡死 App
/// 4. **审计粒度丢失** —— 只能记「执行了一条 SQL」，记不了「读了谁的什么」
///
/// 而 DSL 给的是**另一种自由**：插件够得着所有实体，但**不用关心 schema 演进**
/// —— 宿主可以加列、换存储，插件一行不改。
///
/// > SQL 给的是「今天的自由度」；DSL 给的是「不会因为宿主升级而失效的自由度」。
///
/// ## 为什么编译器在内核里
///
/// 这段逻辑是整个数据访问里**最危险**的部分（拼 SQL）。
/// 放在内核 = 纯 Dart、无数据库依赖 = **可以脱离数据库做穷尽的单元测试**。
/// 宿主那边只剩「执行 + 返回行」，薄到没什么可错的。
///
/// 见 `docs/20-plugin-scope-and-data-access.md` §4。
library;

import '../common/errors.dart';

// ═══════════════════════════ 实体定义 ═══════════════════════════

/// 一个可查询的实体。
///
/// **列白名单是核心安全设施**：不在 [columns] 里的列名一律拒绝，
/// 而不是忽略。忽略的话插件会以为查到了，实际拿到 null。
class DataEntity {
  const DataEntity({
    required this.name,
    required this.table,
    required this.columns,
    this.scopeColumn,
    this.scopeSubquery,
    this.defaultOrder,
  });

  /// 插件看到的实体名（`message` / `agent`…）。
  final String name;

  /// 真实表名。**不对插件暴露** —— 换表名不该影响插件。
  final String table;

  /// 公开的列。key 是插件看到的名字，value 是真实列名。
  final Map<String, String> columns;

  /// 直接的作用域列（如 `agent_id`）。
  final String? scopeColumn;

  /// 没有直接作用域列时的子查询模板，`{scope}` 会被替换成占位条件。
  ///
  /// `messages` 就是这种：它没有 `agent_id`，只能靠
  /// `conversation_id IN (SELECT id FROM conversations WHERE agent_id = ?)`。
  final String? scopeSubquery;

  /// 默认排序。**不指定时用哪个** —— 插件不写 order 也要有确定顺序，
  /// 否则分页会漏行或重复。
  final String? defaultOrder;

  bool exposes(String column) => columns.containsKey(column);

  String realColumn(String column) => columns[column]!;

  /// 有没有可用的作用域过滤。
  ///
  /// 两者都没有的实体**无法做行级过滤** —— 那它只能被
  /// `crossAgent` 权限访问，否则等于没有门。
  bool get isScopable => scopeColumn != null || scopeSubquery != null;
}

/// 内置实体表。
///
/// 列名对着 `database.dart` 的建表语句写。**故意不含
/// `embedding` / `api_key` / `persona` 这类字段** ——
/// 它们要么是二进制、要么是用户私密内容，插件没有理由读。
const Map<String, DataEntity> standardDataEntities = <String, DataEntity>{
  'agent': DataEntity(
    name: 'agent',
    table: 'agents',
    // 作用域就是它自己
    scopeColumn: 'id',
    defaultOrder: 'created_at DESC',
    columns: <String, String>{
      'id': 'id',
      'name': 'name',
      'avatarPath': 'avatar_path',
      'hasPersona': 'persona',
      'createdAt': 'created_at',
      'updatedAt': 'updated_at',
    },
  ),
  'conversation': DataEntity(
    name: 'conversation',
    table: 'conversations',
    scopeColumn: 'agent_id',
    defaultOrder: 'updated_at DESC',
    columns: <String, String>{
      'id': 'id',
      'agentId': 'agent_id',
      'title': 'title',
      'status': 'status',
      'messageCount': 'message_count',
      'lastMessageAt': 'last_message_at',
      'createdAt': 'created_at',
      'updatedAt': 'updated_at',
    },
  ),
  'message': DataEntity(
    name: 'message',
    table: 'messages',
    // messages 没有 agent_id，只能靠子查询
    scopeSubquery:
        'conversation_id IN (SELECT id FROM conversations WHERE agent_id = ?)',
    defaultOrder: 'created_at DESC',
    columns: <String, String>{
      'id': 'id',
      'conversationId': 'conversation_id',
      'role': 'role',
      'content': 'content',
      'status': 'status',
      'seq': 'seq',
      'tokenPrompt': 'tokens_prompt',
      'tokenCompletion': 'tokens_completion',
      'createdAt': 'created_at',
    },
  ),
  'memory': DataEntity(
    name: 'memory',
    table: 'memories',
    scopeColumn: 'agent_id',
    defaultOrder: 'created_at DESC',
    columns: <String, String>{
      'id': 'id',
      'agentId': 'agent_id',
      'conversationId': 'conversation_id',
      'type': 'type',
      'content': 'content',
      'createdAt': 'created_at',
    },
  ),
};

// ═══════════════════════════ 查询对象 ═══════════════════════════

/// 调用方的作用域。
///
/// **由宿主注入，插件不能伪造**（与 pluginId 同一原则，见 docs/07）。
class DataScope {
  const DataScope({this.agentId, this.crossAgent = false});

  /// 本次调用服务的智能体。null = 全局上下文。
  final String? agentId;

  /// 是否持有 `data.read.crossAgent`。
  final bool crossAgent;

  /// 最终会施加的过滤方式。
  DataScopeKind get kind {
    if (crossAgent) return DataScopeKind.all;
    if (agentId != null) return DataScopeKind.ownAgent;
    // **fail-closed**：全局上下文没有"自己的"数据
    return DataScopeKind.none;
  }
}

enum DataScopeKind {
  /// 不限（持有 crossAgent）。
  all,

  /// 限定在本次调用的智能体。
  ownAgent,

  /// 什么都看不到。全局启用的插件只有 `data.read` 时是这种。
  none,
}

/// 一条查询。
class DataQuery {
  const DataQuery({
    required this.entity,
    this.where = const <String, dynamic>{},
    this.order,
    this.limit = 50,
    this.offset = 0,
    this.select,
  });

  final String entity;

  /// 声明式条件。**不是表达式**。
  ///
  /// ```jsonc
  /// {
  ///   "role": "user",                       // 等于
  ///   "createdAt": { "gt": 1700000000 },    // 比较
  ///   "id": { "in": ["m1", "m2"] }
  /// }
  /// ```
  final Map<String, dynamic> where;

  /// `"createdAt.desc"`。省略时用实体的默认排序。
  final String? order;

  final int limit;
  final int offset;

  /// 要哪些列。null = 全部白名单列。
  final List<String>? select;

  static DataQuery parse(Map<String, dynamic> raw) {
    final entity = raw['entity']?.toString();
    if (entity == null || entity.isEmpty) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'data.query 需要 entity',
      );
    }
    final where = raw['where'];
    final select = raw['select'];
    return DataQuery(
      entity: entity,
      where: where is Map ? where.map((k, v) => MapEntry('$k', v)) : const <String, dynamic>{},
      order: raw['order']?.toString(),
      limit: (raw['limit'] as num?)?.toInt() ?? 50,
      offset: (raw['offset'] as num?)?.toInt() ?? 0,
      select: select is List ? select.map((e) => '$e').toList(growable: false) : null,
    );
  }
}

/// 编译结果。
class QueryPlan {
  const QueryPlan({
    required this.sql,
    required this.args,
    required this.scope,
    required this.limit,
  });

  final String sql;
  final List<Object?> args;
  final DataScopeKind scope;

  /// 实际生效的 limit（已夹取）。
  final int limit;

  @override
  String toString() => 'QueryPlan($sql, args=$args)';
}

// ═══════════════════════════ 编译器 ═══════════════════════════

class DataQueryCompiler {
  const DataQueryCompiler({this.entities = standardDataEntities});

  final Map<String, DataEntity> entities;

  /// 一次查询最多返回多少行。
  ///
  /// **宿主给的上限，不是插件能改的** —— 否则一个 `limit: 999999`
  /// 就能把整张表拉进内存。
  static const int maxLimit = 200;

  static const int _maxLikeLength = 64;

  /// 允许的操作符。**封闭集合** —— 不在这里的一律拒绝。
  static const Map<String, String> _operators = <String, String>{
    'eq': '=',
    'ne': '!=',
    'gt': '>',
    'gte': '>=',
    'lt': '<',
    'lte': '<=',
  };

  /// 把 [query] 编译成 SQL。
  ///
  /// 校验失败抛 [TsukiroException]，**不返回"能跑但错了"的 SQL**。
  QueryPlan compile(DataQuery query) => compileScoped(query, const DataScope());

  /// 带作用域编译。宿主用这个重载注入真实的 [scope]。
  QueryPlan compileScoped(DataQuery query, DataScope scope) {
    final entity = entities[query.entity];
    if (entity == null) {
      throw TsukiroException(
        TsukiroErrorCode.unsupported,
        '未知实体「${query.entity}」。可用：${entities.keys.join(', ')}',
      );
    }

    // ── select ──
    final wanted = query.select ?? entity.columns.keys.toList(growable: false);
    if (wanted.isEmpty) {
      throw TsukiroException(TsukiroErrorCode.invalidArgs, 'select 不能为空');
    }
    final selected = <String>[];
    for (final col in wanted) {
      if (!entity.exposes(col)) {
        // **拒绝而不是忽略** —— 忽略的话插件以为查到了，实际拿到 null
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          '实体「${entity.name}」没有列「$col」。可用：${entity.columns.keys.join(', ')}',
        );
      }
      selected.add('${entity.realColumn(col)} AS $col');
    }

    // ── where ──
    final conditions = <String>[];
    final args = <Object?>[];
    query.where.forEach((column, raw) {
      if (!entity.exposes(column)) {
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          '实体「${entity.name}」没有列「$column」',
        );
      }
      final real = entity.realColumn(column);

      if (raw is Map) {
        if (raw.isEmpty) {
          throw TsukiroException(
            TsukiroErrorCode.invalidArgs,
            '列「$column」的条件对象不能为空',
          );
        }
        raw.forEach((op, value) {
          final opName = '$op';
          switch (opName) {
            case 'isNull':
              conditions.add('$real IS ${value == true ? '' : 'NOT '}NULL');
            case 'in':
              if (value is! List || value.isEmpty) {
                throw TsukiroException(
                  TsukiroErrorCode.invalidArgs,
                  '列「$column」的 in 需要一个非空数组',
                );
              }
              if (value.length > maxLimit) {
                throw TsukiroException(
                  TsukiroErrorCode.invalidArgs,
                  'in 最多 $maxLimit 项',
                );
              }
              conditions.add('$real IN (${List.filled(value.length, '?').join(', ')})');
              args.addAll(value);
            case 'like':
              final pattern = '$value';
              if (pattern.length > _maxLikeLength) {
                throw TsukiroException(
                  TsukiroErrorCode.invalidArgs,
                  'like 模式最长 $_maxLikeLength 字符',
                );
              }
              // **转义通配符** —— 否则插件能用 `%` 做全表扫描。
              // 用 ESCAPE 子句而不是字符串替换，避免二次转义问题。
              conditions.add(r"$real LIKE ? ESCAPE '\'");
              args.add(pattern
                  .replaceAll(r'\', r'\\')
                  .replaceAll('%', r'\%')
                  .replaceAll('_', r'\_'));
            default:
              final sqlOp = _operators[opName];
              if (sqlOp == null) {
                throw TsukiroException(
                  TsukiroErrorCode.invalidArgs,
                  '不支持的操作符「$opName」。可用：${_operators.keys.join(', ')}, in, like, isNull',
                );
              }
              if (value == null) {
                throw TsukiroException(
                  TsukiroErrorCode.invalidArgs,
                  '列「$column」的 $opName 不能与 null 比较，请用 isNull',
                );
              }
              conditions.add('$real $sqlOp ?');
              args.add(value);
          }
        });
      } else if (raw == null) {
        conditions.add('$real IS NULL');
      } else {
        conditions.add('$real = ?');
        args.add(raw);
      }
    });

    // ── 作用域注入（**这是门**） ──
    final kind = scope.kind;
    switch (kind) {
      case DataScopeKind.all:
        break; // 持有 crossAgent，不加限制
      case DataScopeKind.ownAgent:
        if (entity.scopeColumn != null) {
          conditions.add('${entity.scopeColumn} = ?');
          args.add(scope.agentId);
        } else if (entity.scopeSubquery != null) {
          conditions.add('(${entity.scopeSubquery})');
          args.add(scope.agentId);
        } else {
          // 实体没有任何作用域列 → 无法过滤 → 只能给 crossAgent 用
          throw TsukiroException(
            TsukiroErrorCode.permissionDenied,
            '实体「${entity.name}」不支持按智能体过滤，需要 data.read.crossAgent',
          );
        }
      case DataScopeKind.none:
        // **fail-closed**：全局上下文 + 只有 data.read = 什么都看不到。
        //
        // 返回空结果而不是抛错：插件拿不到数据是"权限决定的结果"，
        // 不是"调用出错"。抛错会诱使插件作者去 catch 然后重试。
        conditions.add('1 = 0');
    }

    // ── order ──
    String orderSql;
    final order = query.order;
    if (order == null || order.isEmpty) {
      orderSql = entity.defaultOrder == null ? '' : ' ORDER BY ${entity.defaultOrder}';
    } else {
      final parts = order.split('.');
      if (parts.length != 2) {
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          'order 格式应为「列名.asc」或「列名.desc」，收到「$order」',
        );
      }
      final col = parts[0];
      if (!entity.exposes(col)) {
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          '实体「${entity.name}」没有列「$col」',
        );
      }
      final dir = parts[1].toLowerCase();
      if (dir != 'asc' && dir != 'desc') {
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          'order 方向只能是 asc 或 desc，收到「${parts[1]}」',
        );
      }
      orderSql = ' ORDER BY ${entity.realColumn(col)} ${dir.toUpperCase()}';
    }

    // ── limit ──
    final limit = query.limit.clamp(1, maxLimit);
    final offset = query.offset < 0 ? 0 : query.offset;

    final whereSql =
        conditions.isEmpty ? '' : ' WHERE ${conditions.join(' AND ')}';
    final sql = 'SELECT ${selected.join(', ')} FROM ${entity.table}'
        '$whereSql$orderSql LIMIT $limit OFFSET $offset';

    return QueryPlan(sql: sql, args: args, scope: kind, limit: limit);
  }

  /// 自省：让插件在运行期问「有什么可查、有哪些列」。
  ///
  /// 这样插件不必靠文档猜 —— 宿主加了实体它立刻能用。
  List<Map<String, dynamic>> describe() => entities.values
      .map((e) => <String, dynamic>{
            'entity': e.name,
            'columns': e.columns.keys.toList(growable: false),
            'scopable': e.isScopable,
          })
      .toList(growable: false);
}
