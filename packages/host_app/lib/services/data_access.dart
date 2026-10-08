/// 宿主侧的数据访问实现。
///
/// **这一层刻意很薄**：SQL 由内核的 [DataQueryCompiler] 生成
/// （列白名单、作用域注入、limit 夹取都在那边做完），
/// 这里只做「执行 + 包一层返回」。
///
/// 为什么这么分：拼 SQL 是最危险的部分，放在内核里就能
/// **脱离数据库做穷尽的单元测试**（见 `packages/plugin_core/test/data_query_test.dart`）。
///
/// 见 `docs/20-plugin-scope-and-data-access.md` §4。
library;

import 'package:plugin_core/plugin_core.dart';

import '../data/repositories.dart';
import '../plugin/host_services_impl.dart';

class AppDataAccess implements HostDataAccess {
  AppDataAccess({required this.repos, required this.chat});

  final Future<Repos> repos;
  final AppChatContext chat;

  static const DataQueryCompiler _compiler = DataQueryCompiler();

  @override
  Future<Map<String, dynamic>> query(
    String pluginId,
    DataQuery query, {
    bool crossAgent = false,
  }) async {
    // 作用域在这里最终定形。
    //
    // `agentId` 取"当前打开的智能体" —— 这是**宿主维护**的状态，
    // 插件改不了。等 docs/20 的 per-agent 安装落地后，
    // 这里换成"插件被安装到的那个智能体"，其余不变。
    final scope = DataScope(
      agentId: chat.activeAgentId,
      crossAgent: crossAgent,
    );

    // 编译失败会抛 TsukiroException，原语层会把它变成 err 回给插件。
    // **不吞** —— 插件传了坏参数就该被告知。
    final plan = _compiler.compileScoped(query, scope);
    final rows = await (await repos).rawQuery(plan.sql, plan.args);

    return <String, dynamic>{
      'rows': rows,
      'scope': plan.scope.name,
      'limit': plan.limit,
      'count': rows.length,
    };
  }

  @override
  List<Map<String, dynamic>> describeEntities() => _compiler.describe();
}
