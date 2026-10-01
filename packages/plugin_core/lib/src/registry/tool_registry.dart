/// 工具注册表 —— 插件声明的工具汇总，供模型函数调用。
///
/// 见 `docs/09-agent-and-tools.md` §1。
///
/// 两条硬规则：
///   1. **重名不覆盖**。后注册的同名工具改名为 `<插件前缀>__<原名>` 并记冲突。
///      静默覆盖会让先装的插件莫名失效，且极难排查。
///   2. **工具名必须符合 `[A-Za-z0-9_-]`**，因为部分 Provider 的 function name
///      只接受这个字符集。
library;

import '../manifest/manifest.dart';
import '../permission/gatekeeper.dart';

/// 注册表里的一条工具。
class RegisteredTool {
  const RegisteredTool({
    required this.name,
    required this.originalName,
    required this.description,
    required this.parameters,
    required this.pluginId,
    required this.pluginVersion,
    required this.handler,
    required this.permissions,
    required this.timeoutMs,
    required this.dangerous,
    required this.exposed,
    this.returns,
    this.renamedDueToConflict = false,
  });

  /// 暴露给模型的名字。可能因冲突加了前缀。
  final String name;

  /// manifest 里声明的原始名字。
  final String originalName;

  final String description;
  final Map<String, dynamic> parameters;
  final String pluginId;
  final String pluginVersion;
  final String handler;
  final List<String> permissions;
  final int timeoutMs;
  final bool dangerous;
  final bool exposed;
  final String? returns;

  /// 是否因重名被改名（用于审计与插件详情页提示）。
  final bool renamedDueToConflict;

  /// 转为 OpenAI `tools` 数组的一项。
  Map<String, dynamic> toOpenAiFormat() => <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };

  @override
  String toString() => 'RegisteredTool($name ← $pluginId/$handler)';
}

/// 注册时发生的名字冲突记录。
class ToolNameConflict {
  const ToolNameConflict({
    required this.requested,
    required this.assigned,
    required this.existingPluginId,
    required this.newPluginId,
  });

  final String requested;
  final String assigned;
  final String existingPluginId;
  final String newPluginId;
}

/// 工具注册表。
class ToolRegistry {
  final Map<String, RegisteredTool> _tools = <String, RegisteredTool>{};
  final Map<String, List<String>> _byPlugin = <String, List<String>>{};
  final List<ToolNameConflict> _conflicts = <ToolNameConflict>[];

  /// 注册一个插件的全部工具，返回因重名被改名的冲突记录。
  ///
  /// 重复注册同一 pluginId 会先注销旧工具（用于插件升级）。
  List<ToolNameConflict> registerPlugin(PluginManifest manifest) {
    unregisterPlugin(manifest.id);

    final registered = <String>[];
    final localConflicts = <ToolNameConflict>[];

    for (final tool in manifest.tools) {
      final existing = _tools[tool.name];
      var assigned = tool.name;
      var renamed = false;

      if (existing != null) {
        // 重名：加插件前缀，绝不覆盖
        final prefix = _prefixFor(manifest.id);
        assigned = '${prefix}__${tool.name}';
        var suffix = 2;
        while (_tools.containsKey(assigned)) {
          assigned = '${prefix}_${suffix}__${tool.name}';
          suffix++;
        }
        renamed = true;
        final conflict = ToolNameConflict(
          requested: tool.name,
          assigned: assigned,
          existingPluginId: existing.pluginId,
          newPluginId: manifest.id,
        );
        localConflicts.add(conflict);
        _conflicts.add(conflict);
      }

      _tools[assigned] = RegisteredTool(
        name: assigned,
        originalName: tool.name,
        description: tool.description,
        parameters: tool.parameters,
        pluginId: manifest.id,
        pluginVersion: manifest.version,
        handler: tool.handler,
        permissions: tool.permissions,
        timeoutMs: tool.timeoutMs,
        dangerous: tool.dangerous,
        exposed: tool.exposed,
        returns: tool.returns,
        renamedDueToConflict: renamed,
      );
      registered.add(assigned);
    }

    _byPlugin[manifest.id] = registered;
    return localConflicts;
  }

