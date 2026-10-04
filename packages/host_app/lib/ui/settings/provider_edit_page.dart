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

/// 连接测试的进度 / 结果。
///
/// 做成一个显式状态机而不是一个 bool：**用户要能看懂卡在哪一步**。
/// 早先只有一个 `_busy` 布尔，失败得又太快，界面上什么都来不及显示，
/// 就成了"点了没反应，直接报错"。
enum _TestPhase { idle, connecting, listing, done }

class _ProviderEditPageState extends ConsumerState<ProviderEditPage> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _manualModel = TextEditingController();

  ProviderProtocol _protocol = ProviderProtocol.openai;
  bool _loaded = false;
  bool _obscureKey = true;

  _TestPhase _phase = _TestPhase.idle;
  ConnectionCheck? _result;
  String? _rawError;

  bool get _isNew => widget.providerId == null;
  bool get _busy => _phase == _TestPhase.connecting || _phase == _TestPhase.listing;

  /// 用户填的是明文 HTTP。
  ///
  /// 国内大量中转站只提供 http，所以**不阻止**，但要明确告知 ——
  /// 用户有权知道他正在用明文把 API Key 发出去。
  bool get _isCleartext {
    final u = _baseUrl.text.trim().toLowerCase();
    return u.startsWith('http://');
  }

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
        : ref
            .watch(providerListProvider)
            .valueOrNull
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
                  onChanged: (_) => _invalidateResult(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _apiKey,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: 'sk-…',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                  obscureText: _obscureKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => _invalidateResult(),
                ),
              ],
            ),
          ),

          if (_isCleartext) const _CleartextWarning(),

          const SizedBox(height: 12),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _testConnection,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering, size: 16),
              label: Text(_busy ? '测试中…' : '测试并拉取模型'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            ),
          ),

          _TestStatus(phase: _phase, result: _result, rawError: _rawError),

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

  void _invalidateResult() {
    if (_phase == _TestPhase.idle && _result == null && _rawError == null) return;
    setState(() {
      _phase = _TestPhase.idle;
      _result = null;
      _rawError = null;
    });
  }

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

  /// 测试连接并拉模型表。
  ///
  /// **分两个阶段上报进度**：连上之后还要读模型列表，这一步也可能慢。
  /// 只显示一个笼统的"测试中"会让用户以为卡死了。
  Future<void> _testConnection() async {
    final base = _baseUrl.text.trim();
    final key = _apiKey.text.trim();
    if (base.isEmpty || key.isEmpty) {
      setState(() {
        _phase = _TestPhase.done;
        _result = const ConnectionCheck(ok: false, errorMessage: '先填 Base URL 和 API Key');
      });
      return;
    }

    setState(() {
      _phase = _TestPhase.connecting;
      _result = null;
      _rawError = null;
    });

    // 先把当前输入落库 —— 新建时尤其重要，否则模型表没地方写
    final repos = await ref.read(reposProvider.future);
    if (!mounted) return;

    if (_isNew) {
      final created = await repos.providers.create(
        name: _name.text.trim().isEmpty ? '未命名服务商' : _name.text.trim(),
        protocol: _protocol,
        baseUrl: base,
        apiKey: key,
      );
      if (!mounted) return;
      // 从"新建"切到"编辑" —— 否则下面没有 providerId，模型表写不进去
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => ProviderEditPage(providerId: created.id),
      ));
      return;
    }

    final providerId = widget.providerId!;
    final p = await repos.providers.get(providerId);
    if (p != null) {
      p
        ..baseUrl = base
        ..apiKey = key
        ..protocol = _protocol;
      await repos.providers.upsert(p);
    }
    if (!mounted) return;

    setState(() => _phase = _TestPhase.listing);

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
        _phase = _TestPhase.done;
        _result = result;
        // 保留原文：友好文案只说"网络连不上"，排障时看不到真正原因
        _rawError = result.ok ? null : result.errorMessage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _TestPhase.done;
        _result = ConnectionCheck(ok: false, errorMessage: '$e');
        _rawError = '$e';
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

// ─────────────────────────── 组件 ───────────────────────────

