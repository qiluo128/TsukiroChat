/// 插件三条链路的端到端测试（用**真实插件**，不是造的假清单）。
///
/// 对应用户反馈的三个现象：
///   1. 主题插件启动后无效果
///   2. 其他插件启动后无控件/按钮
///   3. 问 AI 当前时间，答"无法获取"
///
/// 这三条分别对应：主题解析、插槽注册、工具注册。
/// 用真实清单测，才能发现"我以为注册了、其实没有"这类问题。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/plugin/plugin_host.dart';

Directory repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    if (Directory(p.join(dir.path, 'plugins')).existsSync()) return dir;
    dir = dir.parent;
  }
  throw StateError('找不到仓库根');
}

void copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = p.basename(e.path);
    if (e is Directory) {
      copyDir(e, Directory(p.join(to.path, name)));
    } else if (e is File) {
      e.copySync(p.join(to.path, name));
    }
  }
}

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
    tempDir = await Directory.systemTemp.createTemp('tsukiro-e2e-');
    pluginsRoot = Directory(p.join(tempDir.path, 'plugins'))..createSync(recursive: true);
    db = await AppDatabase.open(tempDir.path);
    repos = Repos(db);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  /// 把真实插件复制进临时插件目录。
  void installReal(String pluginDirName, {String? asId}) {
    final src = Directory(p.join(repoRoot().path, 'plugins', pluginDirName));
    expect(src.existsSync(), isTrue, reason: '找不到 plugins/$pluginDirName');
    copyDir(src, Directory(p.join(pluginsRoot.path, asId ?? pluginDirName)));
  }

  PluginHost makeHost() => PluginHost(
        toolRegistry: ToolRegistry(),
        gatekeeper: Gatekeeper(),
        primitiveRegistry: PrimitiveRegistry(gatekeeper: Gatekeeper()),
        audit: MemoryAuditSink(),
        settings: repos.settings,
      );

  group('② 插槽注册（用户反馈：没有控件）', () {
    test('status-panel 的 ui 声明进了插槽表', () async {
      installReal('status-panel');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      expect(host.slotRegistry.uiCount, greaterThan(0),
          reason: 'provides.ui 里的声明一条都没进插槽表');
    });

    test('visibleUi 能查到 agent.actions（无 when 条件，必显示）', () async {
      installReal('status-panel');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      final ui = host.visibleUi('agent.actions');
      expect(ui, isNotEmpty,
          reason: '「打招呼」按钮没有 when 条件、权限也声明了，应该出现在 agent.actions');
      expect(ui.first.declaration.id, 'greet');
    });

    test('visibleUi 能查到 chat.toolbar（有 when 条件时按上下文过滤）', () async {
      installReal('status-panel');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      // 没有消息 → when { hasMessages: true } 不成立 → 不显示
      expect(host.visibleUi('chat.toolbar', context: {'hasMessages': false}), isEmpty);
      // 有消息 → 显示
      expect(host.visibleUi('chat.toolbar', context: {'hasMessages': true}), isNotEmpty);
    });

    test('agent.sections 里的 section 与子控件都注册了', () async {
      installReal('status-panel');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      final ui = host.visibleUi('agent.sections');
      expect(ui, isNotEmpty);
      final section = ui.firstWhere((u) => u.declaration.type == 'section');
      expect(section.declaration.children, isNotEmpty,
          reason: 'section 的子控件应该被解析出来');
    });
  });

  group('③ 工具注册（用户反馈：AI 说无法获取时间）', () {
    test('status-panel 的 check_time 进了工具表', () async {
      installReal('status-panel');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      expect(host.toolRegistry.length, greaterThan(0),
          reason: 'provides.tools 里的工具没进工具表，模型根本看不到');

      final names = host.toolRegistry.all.map((t) => t.name).toList();
      expect(names.any((n) => n.contains('check_time')), isTrue,
          reason: '工具名应该包含 check_time，实际是 $names');
    });

    test('工具的 handler 与运行时注册的键一致', () async {
      installReal('status-panel');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      final tool = host.toolRegistry.all
          .firstWhere((t) => t.name.contains('check_time'));
      // AgentLoop 传给 invokeTool 的是 tool.handler；
      // 插件侧 __registerHandler 用的也是这个键。两边必须一致。
      expect(tool.handler, 'handlers/check_time.js');
    });

    test('模型看到的工具定义里带 parameters', () async {
      installReal('status-panel');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      final openai = host.toolRegistry.toOpenAiTools(
        gatekeeper: host.gatekeeper,
        skillAllowList: null,
      );
      expect(openai, isNotEmpty);
      final fn = openai.firstWhere((t) =>
          (t['function'] as Map)['name'].toString().contains('check_time'));
      expect((fn['function'] as Map)['parameters'], isNotNull);
    });
  });

  group('① 主题解析（用户反馈：主题插件无效果）', () {
    test('sakura-theme 的主题声明被解析出来', () async {
      installReal('sakura-theme');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      final plugin = host.plugins.single;
      expect(plugin.manifest.provides.themes, isNotEmpty,
          reason: 'sakura-theme 是零代码主题插件，必须带上主题声明');
    });

    test('宿主能从已启用插件里取到主题声明（这一步以前完全没实现）', () async {
      installReal('sakura-theme');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      // 宿主需要一个"当前有哪些可用的主题声明"的入口。
      // 如果这里拿不到，界面就永远用默认配色 —— 正是用户看到的现象。
      final themes = host.availableThemes();
      expect(themes, isNotEmpty,
          reason: '宿主没有从插件收集主题声明，appTokensProvider 只会返回默认值');
      expect(themes.first.tokens, isNotEmpty);
    });
  });
}
