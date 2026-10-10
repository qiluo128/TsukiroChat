/// 插件声明的配置项。
///
/// ## 为什么要有它
///
/// 插件有开关（要不要飘花瓣、用哪种风格），但**用户没有任何地方能改** ——
/// 除非那个插件自己写一个配置窗口。而每个插件各写一套的话：
///
///   - 用户要学 N 套界面
///   - 深浅色 / 无障碍各写各的，长不齐
///   - 插件作者要为了一个开关写一整个页面
///
/// 所以做成**声明式**：插件描述「我有一个开关叫樱花飘落」，宿主负责画。
/// 和 [UiDeclaration] 是同一个思路，只是这次画的是设置项。
///
/// **没声明就不显示** —— 版本检查、纯主题这类插件不该被塞一个空设置页，
/// 用户看到空的会以为坏了。
library;

/// 一个配置项。
class ConfigField {
  const ConfigField({
    required this.key,
    required this.type,
    required this.label,
    this.description,
    this.defaultValue,
    this.min,
    this.max,
    this.options = const <ConfigOption>[],
  });

  /// 存储键。宿主存成 `plugin.config.<pluginId>.<key>`。
  final String key;

  /// `toggle` | `text` | `number` | `select`
  ///
  /// **字符串而不是枚举**：将来加一种控件类型时，旧宿主应该"画不出来但不崩"，
  /// 而不是解析失败。宿主遇到不认识的类型会画一行"暂不支持"。
  final String type;

  final String label;

  /// 一句话说明**改了会怎样**。用户真正看的是这句，不是 label。
  final String? description;

  final Object? defaultValue;

  final num? min;
  final num? max;

  /// [type] 为 `select` 时的选项。
  final List<ConfigOption> options;

  static ConfigField? parse(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key']?.toString().trim() ?? '';
    final type = raw['type']?.toString().trim() ?? '';
    if (key.isEmpty || type.isEmpty) return null;
    // 键会变成 settings 表里的一段，太长不合适
    if (key.length > 128) return null;

    final options = <ConfigOption>[];
    final rawOptions = raw['options'];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        final parsed = ConfigOption.parse(o);
        if (parsed != null) options.add(parsed);
      }
    }

    final label = raw['label']?.toString().trim() ?? '';
    return ConfigField(
      key: key,
      type: type,
      // label 缺省用 key —— 空白标题比一个丑键名更让人困惑
      label: label.isEmpty ? key : label,
      description: raw['description']?.toString(),
      defaultValue: raw['default'],
      min: raw['min'] as num?,
      max: raw['max'] as num?,
      options: options,
    );
  }

  /// 这个类型宿主画得出来吗。
  ///
  /// 画不出来的会渲染成一行说明，**不静默跳过** ——
  /// 用户会以为插件少给了选项。
  bool get isSupported =>
      type == 'toggle' || type == 'text' || type == 'number' || type == 'select';

  @override
  String toString() => 'ConfigField($key, $type)';
}

/// `select` 的一个选项。
class ConfigOption {
  const ConfigOption({required this.value, required this.label});

  final String value;
  final String label;

  static ConfigOption? parse(Object? raw) {
    if (raw is! Map) return null;
    final value = raw['value']?.toString();
    if (value == null) return null;
    return ConfigOption(value: value, label: raw['label']?.toString() ?? value);
  }
}
