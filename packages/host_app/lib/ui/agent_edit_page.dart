/// 编辑智能体：人设 / 模型 / 记忆。
///
/// **人设默认为空** —— 宿主不预置任何角色（见 `docs/18-agent-and-memory.md` §6）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../providers/app_providers.dart';
import 'plugin_slot.dart';
import '../theme/app_theme.dart';
import 'settings/model_picker_page.dart';

class AgentEditPage extends ConsumerStatefulWidget {
  const AgentEditPage({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<AgentEditPage> createState() => _AgentEditPageState();
}

class _AgentEditPageState extends ConsumerState<AgentEditPage> {
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  final _greeting = TextEditingController();
  final _worldBook = TextEditingController();

  Agent? _agent;
  bool _loaded = false;
  bool _dirty = false;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _greeting.dispose();
    _worldBook.dispose();
    super.dispose();
  }

  void _loadFrom(Agent a) {
    if (_loaded) return;
    _loaded = true;
    _agent = a;
    _name.text = a.name;
    _prompt.text = a.persona.systemPrompt;
    _greeting.text = a.persona.greeting ?? '';
    _worldBook.text = a.persona.worldBook ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final async = ref.watch(agentProvider(widget.agentId));

    return async.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: Center(child: Text('$e'))),
      data: (agent) {
        if (agent == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('智能体不存在（可能已被删除）')),
          );
        }
        _loadFrom(agent);
        final resolved = ref.watch(resolvedModelProvider(agent.id));

