/// 设置页。
///
/// 按 `docs/01-overview.md` 的原则 2「高级设置隐藏」——
/// 普通用户看到的是模型状态和一句话说明，技术字段折叠在「高级」里。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_gateway/model_gateway.dart';

import '../providers/app_providers.dart';
import '../theme/app_theme.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _advancedOpen = false;
  bool _checking = false;
  ConnectionCheck? _check;
  List<ModelInfo> _models = const <ModelInfo>[];

  late TextEditingController _baseUrl;
  late TextEditingController _apiKey;
  late TextEditingController _model;
  ProviderProtocol _protocol = ProviderProtocol.openai;

  @override
  void initState() {
    super.initState();
    final p = ref.read(effectiveProviderProvider);
    _baseUrl = TextEditingController(text: p?.baseUrl ?? '');
    _apiKey = TextEditingController(text: p?.apiKey ?? '');
    _model = TextEditingController(text: p?.defaultModel ?? '');
    _protocol = p?.protocol ?? ProviderProtocol.openai;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final config = ref.watch(appConfigProvider).valueOrNull;
    final effective = ref.watch(effectiveProviderProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: EdgeInsets.symmetric(vertical: t.spacing.section.toDouble() / 2),
        children: <Widget>[
          _SectionTitle('模型'),
          _StatusCard(
            ready: effective?.isUsable ?? false,
            summary: effective == null
                ? '未配置'
                : '${effective.displayName ?? effective.protocol.name} · ${effective.defaultModel ?? "未指定模型"}',
            detail: effective == null
                ? (config?.loadNote ?? '去下面的「高级」里填写')
                : '${effective.protocol.name} @ ${effective.normalizedBaseUrl}',
            onTest: _runCheck,
            checking: _checking,
            check: _check,
            models: _models,
            onPickModel: (id) {
              _model.text = id;
              _save();
            },
          ),

          const SizedBox(height: 8),
          _SectionTitle('对话'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('当前人设'),
            subtitle: Text(
              config?.persona.name ?? '雪',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showPersonaDialog(),
          ),

          const SizedBox(height: 8),
          _AdvancedSection(
            open: _advancedOpen,
            onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
            child: Column(
              children: <Widget>[
                ListTile(
                  title: const Text('协议'),
                  subtitle: Text(_protocolLabel(_protocol)),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: _pickProtocol,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    controller: _baseUrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://api.example.com/v1',
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onEditingComplete: _save,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    controller: _apiKey,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: 'sk-…',
                      // 默认遮蔽 —— 但给一个"看一眼"的开关，
                      // 因为用户粘贴错了却看不见，是更常见的痛苦
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        onPressed: _revealKey,
                      ),
                    ),
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    onEditingComplete: _save,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: TextField(
                    controller: _model,
                    decoration: const InputDecoration(
                      labelText: '模型名',
                      hintText: 'deepseek-v4.1-flash',
                    ),
                    autocorrect: false,
                    onEditingComplete: _save,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton(
                          onPressed: _save,
                          child: const Text('保存'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: _resetToAsset,
                        child: const Text('重置'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),
          _SectionTitle('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Tsukiro Chat'),
            subtitle: Text('0.1.0 · 插件化 AI 陪伴平台'),
          ),
          const ListTile(
            leading: Icon(Icons.warning_amber_rounded),
            title: Text('虚拟商品说明'),
            subtitle: Text('对话内容由 AI 生成，仅供参考。'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── 动作 ───────────────────────────

  void _save() {
    final base = _baseUrl.text.trim();
    final key = _apiKey.text.trim();
    final model = _model.text.trim();

    if (base.isEmpty && key.isEmpty) {
      ref.read(providerOverrideProvider.notifier).state = null;
    } else {
      ref.read(providerOverrideProvider.notifier).state = ProviderConfig(
        protocol: _protocol,
        baseUrl: base,
        apiKey: key,
        defaultModel: model.isEmpty ? null : model,
        displayName: '自定义',
      );
    }
    // 配置变了，之前的检查结果作废
    setState(() {
      _check = null;
      _models = const <ModelInfo>[];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
    );
  }

  void _resetToAsset() {
    final asset = ref.read(appConfigProvider).valueOrNull?.provider;
    setState(() {
      _baseUrl.text = asset?.baseUrl ?? '';
      _apiKey.text = asset?.apiKey ?? '';
      _model.text = asset?.defaultModel ?? '';
      _protocol = asset?.protocol ?? ProviderProtocol.openai;
      _check = null;
      _models = const <ModelInfo>[];
    });
    ref.read(providerOverrideProvider.notifier).state = null;
  }

  Future<void> _runCheck() async {
    final config = ref.read(effectiveProviderProvider);
    if (config == null || !config.isUsable) {
      setState(() {
        _check = const ConnectionCheck(
          ok: false,
          errorMessage: '先填 Base URL 和 API Key',
        );
      });
      return;
    }

    setState(() => _checking = true);
    final gateway = HttpModelGateway(config: config);
    try {
      // 只拉模型表，**不消耗 token** —— "测试连接"不该让用户花钱
      final result = await gateway.check();
      if (!mounted) return;
      setState(() {
        _check = result;
        _models = result.models;
        _checking = false;
      });
    } finally {
      gateway.close();
    }
  }

  void _revealKey() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API Key'),
        content: SelectableText(
          _apiKey.text.isEmpty ? '（空）' : _apiKey.text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _pickProtocol() async {
    final picked = await showModalBottomSheet<ProviderProtocol>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // 不用 RadioListTile：它的 groupValue/onChanged 在 Flutter 3.32+
          // 已废弃（要包一层 RadioGroup）。这里就一个简单选择列表，
          // ListTile + 勾选图标更直接，也少一层状态传递。
          children: ProviderProtocol.values.map((p) {
            final selected = p == _protocol;
            return ListTile(
              title: Text(_protocolLabel(p)),
              subtitle: Text(_protocolHint(p), style: const TextStyle(fontSize: 12)),
              trailing: selected
                  ? Icon(Icons.check, size: 18, color: context.tokens.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, p),
            );
          }).toList(growable: false),
        ),
      ),
    );
    if (picked != null) setState(() => _protocol = picked);
  }

  void _showPersonaDialog() {
    final persona = ref.read(personaProvider);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(persona.name),
        content: SelectableText(persona.systemPrompt),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  static String _protocolLabel(ProviderProtocol p) {
    switch (p) {
      case ProviderProtocol.openai:
        return 'OpenAI 兼容';
      case ProviderProtocol.anthropic:
        return 'Anthropic';
      case ProviderProtocol.google:
        return 'Google Gemini';
    }
  }

  static String _protocolHint(ProviderProtocol p) {
    switch (p) {
      case ProviderProtocol.openai:
        return '绝大多数中转站和自建服务都是这个';
      case ProviderProtocol.anthropic:
        return 'Claude 官方 Messages API';
      case ProviderProtocol.google:
        return 'Gemini Generative Language API';
    }
  }
}

// ─────────────────────────── 组件 ───────────────────────────

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

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.ready,
    required this.summary,
    required this.detail,
    required this.onTest,
    required this.checking,
    required this.check,
    required this.models,
    required this.onPickModel,
  });

  final bool ready;
  final String summary;
  final String detail;
  final VoidCallback onTest;
  final bool checking;
  final ConnectionCheck? check;
  final List<ModelInfo> models;
  final void Function(String) onPickModel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Card(
      margin: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ready ? t.success : t.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(summary, style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(detail, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: checking ? null : onTest,
                  icon: checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 16),
                  label: Text(checking ? '检测中…' : '测试连接'),
                ),
                const SizedBox(width: 10),
                if (check != null)
                  Expanded(
                    child: Text(
                      check!.ok
                          ? '✓ 通 · ${check!.modelCount} 个模型 · ${check!.latency.inMilliseconds}ms'
                          : '✗ ${check!.errorMessage}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: check!.ok ? t.success : t.danger,
                      ),
                    ),
                  ),
              ],
            ),
            if (check != null) ...[
              const SizedBox(height: 6),
              Text(
                '测试连接只拉模型表，**不消耗 token**',
                style: TextStyle(fontSize: 11, color: t.textMuted),
              ),
            ],
            if (models.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(color: t.divider),
              const SizedBox(height: 6),
              Text('可用模型（点一下填入）',
                  style: TextStyle(fontSize: 12, color: t.textMuted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: models.map((m) {
                  return ActionChip(
                    label: Text(m.id, style: const TextStyle(fontSize: 12)),
                    onPressed: () => onPickModel(m.id),
                    backgroundColor: t.background,
                    side: BorderSide(color: t.divider),
                  );
                }).toList(growable: false),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.open,
    required this.onToggle,
    required this.child,
  });

  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      children: <Widget>[
        ListTile(
          leading: Icon(
            open ? Icons.expand_less : Icons.expand_more,
            color: t.textMuted,
          ),
          title: const Text('高级'),
          subtitle: Text(
            open ? '收起' : '供应商 / API Key / 模型名',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          onTap: onToggle,
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: open ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          firstChild: child,
          secondChild: const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }
}
