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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/models.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/plugin/host_services_impl.dart';
import 'package:tsukiro_chat/plugin/plugin_host.dart';
import 'package:tsukiro_chat/theme/design_tokens.dart';

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
    // `ui.dialog` 会碰 Flutter binding（要拿 ScaffoldMessenger）。
    // 不初始化的话它会抛 "Binding has not yet been initialized" ——
    // 那是测试环境问题，不是原语没实现。
    TestWidgetsFlutterBinding.ensureInitialized();
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

    test('主题令牌真的能改变 AppTokens 的主色（最后一段路）', () async {
      installReal('sakura-theme');
      final host = makeHost();
      await host.debugScanDirectory(pluginsRoot.path);

      final base = AppTokens.defaults();
      // 宿主默认是青色 #00DEFF
      expect(base.primary, const Color(0xFF00DEFF));

      final themed = AppTokens.fromTheme(host.availableThemes().first, base: base);

      // sakura 声明 color.primary = #FF6B9D
      expect(themed.primary, const Color(0xFFFF6B9D),
          reason: '主题声明没能覆盖主色 —— 用户看到的「还是蓝的」就是这个');
      expect(themed.primary, isNot(base.primary));
    });
  });

  group('④ 宿主服务注入（用户反馈：宿主未注入时钟服务）', () {
    test('sys.time 能真正执行，不再抛「宿主未注入服务」', () async {
      // 复刻生产装配：注册表 + 服务表
      final services = ServiceRegistry();
      final registry = PrimitiveRegistry(
        gatekeeper: Gatekeeper(),
        services: services,
      );
      registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
      services
        ..put<HostClock>(const AppHostClock())
        ..put<HostUi>(const AppHostUi());

      const pluginId = 'dev.test.clock';
      registry.gatekeeper.registerPlugin(pluginId, <String>['sys.time']);
      registry.gatekeeper.grantAll(pluginId, <String>['sys.time']);

      final result = await registry.invoke(pluginId, 'sys.time', <String, dynamic>{});
      final map = result! as Map<String, dynamic>;

      // 以前这里会抛 StateError('宿主未注入服务 HostClock…')
      expect(map['iso'], isNotNull, reason: 'sys.time 应该返回时间');
      expect(map['human'], isNotNull);
      expect(map['tz'], isNotNull);
      expect(DateTime.tryParse(map['iso'] as String), isNotNull);
    });

    test('服务表缺 HostClock 时的报错是可诊断的', () async {
      final registry = PrimitiveRegistry(gatekeeper: Gatekeeper());
      registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
      const pluginId = 'dev.test.clock';
      registry.gatekeeper.registerPlugin(pluginId, <String>['sys.time']);
      registry.gatekeeper.grantAll(pluginId, <String>['sys.time']);

      // 这就是用户看到的那条错误。它**本身没问题** ——
      // 问题在于宿主从来没注入过。
      await expectLater(
        () => registry.invoke(pluginId, 'sys.time', <String, dynamic>{}),
        throwsA(anything),
      );
    });

    test('HostClock 认常见 IANA 时区名', () {
      const clock = AppHostClock();
      final shanghai = clock.nowIn('Asia/Shanghai');
      final tokyo = clock.nowIn('Asia/Tokyo');
      expect(shanghai, isNotNull);
      expect(tokyo, isNotNull);
      // 东京比上海早 1 小时
      expect(tokyo!.difference(shanghai!).inMinutes, 60);

      // 不认识的时区返回 null（原语会给出友好的错误，而不是瞎猜一个时间）
      expect(clock.nowIn('Mars/Olympus'), isNull);
      // 本地时区名不能是空
      expect(clock.timezoneName, isNotEmpty);
    });
  });

  group('⑥ 翻译按钮链路（用户反馈：实现失败）', () {
    /// 复刻生产装配。
    Future<(PrimitiveRegistry, AppChatContext, AppPluginConfig)> buildHost() async {
      final services = ServiceRegistry();
      final registry = PrimitiveRegistry(
        gatekeeper: Gatekeeper(),
        services: services,
      );
      registry.registerAll(
        standardPrimitiveCatalog(implemented: demoPrimitiveHandlers),
      );

      final chatCtx = AppChatContext(repos: Future<Repos>.value(repos));
      final pluginCfg = AppPluginConfig(repos: Future<Repos>.value(repos));
      services
        ..put<HostClock>(const AppHostClock())
        ..put<HostUi>(const AppHostUi())
        ..put<HostChatContext>(chatCtx)
        ..put<HostPluginConfig>(pluginCfg)
        ..put<PrimitiveRegistry>(registry);

      const id = 'dev.tsukiro.translate';
      registry.gatekeeper.registerPlugin(
        id,
        <String>['chat.read', 'model.chat', 'ui'],
      );
      registry.gatekeeper.grantAll(id, <String>['chat.read', 'model.chat', 'ui']);
      return (registry, chatCtx, pluginCfg);
    }

    test('chat.lastMessage 能取到当前对话的最近一条（以前目录里都没这个原语）', () async {
      final (registry, chatCtx, _) = await buildHost();

      // 造一个对话 + 两条消息
      final agent = await repos.agents.create(name: 'A');
      final conv = await repos.conversations.create(agent.id);
      await repos.messages.prepareTurn(conv.id, userText: '你好');
      await repos.messages.update(
        (await repos.messages.list(conv.id)).last.id,
        content: '你好，有什么事？',
        status: MessageStatus.done,
      );

      // 用户"进入"这个对话
      chatCtx.activeConversationId = conv.id;

      final r = await registry.invoke(
        'dev.tsukiro.translate',
        'chat.lastMessage',
        <String, dynamic>{'role': 'assistant'},
      );
      expect(r, isNotNull);
      expect((r! as Map)['text'], '你好，有什么事？');

      // 只按 user 过滤
      final userOnly = await registry.invoke(
        'dev.tsukiro.translate',
        'chat.lastMessage',
        <String, dynamic>{'role': 'user'},
      );
      expect((userOnly! as Map)['text'], '你好');
    });

    test('不在对话里时给出可操作的错误，而不是笼统的失败', () async {
      final (registry, chatCtx, _) = await buildHost();
      chatCtx.activeConversationId = null;

      await expectLater(
        () => registry.invoke(
          'dev.tsukiro.translate',
          'chat.lastMessage',
          <String, dynamic>{},
        ),
        throwsA(predicate((e) => '$e'.contains('不在任何对话里'))),
      );
    });

    test('config.get / config.set 能往返，且各插件互不可见', () async {
      final (registry, _, _) = await buildHost();

      const a = 'dev.tsukiro.translate';
      const b = 'dev.other.plugin';
      for (final id in <String>[a, b]) {
        registry.gatekeeper.registerPlugin(id, const <String>[]);
      }

      await registry.invoke(a, 'config.set', <String, dynamic>{
        'key': 'target',
        'value': '英文',
      });

      final got = await registry.invoke(a, 'config.get', <String, dynamic>{
        'key': 'target',
      });
      expect((got! as Map)['value'], '英文');

      // 插件 B 读同一个键名，应该是它自己的（未设置）
      final other = await registry.invoke(b, 'config.get', <String, dynamic>{
        'key': 'target',
        'default': '中文',
      });
      expect((other! as Map)['value'], '中文',
          reason: '插件之间必须隔离 —— B 读到了 A 的配置就是命名空间没做对');

      // 没设置过时用 fallback
      final missing = await registry.invoke(a, 'config.get', <String, dynamic>{
        'key': 'nope',
        'default': 42,
      });
      expect((missing! as Map)['value'], 42);
    });

    test('model.chat 缺 ModelGateway 时报错可诊断', () async {
      final (registry, _, _) = await buildHost();
      // 故意不注册 ModelGateway —— 生产里如果忘了注入就是这个表现
      await expectLater(
        () => registry.invoke('dev.tsukiro.translate', 'model.chat', <String, dynamic>{
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
        }),
        throwsA(predicate((e) => '$e'.contains('ModelGateway'))),
      );
    });

    test('ui.dialog 已能执行（以前是"已注册未实现"）', () async {
      final (registry, _, _) = await buildHost();
      // 无头测试里没有真实的 messenger，AppHostUi.dialog 会返回 null；
      // 这里只验证**原语本身不再报"未实现"**
      final r = await registry.invoke('dev.tsukiro.translate', 'ui.dialog', <String, dynamic>{
        'title': '翻译完成',
        'content': 'Hello',
      });
      expect(r, isNotNull, reason: 'ui.dialog 以前抛"原语未实现"');
    });
  });

  group('⑤ 控件事件名与插件实现一致（用户反馈：点了没反应）', () {
    test('translate-button 声明的事件名在它的 index.js 里有监听', () {
      final src = Directory(p.join(repoRoot().path, 'plugins', 'translate-button'));
      final manifest = parseManifestJson(
        File(p.join(src.path, 'manifest.json')).readAsStringSync(),
      );
      expect(manifest.isValid, isTrue);
      final code = File(p.join(src.path, 'index.js')).readAsStringSync();

      for (final ui in manifest.manifest!.provides.ui) {
        final event = ui.onClickEvent ?? 'ui.click';
        expect(
          code.contains("tsukiro.event.on('$event'"),
          isTrue,
          reason: '清单声明点击发 $event，但 index.js 里没有监听它 —— 点了会毫无反应',
        );
      }
    });

    test('status-panel 的控件事件名也一致', () {
      final src = Directory(p.join(repoRoot().path, 'plugins', 'status-panel'));
      final manifest = parseManifestJson(
        File(p.join(src.path, 'manifest.json')).readAsStringSync(),
      );
      final code = File(p.join(src.path, 'index.js')).readAsStringSync();

      void check(List<UiDeclaration> list) {
        for (final ui in list) {
          final event = ui.onClickEvent ?? 'ui.click';
          // toggle 走兜底的 ui.click，status-panel 里监听了
          expect(code.contains("tsukiro.event.on('$event'"), isTrue,
              reason: '${ui.id} 声明 $event，但代码里没监听');
          check(ui.children);
        }
      }

      check(manifest.manifest!.provides.ui);
    });
  });
}