        return Scaffold(
          appBar: AppBar(
            title: const Text('编辑智能体'),
            actions: <Widget>[
              TextButton(
                onPressed: _dirty ? _save : null,
                child: const Text('保存'),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.symmetric(vertical: t.spacing.section.toDouble() / 2),
            children: <Widget>[
              _SectionTitle('基本'),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '名称'),
                  onChanged: (_) => _mark(),
                ),
              ),

              const SizedBox(height: 8),
              _SectionTitle('人设'),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '留空也可以，不会替你填任何默认角色。',
                      style: TextStyle(fontSize: 12, color: t.textMuted),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _prompt,
                      minLines: 4,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        labelText: '角色设定',
                        hintText: '例如：你是……，说话风格是……',
                        alignLabelWithHint: true,
                      ),
                      onChanged: (_) => _mark(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _greeting,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '开场白（可选）',
                        hintText: '新建对话时先说的那句',
                      ),
                      onChanged: (_) => _mark(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _worldBook,
                      minLines: 3,
                      maxLines: 12,
                      decoration: const InputDecoration(
                        labelText: '世界设定 / 世界书（可选）',
                        hintText: '大段背景设定，会附加在角色设定之后',
                        alignLabelWithHint: true,
                      ),
                      onChanged: (_) => _mark(),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),
              _SectionTitle('模型'),
              ListTile(
                leading: const Icon(Icons.memory),
                title: const Text('这个智能体用哪个模型'),
                subtitle: Text(
                  resolved?.label ?? '未配置（去「设置 → 模型配置」添加服务商）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (agent.model.providerId != null)
                      TextButton(
                        onPressed: () => _clearModel(agent),
                        child: const Text('跟随默认'),
                      ),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
                onTap: () => _pickModel(agent),
              ),

              const SizedBox(height: 8),
              // 插件插槽：智能体详情分区。
              //
              // status-panel 的「状态面板」声明在 agent.sections ——
              // 这里不放位置的话，插件声明了也永远看不到。
              Padding(
                padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
                child: PluginSlot(
                  slot: 'agent.sections',
                  axis: Axis.vertical,
                  context: <String, dynamic>{'agentId': widget.agentId},
                ),
              ),

              const SizedBox(height: 8),
              _SectionTitle('记忆'),
              SwitchListTile(
                value: agent.memory.enabled,
                onChanged: (v) => _setMemory(agent, agent.memory.copyWithEnabled(v)),
                title: const Text('启用记忆'),
                subtitle: const Text('关掉之后这个智能体不再读写记忆'),
              ),
              ListTile(
                enabled: agent.memory.enabled,
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('记忆粒度'),
                subtitle: Text(
                  agent.memory.scope == MemoryScope.agent
                      ? '所有对话共享（默认）—— 换个话题它还认得你'
                      : '每个对话各自独立 —— 换个对话就重新开始',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onTap: agent.memory.enabled ? () => _pickScope(agent) : null,
              ),
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('记忆条数'),
                subtitle: Text('${agent.memoryCount} 条',
                    style: Theme.of(context).textTheme.bodySmall),
              ),

              const SizedBox(height: 8),
              _SectionTitle('危险操作'),
              ListTile(
                leading: Icon(Icons.delete_outline, color: t.danger),
                title: Text('删除智能体', style: TextStyle(color: t.danger)),
                subtitle: Text(
                  '会连同它的 ${agent.conversationCount} 个对话和 ${agent.memoryCount} 条记忆一起删除',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onTap: () => _delete(agent),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  void _mark() => setState(() => _dirty = true);

  Future<void> _save() async {
    final agent = _agent;
    if (agent == null) return;

    agent.name = _name.text.trim().isEmpty ? '未命名' : _name.text.trim();
    agent.persona = agent.persona.copyWith(
      systemPrompt: _prompt.text.trim(),
      greeting: _greeting.text.trim(),
      clearGreeting: _greeting.text.trim().isEmpty,
      worldBook: _worldBook.text.trim(),
      clearWorldBook: _worldBook.text.trim().isEmpty,
    );

    final repos = await ref.read(reposProvider.future);
    await repos.agents.update(agent);

    ref.invalidate(agentListProvider);
    ref.invalidate(agentProvider(agent.id));
    if (mounted) setState(() => _dirty = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _pickModel(Agent agent) async {
    final choice = await Navigator.of(context).push<ModelChoice>(
      MaterialPageRoute<ModelChoice>(builder: (_) => const ModelPickerPage()),
    );
    if (choice == null) return;

    agent.model = agent.model.copyWith(
      providerId: choice.provider.id,
      modelId: choice.modelId,
    );
    await _persistModel(agent);
  }

  Future<void> _clearModel(Agent agent) async {
    agent.model = agent.model.copyWith(clearProvider: true, clearModel: true);
    await _persistModel(agent);
  }

  Future<void> _persistModel(Agent agent) async {
    final repos = await ref.read(reposProvider.future);
    await repos.agents.update(agent);
    ref.invalidate(agentProvider(agent.id));
    ref.invalidate(modelChoicesProvider);
    if (mounted) setState(() {});
  }

  Future<void> _setMemory(Agent agent, MemoryConfig config) async {
    agent.memory = config;
    final repos = await ref.read(reposProvider.future);
    await repos.agents.update(agent);
    ref.invalidate(agentProvider(agent.id));
    if (mounted) setState(() {});
  }

  Future<void> _pickScope(Agent agent) async {
    final picked = await showModalBottomSheet<MemoryScope>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: const Text('所有对话共享'),
              subtitle: const Text('默认。陪伴场景通常要的是「记得我」', style: TextStyle(fontSize: 12)),
              trailing: agent.memory.scope == MemoryScope.agent
                  ? Icon(Icons.check, color: context.tokens.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, MemoryScope.agent),
            ),
            ListTile(
              title: const Text('每个对话独立'),
              subtitle: const Text('换个对话就重新开始', style: TextStyle(fontSize: 12)),
              trailing: agent.memory.scope == MemoryScope.conversation
                  ? Icon(Icons.check, color: context.tokens.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, MemoryScope.conversation),
            ),
          ],
        ),
      ),
    );
    if (picked != null) await _setMemory(agent, agent.memory.copyWithScope(picked));
  }

  Future<void> _delete(Agent agent) async {
    final t = context.tokens;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除智能体'),
        content: Text(
          '「${agent.name}」以及它的 ${agent.conversationCount} 个对话、'
          '${agent.memoryCount} 条记忆会被永久删除，无法恢复。',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: t.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final repos = await ref.read(reposProvider.future);
    await repos.agents.delete(agent.id);
    ref.invalidate(agentListProvider);
    if (mounted) Navigator.of(context).pop();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(t.spacing.page.toDouble(), 12, t.spacing.page.toDouble(), 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: t.textMuted,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// [MemoryConfig] 的两个便捷改法 —— 它是 immutable，每次要显式构造。
extension MemoryConfigX on MemoryConfig {
  MemoryConfig copyWithEnabled(bool enabled) => MemoryConfig(
        scope: scope,
        enabled: enabled,
        providerPluginId: providerPluginId,
        maxEntries: maxEntries,
      );

  MemoryConfig copyWithScope(MemoryScope newScope) => MemoryConfig(
        scope: newScope,
        enabled: enabled,
        providerPluginId: providerPluginId,
        maxEntries: maxEntries,
      );
}