  /// 注销一个插件的全部工具。
  void unregisterPlugin(String pluginId) {
    final names = _byPlugin.remove(pluginId);
    if (names == null) return;
    for (final n in names) {
      // 只删属于该插件的条目，防止误删别人的
      if (_tools[n]?.pluginId == pluginId) _tools.remove(n);
    }
  }

  /// 按暴露名查找。
  RegisteredTool? lookup(String name) => _tools[name];

  /// 某个插件的全部工具（暴露名）。
  List<String> toolNamesOf(String pluginId) =>
      List<String>.unmodifiable(_byPlugin[pluginId] ?? const <String>[]);

  /// 全部已注册工具。
  Iterable<RegisteredTool> get all => _tools.values;

  int get length => _tools.length;

  /// 历史冲突记录（用于审计与诊断）。
  List<ToolNameConflict> get conflicts => List<ToolNameConflict>.unmodifiable(_conflicts);

  /// 计算送给模型的工具列表。
  ///
  /// 三个过滤源（见 `docs/09-agent-and-tools.md` §1.4）：
  ///   1. 权限 —— 工具所需权限未全部授予 → 不可见
  ///   2. Skill 白名单 —— 非空时只保留名单内工具
  ///   3. 用户开关 —— 用户在插件详情页关掉的工具
  ///
  /// **为什么按权限过滤**：一个必然因权限不足而失败的工具给模型，只会浪费一次
  /// 往返并产生无意义的错误。
  List<RegisteredTool> visibleTools({
    required Gatekeeper gatekeeper,
    Set<String>? skillAllowList,
    Map<String, bool>? userToggles,
  }) {
    final result = <RegisteredTool>[];
    for (final tool in _tools.values) {
      if (userToggles != null && userToggles[tool.name] == false) continue;

      if (skillAllowList != null &&
          skillAllowList.isNotEmpty &&
          !skillAllowList.contains(tool.name) &&
          !skillAllowList.contains(tool.originalName)) {
        continue;
      }

      var permissionOk = true;
      for (final perm in tool.permissions) {
        if (!gatekeeper.check(tool.pluginId, perm).isAllowed) {
          permissionOk = false;
          break;
        }
      }
      if (!permissionOk) continue;

      result.add(tool);
    }
    // 稳定排序，避免每次请求顺序不同导致 provider 侧 prompt cache 失效
    result.sort((a, b) {
      final byPlugin = a.pluginId.compareTo(b.pluginId);
      return byPlugin != 0 ? byPlugin : a.name.compareTo(b.name);
    });
    return result;
  }

  /// 转为 OpenAI `tools` 数组。
  List<Map<String, dynamic>> toOpenAiTools({
    required Gatekeeper gatekeeper,
    Set<String>? skillAllowList,
    Map<String, bool>? userToggles,
  }) =>
      visibleTools(
        gatekeeper: gatekeeper,
        skillAllowList: skillAllowList,
        userToggles: userToggles,
      ).map((t) => t.toOpenAiFormat()).toList(growable: false);

  /// 清空（测试用）。
  void clear() {
    _tools.clear();
    _byPlugin.clear();
    _conflicts.clear();
  }
}

/// 由插件 id 推导出符合 Provider 字符集的前缀。
///
/// `dev.tsukiro.time` → `time`
String _prefixFor(String pluginId) {
  final segments = pluginId.split('.').where((s) => s.isNotEmpty).toList();
  final last = segments.isEmpty ? pluginId : segments.last;
  final sanitized = last.replaceAll(RegExp('[^A-Za-z0-9]'), '_').toLowerCase();
  return sanitized.isEmpty ? 'plugin' : sanitized;
}
