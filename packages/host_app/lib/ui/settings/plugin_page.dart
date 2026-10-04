/// 插件管理。
///
/// 用户在这里看到：装了什么、在不在跑、给了什么权限、能干什么、
/// 以及**出问题时看哪里**（日志）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../plugin/plugin_host.dart';
import '../../plugin/plugin_runtime.dart';
import '../../providers/plugin_providers.dart';
import '../../theme/app_theme.dart';

class PluginPage extends ConsumerWidget {
  const PluginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final hostAsync = ref.watch(pluginHostProvider);
    final host = ref.watch(pluginHostValueProvider);
    // 启停会改变状态，watch 一下让界面重建
    ref.watch(pluginHostRevisionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('插件')),
      body: hostAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (_) {
          final plugins = host?.plugins ?? const <InstalledPlugin>[];
          return ListView(
            padding: EdgeInsets.symmetric(vertical: t.spacing.page.toDouble() / 2),
            children: <Widget>[
              _Summary(host: host),
              const SizedBox(height: 8),

              if (plugins.isEmpty)
                const _Empty()
              else
                for (final plugin in plugins)
                  _PluginCard(
                    plugin: plugin,
                    host: host,
                    onChanged: () => ref.invalidate(pluginHostProvider),
                  ),

              const SizedBox(height: 16),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
                child: OutlinedButton.icon(
                  onPressed: () => _reinstallDemos(context, ref, host),
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('重装演示插件'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  t.spacing.page.toDouble(), 8, t.spacing.page.toDouble(), 0,
                ),
                child: Text(
                  '从内置资源重新安装时间、翻译、樱花主题三个演示插件。'
                  '已经装着的会被覆盖。',
                  style: TextStyle(fontSize: 11.5, color: t.textMuted, height: 1.5),
                ),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Future<void> _reinstallDemos(BuildContext context, WidgetRef ref, PluginHost? host) async {
    if (host == null) return;
    var ok = 0;
    final failed = <String>[];
    for (final assetDir in demoTemplatePlugins) {
      try {
        await host.installFromAssets(assetDir);
        ok++;
      } catch (e) {
        failed.add('$assetDir：$e');
      }
    }
    ref.invalidate(pluginHostProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(failed.isEmpty ? '装了 $ok 个插件' : '装了 $ok 个，${failed.length} 个失败'),
      duration: const Duration(seconds: 3),
    ));
  }
}

// ─────────────────────────── 组件 ───────────────────────────

class _Summary extends StatelessWidget {
  const _Summary({required this.host});

  final PluginHost? host;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final plugins = host?.plugins ?? const <InstalledPlugin>[];
    final tools = host?.toolRegistry.length ?? 0;
    final uiCount = host?.slotRegistry.uiCount ?? 0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.spacing.page.toDouble()),
      child: Row(
        children: <Widget>[
          _Stat(value: '${plugins.length}', label: '已安装'),
          _Stat(value: '${host?.runningCount ?? 0}', label: '运行中', accent: true),
          _Stat(value: '$tools', label: '工具'),
          _Stat(value: '$uiCount', label: '界面控件'),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.accent = false});

  final String value;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: accent ? t.primary : t.text,
            ),
          ),
          Text(label, style: TextStyle(fontSize: 11.5, color: t.textMuted)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.all(t.spacing.page.toDouble() * 2),
      child: Column(
        children: <Widget>[
          Icon(Icons.extension_off_outlined, size: 44, color: t.textMuted),
          const SizedBox(height: 12),
          Text('还没有安装插件', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            '点下面的按钮装几个演示插件试试',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PluginCard extends StatefulWidget {
  const _PluginCard({
    required this.plugin,
    required this.host,
    required this.onChanged,
  });

  final InstalledPlugin plugin;
  final PluginHost? host;
  final VoidCallback onChanged;

  @override
  State<_PluginCard> createState() => _PluginCardState();
}

class _PluginCardState extends State<_PluginCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final plugin = widget.plugin;

    return Card(
      margin: EdgeInsets.symmetric(
        horizontal: t.spacing.page.toDouble(),
        vertical: 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              plugin.name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _StateBadge(plugin: plugin),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'v${plugin.version} · ${plugin.id}',
                        style: TextStyle(fontSize: 11.5, color: t.textMuted),
                      ),
                      if (plugin.runtime?.failureReason != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          plugin.runtime!.failureReason!,
                          style: TextStyle(fontSize: 11.5, color: t.danger),
                        ),
                      ],
                    ],
                  ),
                ),
                Switch(
                  value: plugin.enabled,
                  onChanged: (v) async {
                    await widget.host?.setEnabled(plugin.id, v);
                    widget.onChanged();
                  },
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                if (plugin.tools.isNotEmpty)
                  _Tag(
                    icon: Icons.build_outlined,
                    text: '${plugin.tools.length} 个工具',
                  ),
                for (final tool in plugin.tools) _Tag(text: tool.name),
                if (plugin.manifest.isZeroCode) const _Tag(text: '零代码'),
              ],
            ),
          ),

          // 权限：让用户知道这个插件能碰什么
          if (plugin.manifest.permissions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '申请的权限',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: t.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final p in plugin.manifest.permissions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(Icons.check_circle_outline,
                              size: 12, color: t.success),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              '${p.name}${p.reason == null ? '' : " — ${p.reason}"}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: t.textMuted,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                ),
                label: Text(_expanded ? '收起' : '日志'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _confirmUninstall(context),
                icon: Icon(Icons.delete_outline, size: 16, color: t.danger),
                label: Text('卸载', style: TextStyle(color: t.danger)),
              ),
              const SizedBox(width: 4),
            ],
          ),

          if (_expanded)
            _LogPanel(plugin: plugin),
        ],
      ),
    );
  }

  Future<void> _confirmUninstall(BuildContext context) async {
    final t = context.tokens;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text('「${widget.plugin.name}」会被删除，它的工具和界面也会一并消失。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: t.danger),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.host?.uninstall(widget.plugin.id);
    widget.onChanged();
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.plugin});

  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final (String text, Color color) = switch (plugin.state) {
      RuntimeState.ready => ('运行中', t.success),
      RuntimeState.loading => ('启动中', t.primary),
      RuntimeState.failed => ('失败', t.danger),
      RuntimeState.stopped => ('已停止', t.textMuted),
      RuntimeState.created => ('未启动', t.textMuted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: t.textMuted),
            const SizedBox(width: 3),
          ],
          Text(text, style: TextStyle(fontSize: 11, color: t.textMuted)),
        ],
      ),
    );
  }
}

/// 插件日志。
///
/// **这是排障唯一的窗口。** 插件跑在 WebView 里，出问题在 Flutter 侧
/// 什么都看不到 —— 握手失败、JS 抛错、原语被拒，全都要靠这里。
class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.plugin});

  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final logs = plugin.runtime?.logs ?? const <PluginLogEntry>[];

    if (logs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Text(
          plugin.isReady ? '还没有日志' : '运行时没起来，所以没有日志',
          style: TextStyle(fontSize: 11.5, color: t.textMuted),
        ),
      );
    }

    // 倒序：最新的在最上面
    final recent = logs.reversed.take(50).toList(growable: false);

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.divider),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: recent.length,
        itemBuilder: (context, i) {
          final entry = recent[i];
          final color = switch (entry.level) {
            'error' => t.danger,
            'warn' => const Color(0xFFF59E0B),
            _ => t.textMuted,
          };
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: SelectableText(
              '${_hhmmss(entry.at)} [${entry.level}] ${entry.message}',
              style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: color,
                fontFamily: 'monospace',
              ),
            ),
          );
        },
      ),
    );
  }

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
}
