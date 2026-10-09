/// 插件自己的键值存储。
///
/// 落地在 settings 表上，键前缀 `plugin.state.<pluginId>.` ——
/// 插件之间天然分区，而且不用新建表。
///
/// **等 docs/20 的 per-agent 安装落地后**，前缀会变成
/// `plugin.state.<pluginId>.<agentId>.`，这个类改一行即可，
/// 插件侧一行不用改。
library;

import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';

import '../data/repositories.dart';

class AppPluginState implements HostPluginState {
  AppPluginState(this._repos);

  final Future<Repos> _repos;

  /// 单个值的大小上限。
  ///
  /// **插件存储不是文件系统。** 一个插件往里塞 10MB 的 base64
  /// 会把设置表和每次读取都拖垮。64KB 够放几千条礼物记录。
  static const int maxValueBytes = 64 * 1024;

  static String _prefixOf(String pluginId) => 'plugin.state.$pluginId.';

  static String _keyOf(String pluginId, String key) => '${_prefixOf(pluginId)}$key';

  @override
  Future<Object?> get(String pluginId, String key) async {
    final raw = await (await _repos).settings.get(_keyOf(pluginId, key));
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      // 存进去的一定是 JSON，解不开说明被外部改过。
      // 原样返回比抛错好 —— 插件至少能看见"这里有个坏值"。
      return raw;
    }
  }

  @override
  Future<void> set(String pluginId, String key, Object? value) async {
    final encoded = jsonEncode(value);
    // **按 UTF-8 字节数算，不是 String.length。**
    //
    // String.length 是 UTF-16 码元数：一个汉字算 1，但落盘是 3 字节。
    // 用 length 的话"64KB 上限"对中文实际是 192KB —— 名字和提示都在说谎。
    final bytes = utf8.encode(encoded).length;
    if (bytes > maxValueBytes) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '插件状态单个值上限 ${maxValueBytes ~/ 1024}KB，'
        '这次要写 ${bytes ~/ 1024}KB。请拆成多个键。',
      );
    }
    await (await _repos).settings.set(_keyOf(pluginId, key), encoded);
  }

  @override
  Future<bool> delete(String pluginId, String key) async =>
      (await _repos).settings.delete(_keyOf(pluginId, key));

  @override
  Future<List<String>> keys(String pluginId, {String? prefix}) async {
    final all = await (await _repos).settings.keysWithPrefix(_prefixOf(pluginId));
    final base = _prefixOf(pluginId);
    final stripped = all
        .map((k) => k.substring(base.length))
        .where((k) => prefix == null || prefix.isEmpty || k.startsWith(prefix))
        .toList(growable: false)
      ..sort();
    return stripped;
  }
}