/// 明文 HTTP 警示。
class _CleartextWarning extends StatelessWidget {
  const _CleartextWarning();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        t.spacing.page.toDouble(), 10, t.spacing.page.toDouble(), 0,
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.danger.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.lock_open_outlined, size: 16, color: t.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '这是明文 HTTP 连接。你的 API Key 会以明文发出去，'
                '同一个网络下的人可能看到。\n'
                '能用 HTTPS 就换成 HTTPS。',
                style: TextStyle(fontSize: 12, color: t.danger, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 测试进度 / 结果。
class _TestStatus extends StatelessWidget {
  const _TestStatus({required this.phase, required this.result, this.rawError});

  final _TestPhase phase;
  final ConnectionCheck? result;
  final String? rawError;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (phase == _TestPhase.idle) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          t.spacing.page.toDouble(), 8, t.spacing.page.toDouble(), 0,
        ),
        child: Text(
          '测试只拉模型列表，不消耗 token。',
          style: TextStyle(fontSize: 11.5, color: t.textMuted),
        ),
      );
    }

    // 进行中
    if (phase == _TestPhase.connecting || phase == _TestPhase.listing) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          t.spacing.page.toDouble(), 12, t.spacing.page.toDouble(), 0,
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
            border: Border.all(color: t.divider),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: t.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      phase == _TestPhase.connecting ? '正在连接…' : '正在读取模型列表…',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      phase == _TestPhase.connecting
                          ? '连不上时通常要等十几秒才会超时'
                          : '已经连上了，这一步通常很快',
                      style: TextStyle(fontSize: 11.5, color: t.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 完成
    final check = result;
    if (check == null) return const SizedBox.shrink();
    final ok = check.ok;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        t.spacing.page.toDouble(), 12, t.spacing.page.toDouble(), 0,
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: ok ? t.success.withValues(alpha: 0.07) : t.danger.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
          border: Border.all(
            color: (ok ? t.success : t.danger).withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 18,
                  color: ok ? t.success : t.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ok
                        ? '连接成功 · ${check.modelCount} 个模型 · ${check.latency.inMilliseconds}ms'
                        : userFacingConnectionError(check.errorMessage),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: ok ? t.success : t.danger,
                    ),
                  ),
                ),
              ],
            ),

            // 失败时把原始错误也显示出来。
            // **不做"友好化"就丢掉原文** —— 那会让排障变成猜谜：
            // "网络连不上"可能是 DNS、可能是证书、可能是 Key 错、也可能是
            // 根本没网。原始报文里写着是哪个。
            if (!ok && rawError != null && rawError!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _trim(rawError!),
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: t.textMuted,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _hintFor(rawError!),
                style: TextStyle(fontSize: 11.5, color: t.danger, height: 1.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _trim(String s) => s.length > 400 ? '${s.substring(0, 400)}…' : s;

  /// 针对常见错误给一句**能照着做**的建议。
  ///
  /// 原始错误告诉用户"是什么"，这里告诉用户"该怎么办"。
  static String _hintFor(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('cleartext')) {
      return '系统拦截了明文 HTTP。换 HTTPS，或确认应用已允许明文流量。';
    }
    if (s.contains('failed host lookup') || s.contains('no address associated')) {
      return '域名解析不了。检查 Base URL 拼写，或者当前网络有 DNS 限制。';
    }
    if (s.contains('connection refused')) {
      return '服务器拒绝了连接。检查端口号和路径（很多服务要带 /v1）。';
    }
    if (s.contains('certificate') || s.contains('handshake')) {
      return 'HTTPS 证书有问题。自签名证书需要装到设备信任链里。';
    }
    if (s.contains('401') || s.contains('unauthorized') || s.contains('鉴权')) {
      return 'API Key 不对，或者没有这个模型的权限。';
    }
    if (s.contains('404')) {
      return '路径不对。多数服务商的 Base URL 需要以 /v1 结尾。';
    }
    if (s.contains('timeout') || s.contains('超时')) {
      return '超时了。服务器可能不通，或者被防火墙挡住。';
    }
    return '把这行信息复制下来可以帮你定位问题。';
  }
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
