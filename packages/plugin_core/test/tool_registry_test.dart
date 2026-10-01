import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

PluginManifest buildManifest({
  required String id,
  required String version,
  List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[],
  List<String> permissions = const <String>[],
}) {
  final json = <String, dynamic>{
    'manifestVersion': 1,
    'id': id,
    'name': id,
    'version': version,
    'runtime': <String, dynamic>{'main': 'index.js'},
    'permissions': permissions,
    if (tools.isNotEmpty)
      'provides': <String, dynamic>{'tools': tools},
  };
  final result = parseManifest(json);
  if (!result.isValid) {
    throw StateError('测试用 manifest 构造失败: ${result.issues.join(", ")}');
  }
  return result.manifest!;
}

Map<String, dynamic> tool(
  String name, {
  String? description,
  String handler = 'handlers/x.js',
  List<String> permissions = const <String>[],
  int timeoutMs = 10000,
  bool dangerous = false,
  bool exposed = true,
}) =>
    <String, dynamic>{
      'name': name,
      'description': description ?? '示例工具 $name',
      'handler': handler,
      'parameters': <String, dynamic>{'q': 'string'},
      'permissions': permissions,
      'timeoutMs': timeoutMs,
      'dangerous': dangerous,
      'exposed': exposed,
    };

void main() {
  late ToolRegistry registry;
  late Gatekeeper gk;

  setUp(() {
    registry = ToolRegistry();
    gk = Gatekeeper();
  });

  /// 注册插件到守门人并授予全部权限。
  void grantAll(PluginManifest m) {
    gk.registerPlugin(m.id, m.permissionNames);
    gk.grantAll(m.id, m.permissionNames);
  }

  group('注册与注销', () {
    test('注册单个工具', () {
      final m = buildManifest(id: 'dev.tsukiro.time', version: '1.0.0', tools: <Map<String, dynamic>>[tool('get_time')]);
      registry.registerPlugin(m);
      expect(registry.length, 1);
      expect(registry.lookup('get_time'), isNotNull);
      expect(registry.lookup('get_time')!.pluginId, 'dev.tsukiro.time');
    });

    test('注销插件后其工具全部消失', () {
      final m = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('t1'), tool('t2')]);
      registry.registerPlugin(m);
      expect(registry.length, 2);
      registry.unregisterPlugin('a.b');
      expect(registry.length, 0);
      expect(registry.lookup('t1'), isNull);
    });

    test('注销不会误删别人的工具', () {
      final a = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('t1')]);
      final c = buildManifest(id: 'c.d', version: '1.0.0', tools: <Map<String, dynamic>>[tool('t2')]);
      registry.registerPlugin(a);
      registry.registerPlugin(c);
      registry.unregisterPlugin('a.b');
      expect(registry.lookup('t2'), isNotNull);
      expect(registry.length, 1);
    });

    test('重复注册同一插件 = 升级，旧工具被替换', () {
      final v1 = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('old_tool')]);
      final v2 = buildManifest(id: 'a.b', version: '2.0.0', tools: <Map<String, dynamic>>[tool('new_tool')]);
      registry.registerPlugin(v1);
      registry.registerPlugin(v2);
      expect(registry.lookup('old_tool'), isNull);
      expect(registry.lookup('new_tool')!.pluginVersion, '2.0.0');
      expect(registry.length, 1);
    });

    test('toolNamesOf 返回暴露名', () {
      final m = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('t1'), tool('t2')]);
      registry.registerPlugin(m);
      expect(registry.toolNamesOf('a.b'), containsAll(<String>['t1', 't2']));
    });
  });

  group('重名冲突：加前缀，不覆盖', () {
    test('后注册者被改名，先注册者保持原名', () {
      final a = buildManifest(id: 'dev.tsukiro.time', version: '1.0.0', tools: <Map<String, dynamic>>[tool('get_time')]);
      final b = buildManifest(id: 'dev.tsukiro.clock', version: '1.0.0', tools: <Map<String, dynamic>>[tool('get_time')]);

      final conflictsA = registry.registerPlugin(a);
      expect(conflictsA, isEmpty);

      final conflictsB = registry.registerPlugin(b);
      expect(conflictsB, hasLength(1));
      expect(conflictsB.single.requested, 'get_time');
      expect(conflictsB.single.assigned, 'clock__get_time');

      // 先注册者仍是原名
      expect(registry.lookup('get_time')!.pluginId, 'dev.tsukiro.time');
      // 后注册者换了名字，且标记了冲突
      final renamed = registry.lookup('clock__get_time')!;
      expect(renamed.pluginId, 'dev.tsukiro.clock');
      expect(renamed.originalName, 'get_time');
      expect(renamed.renamedDueToConflict, isTrue);
    });

    test('三个插件同名时前缀递增', () {
      for (final id in <String>['a.one', 'a.two', 'a.three']) {
        registry.registerPlugin(
          buildManifest(id: id, version: '1.0.0', tools: <Map<String, dynamic>>[tool('same')]),
        );
      }
      expect(registry.lookup('same'), isNotNull);
      expect(registry.lookup('two__same'), isNotNull);
      expect(registry.lookup('three__same'), isNotNull);
      expect(registry.length, 3);
    });

    test('冲突记录进入 conflicts 列表（供审计）', () {
      registry.registerPlugin(buildManifest(id: 'a.one', version: '1.0.0', tools: <Map<String, dynamic>>[tool('same')]));
      registry.registerPlugin(buildManifest(id: 'a.two', version: '1.0.0', tools: <Map<String, dynamic>>[tool('same')]));
      expect(registry.conflicts, hasLength(1));
      expect(registry.conflicts.single.existingPluginId, 'a.one');
      expect(registry.conflicts.single.newPluginId, 'a.two');
    });

    test('前缀来自插件 id 最后一段，且符合 Provider 字符集', () {
      registry.registerPlugin(buildManifest(id: 'a.one', version: '1.0.0', tools: <Map<String, dynamic>>[tool('same')]));
      registry.registerPlugin(buildManifest(id: 'com.example.my-plugin', version: '1.0.0', tools: <Map<String, dynamic>>[tool('same')]));
      final assigned = registry.toolNamesOf('com.example.my-plugin').single;
      expect(assigned, 'my_plugin__same');
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(assigned), isTrue,
          reason: '部分 Provider 的 function name 只接受这个字符集');
    });
  });

  group('可见性过滤', () {
    test('权限未授予 → 工具不可见', () {
      final m = buildManifest(
        id: 'a.b',
        version: '1.0.0',
        permissions: <String>['sys.time'],
        tools: <Map<String, dynamic>>[tool('get_time', permissions: <String>['sys.time'])],
      );
      gk.registerPlugin(m.id, m.permissionNames);
      registry.registerPlugin(m);

      // 未授予
      expect(registry.visibleTools(gatekeeper: gk), isEmpty);

      // 授予后可见
      gk.grant('a.b', 'sys.time');
      expect(registry.visibleTools(gatekeeper: gk), hasLength(1));
    });

    test('撤销权限 → 工具立即不可见', () {
      final m = buildManifest(
        id: 'a.b',
        version: '1.0.0',
        permissions: <String>['sys.time'],
        tools: <Map<String, dynamic>>[tool('get_time', permissions: <String>['sys.time'])],
      );
      grantAll(m);
      registry.registerPlugin(m);
      expect(registry.visibleTools(gatekeeper: gk), hasLength(1));

      gk.revoke('a.b', 'sys.time');
      expect(registry.visibleTools(gatekeeper: gk), isEmpty);
    });

    test('无权限要求的工具始终可见', () {
      final m = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('ping')]);
      grantAll(m);
      registry.registerPlugin(m);
      expect(registry.visibleTools(gatekeeper: gk), hasLength(1));
    });

    test('多权限工具需全部授予才可见', () {
      final m = buildManifest(
        id: 'a.b',
        version: '1.0.0',
        permissions: <String>['sys.time', 'ui'],
        tools: <Map<String, dynamic>>[tool('t', permissions: <String>['sys.time', 'ui'])],
      );
      gk.registerPlugin(m.id, m.permissionNames);
      gk.grant('a.b', 'sys.time');
      registry.registerPlugin(m);
      expect(registry.visibleTools(gatekeeper: gk), isEmpty, reason: 'ui 还没授予');

      gk.grant('a.b', 'ui');
      expect(registry.visibleTools(gatekeeper: gk), hasLength(1));
    });

    test('Skill 白名单过滤', () {
      final m = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('t1'), tool('t2')]);
      grantAll(m);
      registry.registerPlugin(m);

      final visible = registry.visibleTools(
        gatekeeper: gk,
        skillAllowList: <String>{'t1'},
      );
      expect(visible.map((t) => t.name), <String>['t1']);
    });

    test('空 Skill 白名单 = 不限制', () {
      final m = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('t1'), tool('t2')]);
      grantAll(m);
      registry.registerPlugin(m);
      expect(
        registry.visibleTools(gatekeeper: gk, skillAllowList: <String>{}),
        hasLength(2),
      );
    });

    test('Skill 白名单可用原始名匹配被改名的工具', () {
      registry.registerPlugin(buildManifest(id: 'a.one', version: '1.0.0', tools: <Map<String, dynamic>>[tool('same')]));
      final b = buildManifest(id: 'a.two', version: '1.0.0', tools: <Map<String, dynamic>>[tool('same')]);
      grantAll(b);
      registry.registerPlugin(b);

      final visible = registry.visibleTools(
        gatekeeper: gk,
        skillAllowList: <String>{'same'},
      );
      // 原始名为 same 的两个工具都应命中
      expect(visible, hasLength(2));
    });

    test('用户开关关闭工具', () {
      final m = buildManifest(id: 'a.b', version: '1.0.0', tools: <Map<String, dynamic>>[tool('t1'), tool('t2')]);
      grantAll(m);
      registry.registerPlugin(m);
      final visible = registry.visibleTools(
        gatekeeper: gk,
        userToggles: <String, bool>{'t1': false},
      );
      expect(visible.map((t) => t.name), <String>['t2']);
    });

    test('排序稳定（避免 provider prompt cache 失效）', () {
      final m = buildManifest(
        id: 'a.b',
        version: '1.0.0',
        tools: <Map<String, dynamic>>[tool('zeta'), tool('alpha'), tool('mid')],
      );
      grantAll(m);
      registry.registerPlugin(m);
      final first = registry.visibleTools(gatekeeper: gk).map((t) => t.name).toList();
      final second = registry.visibleTools(gatekeeper: gk).map((t) => t.name).toList();
      expect(first, second);
      expect(first, <String>['alpha', 'mid', 'zeta']);
    });
  });

  group('OpenAI 格式导出', () {
    test('字段映射正确', () {
      final m = buildManifest(
        id: 'a.b',
        version: '1.0.0',
        tools: <Map<String, dynamic>>[
          tool('get_time', description: '获取时间', handler: 'handlers/get_time.js'),
        ],
      );
      grantAll(m);
      registry.registerPlugin(m);

      final exported = registry.toOpenAiTools(gatekeeper: gk);
      expect(exported, hasLength(1));
      expect(exported.single['type'], 'function');

      final fn = exported.single['function'] as Map<String, dynamic>;
      expect(fn['name'], 'get_time');
      expect(fn['description'], '获取时间');
      expect(fn['parameters'], isA<Map<String, dynamic>>());
    });

    test('不可见的工具不出现在导出结果里', () {
      final m = buildManifest(
        id: 'a.b',
        version: '1.0.0',
        permissions: <String>['sys.time'],
        tools: <Map<String, dynamic>>[tool('needs_perm', permissions: <String>['sys.time'])],
      );
      gk.registerPlugin(m.id, m.permissionNames);
      registry.registerPlugin(m);
      expect(registry.toOpenAiTools(gatekeeper: gk), isEmpty);
    });
  });

  group('真实插件 manifest 注册', () {
    test('time-plugin 的工具能被注册并导出', () {
      final m = parseManifestJson(
        r'''
{
  "manifestVersion": 1,
  "id": "dev.tsukiro.time",
  "name": "时间插件",
  "version": "1.0.0",
  "runtime": { "main": "index.js" },
  "permissions": ["sys.time"],
  "provides": {
    "tools": [{
      "name": "get_time",
      "description": "获取当前时间",
      "handler": "handlers/get_time.js",
      "permissions": ["sys.time"]
    }]
  }
}
''',
      ).manifest!;

      grantAll(m);
      final conflicts = registry.registerPlugin(m);
      expect(conflicts, isEmpty);

      final tools = registry.toOpenAiTools(gatekeeper: gk);
      expect(tools, hasLength(1));
      expect(
        ((tools.single['function'] as Map<String, dynamic>)['name']),
        'get_time',
      );
    });
  });
}
