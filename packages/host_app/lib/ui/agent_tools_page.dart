/// 智能体 · 工具：这个智能体的模型能看到哪些工具。
///
/// ## 为什么用「工具」而不是「插件」
///
/// 插件是**装载单位**，工具是**能力单位**。用户真正想控制的是
/// 「这个智能体能做什么」，而他能感知的形态只有工具 —— 他看不见
/// 插件的钩子和后台任务。
///
/// 所以这里按插件分组列出工具，勾选就是逐智能体的开关。
/// 一个插件的全选/取消，等价于「逐智能体插件启用」（对工具这一面）。
///
/// 不单独做「逐智能体插件页」的理由见 `docs/26` §2 和 `docs/27` §4：
/// 带 UI 贡献或钩子的插件光屏蔽工具不够，那些作用域本来就不该逐智能体。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';

import '../plugin/app_keys.dart';
import '../providers/plugin_providers.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';

/// 存储键：某个智能体关掉的工具名。
///
/// 用 settings 而不是给 agents 表加字段 —— 加字段要迁移，
/// 而这个数据只在这一页读写，没必要动数据库。
String agentToolExcludesKey(String agentId) => 'agent.toolExcludes.$agentId';

class AgentToolsPage extends ConsumerStatefulWidget {
  const AgentToolsPage({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<AgentToolsPage> createState() => _AgentToolsPageState();
}

class _AgentToolsPageState extends ConsumerState<AgentToolsPage> {
  Set<String> _disabled = <String>{};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repos = await ref.read(reposProvider.future);
    final raw = await repos.settings.get(agentToolExcludesKey(widget.agentId));
    var names = <String>{};
    if (raw != null) {
      try {
        names = (jsonDecode(raw) as List).cast<String>().toSet();
      } catch (_) {
        // 存坏了就当没关过 —— 宁可多给工具，也不要莫名少一堆
      }
    }
    if (!mounted) return;
    setState(() {
      _disabled = names;
      _loaded = true;
    });
  }

  Future<void> _persist() async {
    final repos = await ref.read(reposProvider.future);
    await repos.settings.set(
      agentToolExcludesKey(widget.agentId),
      jsonEncode(_disabled.toList()),
    );
  }

  void _toggle(String name, bool enabled) {
    setState(() {
      if (enabled) {
        _disabled.remove(name);
      } else {
        _disabled.add(name);
      }
    });
    _persist();
  }

  void _setGroup(List<RegisteredTool> tools, bool enabled) {
    setState(() {
      for (final t in tools) {
        if (enabled) {
          _disabled.remove(t.name);
        } else {
          _disabled.add(t.name);
        }
      }
    });
    _persist();
  }

  /// 插件 id → 给人看的名字。
  String _sourceName(String pluginId) {
    if (pluginId == hostPluginId) return '宿主（应用自带）';
    if (pluginId.startsWith('mcp:')) {
      return 'MCP · ${pluginId.substring('mcp:'.length)}';
    }
    final host = ref.read(pluginHostValueProvider);
    return host?.byId(pluginId)?.name ?? pluginId;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final registry = ref.watch(toolRegistryProvider);
    final all = registry.all.toList();

    // 按插件分组，组内按名字排序 —— 和送给模型的顺序一致，
    // 用户看到的顺序就是模型看到的顺序。
    final groups = <String, List<RegisteredTool>>{};
    for (final tool in all) {
      groups.putIfAbsent(tool.pluginId, () => <RegisteredTool>[]).add(tool);
    }
    for (final list in groups.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    final groupKeys = groups.keys.toList()
      ..sort((a, b) {
        // 宿主排最前，其余按名字
        if (a == hostPluginId) return -1;
        if (b == hostPluginId) return 1;
        return _sourceName(a).compareTo(_sourceName(b));
      });

    final enabledCount = all.where((x) => !_disabled.contains(x.name)).length;

    return Scaffold(
      appBar: AppBar(title: const Text('工具')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(t.spacing.section.toDouble()),
              children: <Widget>[
                // **把"后果"说清楚。**
                //
                // 开关的后果不是"装了/没装"，而是"进不进上下文"。
                // 用户看到这个数字，才能判断上下文预算被吃掉多少。
                Container(
                  padding: EdgeInsets.all(t.spacing.section.toDouble()),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
                  ),
                  child: Text(
                    '共 ${all.length} 个工具，$enabledCount 个会进上下文。\n'
                    '关掉的工具不会出现在这个智能体的模型面前 —— '
                    '模型看不到就调不了。',
                    style: TextStyle(fontSize: 12, color: t.textMuted),
                  ),
                ),
                const SizedBox(height: 8),
                for (final key in groupKeys) ...<Widget>[
                  _GroupHeader(
                    title: _sourceName(key),
                    tools: groups[key]!,
                    disabled: _disabled,
                    onToggleAll: (v) => _setGroup(groups[key]!, v),
                  ),
                  for (final tool in groups[key]!)
                    CheckboxListTile(
                      dense: true,
                      value: !_disabled.contains(tool.name),
                      onChanged: (v) => _toggle(tool.name, v ?? false),
                      title: Text(
                        tool.name,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        tool.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: t.textMuted),
                      ),
                    ),
                  const SizedBox(height: 4),
                ],
              ],
            ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.tools,
    required this.disabled,
    required this.onToggleAll,
  });

  final String title;
  final List<RegisteredTool> tools;
  final Set<String> disabled;
  final ValueChanged<bool> onToggleAll;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final on = tools.where((x) => !disabled.contains(x.name)).length;
    final allOn = on == tools.length;

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '$title（$on/${tools.length}）',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                
              ),
            ),
          ),
          // 全选/取消一组 —— 这就是「逐智能体插件启用」在工具层的等价物
          TextButton(
            onPressed: () => onToggleAll(!allOn),
            child: Text(
              allOn ? '全不选' : '全选',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
