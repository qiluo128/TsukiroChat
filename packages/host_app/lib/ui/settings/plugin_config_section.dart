/// 插件配置界面。
///
/// ## 为什么由宿主画而不是插件自己画
///
/// 插件有开关，但用户没有地方能改 —— 除非每个插件自己写一个配置窗口。
/// 那样的话：用户要学 N 套界面、深浅色各写各的、插件作者要为了
/// 一个开关写一整个页面。
///
/// 所以插件只**声明**（`provides.config`），宿主负责画。
/// 和 `provides.ui` 是同一个思路，只是这次画的是设置项。
///
/// **没声明就不显示** —— 一个空的设置页比没有更让人困惑。
library;

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

import '../../plugin/plugin_host.dart';
import '../../theme/app_theme.dart';

class PluginConfigSection extends StatelessWidget {
  const PluginConfigSection({super.key, required this.plugin, required this.host});

  final InstalledPlugin plugin;
  final PluginHost host;

  @override
  Widget build(BuildContext context) {
    final fields = plugin.manifest.provides.config;
    // **没声明就不显示。** 不是显示一个"暂无配置"的空壳。
    if (fields.isEmpty) return const SizedBox.shrink();

    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.tune, size: 14, color: t.textMuted),
              const SizedBox(width: 6),
              Text('设置', style: TextStyle(fontSize: 12.5, color: t.textMuted)),
            ],
          ),
          const SizedBox(height: 4),
          for (final field in fields) _Field(plugin: plugin, host: host, field: field),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.plugin, required this.host, required this.field});

  final InstalledPlugin plugin;
  final PluginHost host;
  final ConfigField field;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final value = host.configValue(plugin.id, field.key) ?? field.defaultValue;

    Future<void> write(Object? next) async {
      await host.setConfig(plugin.id, field.key, next);
    }

    switch (field.type) {
      case 'toggle':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(field.label, style: const TextStyle(fontSize: 14)),
          subtitle: field.description == null
              ? null
              : Text(field.description!, style: const TextStyle(fontSize: 12)),
          value: value == true,
          onChanged: (v) => write(v),
        );

      case 'number':
        final current = (value as num?)?.toDouble() ?? (field.defaultValue as num?)?.toDouble() ?? 0;
        final min = (field.min ?? 0).toDouble();
        final max = (field.max ?? 100).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Text(field.label, style: const TextStyle(fontSize: 14))),
                  Text('${current.round()}', style: TextStyle(fontSize: 13, color: t.textMuted)),
                ],
              ),
              if (field.description != null)
                Text(field.description!, style: TextStyle(fontSize: 12, color: t.textMuted)),
              Slider(
                value: current.clamp(min, max),
                min: min,
                max: max,
                // 分几档而不是连续：花瓣数量是 14 还是 15 没区别，
                // 连续滑块只会让用户纠结
                divisions: (max - min).clamp(1, 20).round(),
                label: '${current.round()}',
                onChanged: (v) => write(v.round()),
              ),
            ],
          ),
        );

      case 'select':
        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(field.label, style: const TextStyle(fontSize: 14)),
          subtitle: field.description == null
              ? null
              : Text(field.description!, style: const TextStyle(fontSize: 12)),
          trailing: DropdownButton<String>(
            value: field.options.any((o) => o.value == value?.toString())
                ? value.toString()
                : field.options.first.value,
            underline: const SizedBox.shrink(),
            items: <DropdownMenuItem<String>>[
              for (final o in field.options)
                DropdownMenuItem<String>(value: o.value, child: Text(o.label)),
            ],
            onChanged: (v) => write(v),
          ),
        );

      case 'text':
        final controller = TextEditingController(text: value?.toString() ?? '');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: field.label,
              helperText: field.description,
            ),
            onSubmitted: write,
          ),
        );

      default:
        // **不静默跳过。** 跳过的话用户会以为插件少给了选项；
        // 明说"这个版本画不出来"至少让人知道该升级宿主。
        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(Icons.help_outline, size: 16, color: t.textMuted),
          title: Text(field.label, style: const TextStyle(fontSize: 14)),
          subtitle: Text('这个版本的宿主还不支持「${field.type}」类型的设置项',
              style: const TextStyle(fontSize: 12)),
        );
    }
  }
}
