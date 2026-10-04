/// 添加 / 编辑服务商。
///
/// 支持 OpenAI / Anthropic / Google 三种协议，以及拉取模型表与手动补模型。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_gateway/model_gateway.dart';

import '../../data/models.dart';
import '../../providers/app_providers.dart';
import '../../theme/app_theme.dart';
import '../user_error.dart';

class ProviderEditPage extends ConsumerStatefulWidget {
  const ProviderEditPage({super.key, this.providerId});

  /// null = 新建。
  final String? providerId;

  @override
  ConsumerState<ProviderEditPage> createState() => _ProviderEditPageState();
}

class _ProviderEditPageState extends ConsumerState<ProviderEditPage> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _manualModel = TextEditingController();

  ProviderProtocol _protocol = ProviderProtocol.openai;
  bool _loaded = false;
  bool _busy = false;
  bool _obscureKey = true;

  String? _testResult;
  bool _testOk = false;

  bool get _isNew => widget.providerId == null;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _manualModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final existing = _isNew
        ? null
        : ref.watch(providerListProvider).valueOrNull
            ?.where((p) => p.id == widget.providerId)
            .firstOrNull;

    if (existing != null && !_loaded) {
      _loaded = true;
      _name.text = existing.name;
      _baseUrl.text = existing.baseUrl;
      _apiKey.text = existing.apiKey;
      _protocol = existing.protocol;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '添加服务商' : (existing?.name ?? '编辑服务商')),
        actions: <Widget>[
          TextButton(
            onPressed: _busy ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(vertical: t.spacing.section.toDouble() / 2),
        children: <Widget>[
          _SectionTitle('基本信息'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '给自己看的，随便起',
              ),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.cable_outlined),
            title: const Text('协议'),
            subtitle: Text(_protocolHint(_protocol),
                style: Theme.of(context).textTheme.bodySmall),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(_protocolLabel(_protocol), style: TextStyle(color: t.primary)),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
            onTap: _pickProtocol,
          ),

          const SizedBox(height: 8),
          _SectionTitle('连接'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _baseUrl,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.example.com/v1',
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => setState(() => _testResult = null),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _apiKey,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: 'sk-…',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                  obscureText: _obscureKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() => _testResult = null),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _testConnection,
                  icon: _busy
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 16),
                  label: Text(_busy ? '检测中…' : '测试并拉取模型'),
                ),
              ],
            ),
          ),
          if (_testResult != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                t.spacing.page.toDouble(),
                10,
                t.spacing.page.toDouble(),
                0,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    _testOk ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: _testOk ? t.success : t.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: _testOk ? t.success : t.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              t.spacing.page.toDouble(),
              4,
              t.spacing.page.toDouble(),
              0,
            ),
            child: Text(
              '测试只拉模型列表，不消耗 token。',
              style: TextStyle(fontSize: 11, color: t.textMuted),
            ),
          ),

          if (existing != null) ...<Widget>[
            const SizedBox(height: 8),
            _SectionTitle('模型'),
            _ModelList(provider: existing),
            Padding(
              padding: EdgeInsets.fromLTRB(
                t.spacing.page.toDouble(),
                12,
                t.spacing.page.toDouble(),
                0,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _manualModel,
                      decoration: const InputDecoration(
                        labelText: '手动添加模型',
                        hintText: '有些中转站的模型表不全',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: () => _addManualModel(existing),
                    icon: const Icon(Icons.add, size: 18),
                  ),
                ],
              ),
            ),
          ],

          if (existing != null && !existing.isOfficial) ...<Widget>[
            const SizedBox(height: 8),
            _SectionTitle('危险操作'),
            ListTile(
              leading: Icon(Icons.delete_outline, color: t.danger),
              title: Text('删除服务商', style: TextStyle(color: t.danger)),
              subtitle: Text(
                '会连同它的 ${existing.modelCount} 个模型记录一起删除',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () => _delete(existing),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ─────────────────────────── 动作 ───────────────────────────

  Future<void> _save() async {
    final name = _name.text.trim();
    final base = _baseUrl.text.trim();
    final key = _apiKey.text.trim();

    if (name.isEmpty) return _toast('给服务商起个名字');
    if (base.isEmpty) return _toast('Base URL 不能为空');

    final repos = await ref.read(reposProvider.future);
    if (_isNew) {
      await repos.providers.create(
        name: name,
        protocol: _protocol,
        baseUrl: base,
        apiKey: key,
      );
    } else {
      final p = await repos.providers.get(widget.providerId!);
      if (p == null) return _toast('服务商不存在');
      p
        ..name = name
        ..protocol = _protocol
        ..baseUrl = base
        ..apiKey = key;
      await repos.providers.upsert(p);
    }

    ref.invalidate(providerListProvider);
    ref.invalidate(modelChoicesProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _testConnection() async {
    final base = _baseUrl.text.trim();
    final key = _apiKey.text.trim();
    if (base.isEmpty || key.isEmpty) {
      setState(() {
        _testOk = false;
        _testResult = '先填 Base URL 和 API Key';
      });
      return;
    }

    setState(() {
      _busy = true;
      _testResult = null;
    });

    // 先把当前输入落库，这样模型表才有地方写
    final repos = await ref.read(reposProvider.future);
    String providerId;
    if (_isNew) {
      final created = await repos.providers.create(
        name: _name.text.trim().isEmpty ? '未命名服务商' : _name.text.trim(),
        protocol: _protocol,
        baseUrl: base,
        apiKey: key,
      );
      providerId = created.id;
      _loaded = true;
      // 从"新建"变成"编辑" —— 否则下面拿不到 provider
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
          builder: (_) => ProviderEditPage(providerId: providerId),
        ));
      }
      setState(() => _busy = false);
      return;
    }
    providerId = widget.providerId!;
    final p = await repos.providers.get(providerId);
    if (p != null) {
      p
        ..baseUrl = base
        ..apiKey = key
        ..protocol = _protocol;
      await repos.providers.upsert(p);
    }

    final gateway = HttpModelGateway(
      config: ProviderConfig(
        protocol: _protocol,
        baseUrl: base,
        apiKey: key,
        displayName: _name.text.trim(),
      ),
    );
    try {
      final result = await gateway.check();
      if (!mounted) return;
      if (result.ok) {
        await repos.providers.replaceDiscovered(providerId, result.models);
        ref.invalidate(providerModelsProvider(providerId));
        ref.invalidate(providerListProvider);
      }
      setState(() {
        _testOk = result.ok;
        _testResult = result.ok
            ? '通了 · ${result.modelCount} 个模型 · ${result.latency.inMilliseconds}ms'
            : userFacingConnectionError(result.errorMessage);
        _busy = false;
      });
    } finally {
      gateway.close();
    }
  }

  Future<void> _addManualModel(ModelProvider provider) async {
    final id = _manualModel.text.trim();
    if (id.isEmpty) return;
    final repos = await ref.read(reposProvider.future);
    await repos.providers.addManualModel(provider.id, id);
    _manualModel.clear();
    ref.invalidate(providerModelsProvider(provider.id));
    ref.invalidate(providerListProvider);
    ref.invalidate(modelChoicesProvider);
    if (mounted) setState(() {});
  }

  Future<void> _pickProtocol() async {
    final picked = await showModalBottomSheet<ProviderProtocol>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: ProviderProtocol.values.map((p) {
            return ListTile(
              title: Text(_protocolLabel(p)),
              subtitle: Text(_protocolHint(p), style: const TextStyle(fontSize: 12)),
              trailing: p == _protocol
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

  Future<void> _delete(ModelProvider provider) async {
    final t = context.tokens;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除服务商'),
        content: Text('「${provider.name}」及其模型记录会被删除。已配置使用它的智能体会回退到默认服务商。'),
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
    await repos.providers.delete(provider.id);
    ref.invalidate(providerListProvider);
    ref.invalidate(modelChoicesProvider);
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  static String _protocolLabel(ProviderProtocol p) => switch (p) {
        ProviderProtocol.openai => 'OpenAI 兼容',
        ProviderProtocol.anthropic => 'Anthropic',
        ProviderProtocol.google => 'Google Gemini',
      };

  static String _protocolHint(ProviderProtocol p) => switch (p) {
        ProviderProtocol.openai => '绝大多数中转站和自建服务都是这个',
        ProviderProtocol.anthropic => 'Claude 官方 Messages API',
        ProviderProtocol.google => 'Gemini Generative Language API',
      };
}

class _ModelList extends ConsumerWidget {
  const _ModelList({required this.provider});

  final ModelProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final models = ref.watch(providerModelsProvider(provider.id));

    return models.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
      data: (list) {
        if (list.isEmpty) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: Text(
              '还没有模型。点上面的「测试并拉取模型」自动获取，或手动添加。',
              style: TextStyle(fontSize: 12.5, color: t.textMuted),
            ),
          );
        }
        return Column(
          children: <Widget>[
            for (final m in list)
              ListTile(
                dense: true,
                leading: Icon(
                  m.isManual ? Icons.push_pin_outlined : Icons.cloud_done_outlined,
                  size: 16,
                  color: t.textMuted,
                ),
                title: Text(m.id, style: const TextStyle(fontSize: 13.5)),
                subtitle: m.isManual
                    ? Text('手动添加', style: TextStyle(fontSize: 11, color: t.textMuted))
                    : null,
                trailing: IconButton(
                  icon: Icon(Icons.close, size: 16, color: t.textMuted),
                  onPressed: () async {
                    final repos = await ref.read(reposProvider.future);
                    await repos.providers.removeModel(provider.id, m.id);
                    ref.invalidate(providerModelsProvider(provider.id));
                    ref.invalidate(providerListProvider);
                    ref.invalidate(modelChoicesProvider);
                  },
                ),
              ),
          ],
        );
      },
    );
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
