/// 插件设置页。
///
/// ## 为什么是独立页面而不是卡片里的一块
///
/// 一开始是嵌在插件卡片里的。两个问题：
///
///   1. **对齐**：卡片里的可用宽度已经很窄，而不同控件
///      （SwitchListTile / Slider / DropdownButton）各自有自己的内边距，
///      并排放在一起时标题和控件永远差几个像素 —— 看着就是没对齐。
///   2. **内容一多就没法用**：插件可能声明七八个配置项，
///      卡片会被撑得很长，而且和"启用/停用/日志"挤在一起。
///
/// 独立页面之后，宽度、滚动、分组都有了，加减配置项也不会影响卡片布局。
///
/// **没声明配置的插件不显示入口** —— 一个空的设置页比没有更让人困惑。
library;

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

import '../../plugin/plugin_host.dart';
import '../../theme/app_theme.dart';

/// 打开某个插件的设置页。
Future<void> openPluginConfig(
  BuildContext context, {
  required InstalledPlugin plugin,
  required PluginHost host,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PluginConfigPage(plugin: plugin, host: host),
    ),
  );
}

class PluginConfigPage extends StatefulWidget {
  const PluginConfigPage({super.key, required this.plugin, required this.host});

  final InstalledPlugin plugin;
  final PluginHost host;

  @override
  State<PluginConfigPage> createState() => _PluginConfigPageState();
}

class _PluginConfigPageState extends State<PluginConfigPage> {
  @override
  void initState() {
    super.initState();
    // 宿主变更（比如另一个入口改了配置）时重画
    widget.host.addListener(_onHostChanged);
  }

  @override
  void dispose() {
    widget.host.removeListener(_onHostChanged);
    super.dispose();
  }

  void _onHostChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fields = widget.plugin.manifest.provides.config;

    return Scaffold(
      appBar: AppBar(title: Text('${widget.plugin.name} 的设置')),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: t.spacing.page.toDouble(),
          vertical: t.spacing.section.toDouble() / 2,
        ),
        children: <Widget>[
          if (fields.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('这个插件没有可配置的项目')),
            )
          else
            for (final field in fields)
              _ConfigFieldTile(plugin: widget.plugin, host: widget.host, field: field),
        ],
      ),
    );
  }
}

/// 一个配置项。
///
/// **所有类型共用同一套几何**（同样的横向内边距、同样的
/// "标题在上、控件在下"结构），这样并排看过去是齐的。
/// 之前用 SwitchListTile + 自己拼的 Slider 行，两者的内边距不同，
/// 于是永远差几个像素。
class _ConfigFieldTile extends StatelessWidget {
  const _ConfigFieldTile({
    required this.plugin,
    required this.host,
    required this.field,
  });

  final InstalledPlugin plugin;
  final PluginHost host;
  final ConfigField field;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final value = host.configValue(plugin.id, field.key) ?? field.defaultValue;

    Future<void> write(Object? next) => host.setConfig(plugin.id, field.key, next);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // ── 标题行 ──
          // 用同一行放"标签 + 内联控件"（开关这种小的），
          // 大的控件（滑块、下拉、输入框）放到下面一行，
          // 但**左边起始位置完全一样**。
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  field.label,
                  style: TextStyle(
                    fontSize: t.font.body.toDouble(),
                    fontWeight: FontWeight.w500,
                    color: t.text,
                  ),
                ),
              ),
              if (field.type == 'toggle')
                SizedBox(
                  height: 28,
                  child: Switch(
                    value: value == true,
                    onChanged: (v) => write(v),
                  ),
                ),
              if (field.type == 'number')
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${((value as num?) ?? (field.defaultValue as num?) ?? 0).round()}',
                    style: TextStyle(
                      fontSize: t.font.body.toDouble(),
                      color: t.primary,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),

          if ((field.description ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              field.description!,
              style: TextStyle(fontSize: t.font.caption.toDouble(), color: t.textMuted),
            ),
          ],

          // ── 控件区（需要整行的类型） ──
          if (field.type == 'number')
            Slider(
              value: ((value as num?) ?? (field.defaultValue as num?) ?? 0)
                  .toDouble()
                  .clamp((field.min ?? 0).toDouble(), (field.max ?? 100).toDouble()),
              min: (field.min ?? 0).toDouble(),
              max: (field.max ?? 100).toDouble(),
              divisions: ((field.max ?? 100) - (field.min ?? 0)).clamp(1, 20).round(),
              onChanged: (v) => write(v.round()),
            ),

          if (field.type == 'select')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DropdownButtonFormField<String>(
                initialValue: field.options.any((o) => o.value == value?.toString())
                    ? value.toString()
                    : field.options.first.value,
                decoration: const InputDecoration(isDense: true),
                items: <DropdownMenuItem<String>>[
                  for (final o in field.options)
                    DropdownMenuItem<String>(value: o.value, child: Text(o.label)),
                ],
                onChanged: (v) => write(v),
              ),
            ),

          if (field.type == 'text')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextFormField(
                initialValue: value?.toString() ?? '',
                decoration: const InputDecoration(isDense: true),
                onFieldSubmitted: write,
              ),
            ),

          // **不认识的类型明说，不静默跳过。**
          // 跳过的话用户会以为插件少给了选项；明说至少知道该升级宿主。
          if (field.type != 'toggle' &&
              field.type != 'number' &&
              field.type != 'select' &&
              field.type != 'text')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: <Widget>[
                  Icon(Icons.help_outline, size: 14, color: t.textMuted),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '这个版本的宿主还不支持「${field.type}」类型的设置项',
                      style: TextStyle(fontSize: t.font.caption.toDouble(), color: t.textMuted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
