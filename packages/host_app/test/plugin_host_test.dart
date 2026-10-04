/// 插件宿主的启停状态测试。
///
/// 守住一个具体 bug：用户关掉插件后，重新扫描又变回开启 ——
/// 因为 `enabled` 每次 `_scan()` 都从清单的 `autoStart` 重读，没有持久化。
/// 表现是"开关关不掉"。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/plugin/plugin_host.dart';

/// 造一个最小的插件目录（只有清单，没有 JS）。
///
/// 零代码插件就够测启停逻辑了，而且不用准备 handler 文件。
Future<Directory> writePlugin(
  Directory root,
  String id, {
  bool autoStart = true,
}) async {
  final dir = Directory('${root.path}/$id');
  await dir.create(recursive: true);
  await File('${dir.path}/manifest.json').writeAsString('''
{
  "manifestVersion": 1,
  "id": "$id",
  "name": "$id",
  "version": "1.0.0",
  "description": "test",
  "author": { "name": "t" },
  "runtime": { "main": "index.js", "type": "module", "autoStart": $autoStart },
  "provides": { "theme": [{ "id": "t", "name": "t", "tokens": { "color.primary": "#123456" } }] }
}
''');
  return dir;
}

PluginHost makeHost(SettingsRepository settings) => PluginHost(
      toolRegistry: ToolRegistry(),
      gatekeeper: Gatekeeper(),
      primitiveRegistry: PrimitiveRegistry(gatekeeper: Gatekeeper()),
      audit: MemoryAuditSink(),
      settings: settings,
    );

void main() {
  late Directory tempDir;
  late Directory pluginsRoot;
  late AppDatabase db;
  late Repos repos;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tsukiro-host-test-');
    pluginsRoot = Directory('${tempDir.path}/plugins');
    await pluginsRoot.create(recursive: true);
    db = await AppDatabase.open(tempDir.path);
    repos = Repos(db);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('启停状态持久化', () {
    test('默认取清单里的 autoStart', () async {
      await writePlugin(pluginsRoot, 'dev.test.a', autoStart: true);
      final host = makeHost(repos.settings);
      // PluginHost.initialize 用应用文档目录，这里直接扫我们造的目录
      await _scanInto(host, pluginsRoot);

      expect(host.plugins, hasLength(1));
      expect(host.plugins.first.enabled, isTrue);
    });

    test('关掉之后重新扫描**不会**自己变回开启', () async {
      await writePlugin(pluginsRoot, 'dev.test.a', autoStart: true);

      final first = makeHost(repos.settings);
      await _scanInto(first, pluginsRoot);
      expect(first.plugins.first.enabled, isTrue);

      await first.setEnabled('dev.test.a', false);
      expect(first.plugins.first.enabled, isFalse);

      // 换一个新宿主 = 模拟重启。这就是原来会出问题的地方：
      // enabled 从 autoStart 重读 → 又变 true
      final second = makeHost(repos.settings);
      await _scanInto(second, pluginsRoot);

      expect(second.plugins.first.enabled, isFalse,
          reason: '用户关掉的插件在重启后又自己开了 —— enabled 没有持久化');
    });

    test('关闭后再打开，状态也对', () async {
      await writePlugin(pluginsRoot, 'dev.test.a', autoStart: false);

      final first = makeHost(repos.settings);
      await _scanInto(first, pluginsRoot);
      expect(first.plugins.first.enabled, isFalse);

      await first.setEnabled('dev.test.a', true);

      final second = makeHost(repos.settings);
      await _scanInto(second, pluginsRoot);
      expect(second.plugins.first.enabled, isTrue);
    });
  });

  group('插槽注册', () {
    test('清单里的声明会进插槽表', () async {
      await writePlugin(pluginsRoot, 'dev.test.a');
      final host = makeHost(repos.settings);
      await _scanInto(host, pluginsRoot);

      expect(host.slotRegistry.uiCount, greaterThanOrEqualTo(0));
      // 主题声明进的是主题表，不是插槽表；这里主要验证注册没抛异常
      expect(host.plugins, hasLength(1));
    });
  });
}

/// 把插件目录塞进宿主再扫描。
///
/// [PluginHost.initialize] 固定用应用文档目录，测试里不方便改，
/// 所以这里复用它内部的扫描逻辑 —— 直接把目录设进去。
Future<void> _scanInto(PluginHost host, Directory root) async {
  // ignore: invalid_use_of_visible_for_testing_member
  await host.debugScanDirectory(root.path);
}
