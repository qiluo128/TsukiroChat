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
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        // **stretch**：让标题、滑块、下拉、输入框**同宽**。
        // 用 start 的话它们各自按内容宽度收缩，左边虽齐、右边参差，
        // 一眼看上去就是没对齐。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ── 标题行 ──
          //
          // **center 对齐**，不是 start。
          //
          // 上一版用 start + 给数字硬加 `top: 2` 凑基线，结果是
          // 标签、开关、数字三者各偏几个像素 —— 因为它们的自然高度
          // 本来就不同（文字 ~19px、Switch 32px、数字 ~19px），
          // 靠 start 对齐顶部只会让视觉重心错开。
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Text(
                  field.label,
                  style: TextStyle(
                    fontSize: t.font.body.toDouble(),
                    fontWeight: FontWeight.w500,
                    color: t.text,
                    height: 1.25,
                  ),
                ),
              ),
              // Switch **不塞进固定高度的盒子**。
              //
              // M3 的 Switch 是 32 高、触摸目标是 48 —— 塞进
              // SizedBox(height: 28) 会把它压变形并裁掉触摸区。
              if (field.type == 'toggle')
                Switch(
                  value: value == true,
                  onChanged: (v) => write(v),
                ),
              if (field.type == 'number')
                Text(
                  '${((value as num?) ?? (field.defaultValue as num?) ?? 0).round()}',
                  style: TextStyle(
                    fontSize: t.font.body.toDouble(),
                    color: t.primary,
                    fontWeight: FontWeight.w600,
                    // 等宽数字：拖动时数字不会左右跳
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),

          if ((field.description ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              field.description!,
              style: TextStyle(
                fontSize: t.font.caption.toDouble(),
                color: t.textMuted,
                height: 1.35,
              ),
            ),
          ],

          // ── 控件区（整行宽） ──
          //
          // 给 Slider 一个小的水平 padding：默认内边距太大，
          // 滑轨起点会明显缩在标签右边；设成 0 又会让滑块在两端被裁掉一半。
          // 6 是个折中 —— 视觉上起点基本与标签齐平，两端也不裁。
          if (field.type == 'number')
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Slider(
                value: ((value as num?) ?? (field.defaultValue as num?) ?? 0)
                    .toDouble()
                    .clamp((field.min ?? 0).toDouble(), (field.max ?? 100).toDouble()),
                min: (field.min ?? 0).toDouble(),
                max: (field.max ?? 100).toDouble(),
                divisions: ((field.max ?? 100) - (field.min ?? 0)).clamp(1, 20).round(),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                onChanged: (v) => write(v.round()),
              ),
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
