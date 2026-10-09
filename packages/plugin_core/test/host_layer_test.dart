/// 宿主层测试 —— 插槽表 / 安装器 / Bridge 会话 / 内存服务。
///
/// 对应 `docs/15-status.md` §4 的任务 6–9。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

import 'support/fake_services.dart';
import 'support/zip_builder.dart';

// ─────────────────────────── 通用装配 ───────────────────────────

class Rig {
  Rig({
    required this.gatekeeper,
    required this.registry,
    required this.tools,
    required this.slots,
    required this.installer,
    required this.store,
    required this.audit,
    required this.services,
  });

  final Gatekeeper gatekeeper;
  final PrimitiveRegistry registry;
  final ToolRegistry tools;
  final SlotRegistry slots;
  final Installer installer;
  final InMemoryPluginStore store;
  final MemoryAuditSink audit;
  final ServiceRegistry services;
}

Rig makeRig({Map<String, PrimitiveHandler>? handlers}) {
  final audit = MemoryAuditSink();
  final gk = Gatekeeper();

  // 原语实现要通过 ServiceRegistry 取宿主能力。少注册一个，
  // 对应的原语就会在运行时被 `require<T>()` 抛出来 —— 这正是我们要的行为，
  // 但测试环境该把它配齐。
  final services = ServiceRegistry()
    ..put<HostClock>(FakeClock(fixed: DateTime(2026, 2, 14, 10, 23, 41)))
    ..put<HostUi>(RecordingUi())
    ..put<HostFiles>(InMemoryFiles())
    ..put<SandboxProvider>(MapSandbox(<String, String>{}))
    ..put<ModelGateway>(ScriptedGateway(<ModelReply>[ModelReply(text: 'ok')]));

  final registry = PrimitiveRegistry(gatekeeper: gk, audit: audit, services: services);
  registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
  services.put<PrimitiveRegistry>(registry);

  final tools = ToolRegistry();
  final slots = SlotRegistry(audit: audit);
  final store = InMemoryPluginStore();

  return Rig(
    gatekeeper: gk,
    registry: registry,
    tools: tools,
    slots: slots,
    installer: Installer(
      store: store,
      gatekeeper: gk,
      tools: tools,
      slots: slots,
      audit: audit,
    ),
    store: store,
    audit: audit,
    services: services,
  );
}

/// 造一个带工具/UI/页面的插件包。
Uint8List pluginZip({
  String id = 'dev.tsukiro.demo',
  String version = '1.0.0',
  List<String> permissions = const <String>['sys.time'],
  List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> ui = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> pages = const <Map<String, dynamic>>[],
  Map<String, String> extraFiles = const <String, String>{},
}) {
  final manifest = <String, dynamic>{
    'manifestVersion': 1,
    'id': id,
    'name': '演示插件',
    'version': version,
    'runtime': <String, dynamic>{'main': 'index.js'},
    'permissions': permissions,
    if (tools.isNotEmpty || ui.isNotEmpty || pages.isNotEmpty)
      'provides': <String, dynamic>{
        if (tools.isNotEmpty) 'tools': tools,
        if (ui.isNotEmpty) 'ui': ui,
        if (pages.isNotEmpty) 'pages': pages,
      },
  };
  return buildZip(<String, String>{
    'manifest.json': jsonEncode(manifest),
    'index.js': '// stub',
    ...extraFiles,
  });
}

void main() {
  // ═══════════════════ 任务 6 · 插槽表与页面表 ═══════════════════

  group('插槽表', () {
    test('注册后按插槽取到控件', () {
      final rig = makeRig();
      final manifest = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'ui': <dynamic>[
            <String, dynamic>{'slot': 'chat.toolbar', 'id': 't', 'type': 'button', 'label': 'T'},
          ],
        },
      }).manifest!;

      expect(rig.slots.registerPlugin(manifest), isEmpty);
      expect(rig.slots.uiIn('chat.toolbar'), hasLength(1));
      expect(rig.slots.uiIn('chat.toolbar').single.id, 't');
    });

    test('格式对的插槽即使界面没声明也照样注册', () {
      final rig = makeRig();
      final manifest = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'ui': <dynamic>[
            <String, dynamic>{'slot': 'future.slot', 'id': 'f', 'type': 'button', 'label': 'F'},
            <String, dynamic>{'slot': 'chat.toolbar', 'id': 't', 'type': 'button', 'label': 'T'},
          ],
        },
      }).manifest!;

      final bad = rig.slots.registerPlugin(manifest);

      // **格式对但界面还没声明的插槽照样注册。**
      //
      // 这条以前是"未知插槽直接丢弃"，改了因为：插槽不该是内核的白名单
      // （那意味着加一个位置要改内核），而且"插件先加载还是界面先渲染"
      // 不该决定谁有效。这里没声明 future.slot，但它注册上了。
      expect(bad, isEmpty);
      expect(rig.slots.uiIn('chat.toolbar'), hasLength(1));
      expect(rig.slots.uiIn('future.slot'), hasLength(1),
          reason: '注册表收下它，界面声明了就会渲染');

      // 界面上没人声明这个位置 —— 注册 ≠ 声明
      expect(rig.slots.isDeclared('future.slot'), isFalse,
          reason: '注册只说明插件挂在那儿，位置存不存在由界面说了算');
    });

    test('格式非法的插槽被拒绝并记审计', () {
      final rig = makeRig();
      final manifest = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'ui': <dynamic>[
            // 含空格和大写开头 —— 不是合法路径
            <String, dynamic>{'slot': 'Bad Slot!', 'id': 'bad', 'type': 'button', 'label': 'B'},
            <String, dynamic>{'slot': 'chat.toolbar', 'id': 't', 'type': 'button', 'label': 'T'},
          ],
        },
      }).manifest!;

      final bad = rig.slots.registerPlugin(manifest);

      expect(bad, <String>['Bad Slot!']);
      // 合法的照常注册 —— 旧宿主 + 新插件不该整体失效
      expect(rig.slots.uiIn('chat.toolbar'), hasLength(1));
      expect(rig.slots.uiIn('Bad Slot!'), isEmpty);
      expect(
        rig.audit.entries.any((e) => e.primitive == 'ui.badSlot'),
        isTrue,
        reason: '要能让插件作者查出来，所以必须记审计',
      );
    });

    test('按 order 排序，同 order 按 pluginId 保证确定性', () {
      final rig = makeRig();
      for (final spec in <List<Object>>[
        <Object>['a.zzz', 'later', 100],
        <Object>['a.aaa', 'early', 10],
        <Object>['a.mmm', 'mid', 50],
      ]) {
        rig.slots.registerPlugin(parseManifest(<String, dynamic>{
          'manifestVersion': 1,
          'id': spec[0],
          'name': 'x',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
          'provides': <String, dynamic>{
            'ui': <dynamic>[
              <String, dynamic>{
                'slot': 'chat.toolbar',
                'id': spec[1],
                'type': 'button',
                'label': 'L',
                'order': spec[2],
              },
            ],
          },
        }).manifest!);
      }

      final ids = rig.slots.uiIn('chat.toolbar').map((u) => u.id).toList();
      expect(ids, <String>['early', 'mid', 'later']);
    });

    test('权限被撤销的控件自动隐藏', () {
      final rig = makeRig();
      final m = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'permissions': <String>['model.chat', 'ui'],
        'provides': <String, dynamic>{
          'ui': <dynamic>[
            <String, dynamic>{
              'slot': 'chat.toolbar',
              'id': 'translate',
              'type': 'button',
              'label': '翻译',
              'permissions': <String>['model.chat'],
            },
          ],
        },
      }).manifest!;

      rig.gatekeeper.registerPlugin(m.id, m.permissionNames);
      rig.slots.registerPlugin(m);

      // 未授权 → 隐藏
      expect(rig.slots.uiIn('chat.toolbar', gatekeeper: rig.gatekeeper), isEmpty);

      rig.gatekeeper.grant(m.id, 'model.chat');
      expect(rig.slots.uiIn('chat.toolbar', gatekeeper: rig.gatekeeper), hasLength(1));

      rig.gatekeeper.revoke(m.id, 'model.chat');
      expect(rig.slots.uiIn('chat.toolbar', gatekeeper: rig.gatekeeper), isEmpty,
          reason: '与其显示一个点了就报错的按钮，不如不显示');
    });

    test('页面按插件分组查找', () {
      final rig = makeRig();
      final m = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'pages': <dynamic>[
            <String, dynamic>{'id': 'game', 'title': '游戏', 'entry': 'pages/game.html'},
          ],
        },
      }).manifest!;
      rig.slots.registerPlugin(m);

      expect(rig.slots.pagesOf('a.b'), hasLength(1));
      expect(rig.slots.findPage('a.b', 'game')!.declaration.entry, 'pages/game.html');
      expect(rig.slots.findPage('a.b', 'nope'), isNull);
    });

    test('注销后控件与页面都消失', () {
      final rig = makeRig();
      final m = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'ui': <dynamic>[
            <String, dynamic>{'slot': 'chat.toolbar', 'id': 't', 'type': 'button', 'label': 'T'},
          ],
          'pages': <dynamic>[
            <String, dynamic>{'id': 'p', 'title': 'P', 'entry': 'a.html'},
          ],
        },
      }).manifest!;
      rig.slots.registerPlugin(m);
      expect(rig.slots.uiCount, 1);

      expect(rig.slots.unregisterPlugin('a.b'), 2);
      expect(rig.slots.uiCount, 0);
      expect(rig.slots.pageCount, 0);
    });

    test('自省输出包含已知插槽与占用情况', () {
      final rig = makeRig();
      final info = rig.slots.describe();
      expect(info['knownSlots'], contains('chat.message.after'));
      expect(info['capacity'], isA<Map<String, dynamic>>());
    });
  });

  // ═══════════════════ 任务 7 · 安装器 ═══════════════════

  group('安装器', () {
    test('全流程：包检查 → manifest → 权限 → 授权 → 落盘 → 注册', () async {
      final rig = makeRig();
      final result = await rig.installer.install(pluginZip(
        tools: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'get_time',
            'description': '获取时间',
            'handler': 'handlers/get_time.js',
          },
        ],
        ui: <Map<String, dynamic>>[
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 't', 'type': 'button', 'label': 'T'},
        ],
        extraFiles: <String, String>{'handlers/get_time.js': '// stub'},
      ));

      expect(result.ok, isTrue, reason: result.issues.join('; '));
      expect(result.state, InstallState.installed);
      expect(result.grantedPermissions, contains('sys.time'));
      expect(rig.tools.lookup('get_time'), isNotNull);
      expect(rig.slots.uiCount, 1);
      expect(rig.store.hasStagingLeftover, isFalse);
      expect(await rig.store.installedVersion('dev.tsukiro.demo'), '1.0.0');
    });

    test('先 staging 后 commit（原子性靠顺序保证）', () async {
      final rig = makeRig();
      await rig.installer.install(pluginZip());

      final ci = rig.store.trace.indexWhere((t) => t.startsWith('createStaging'));
      final co = rig.store.trace.indexWhere((t) => t.startsWith('commitStaging'));
      expect(ci, greaterThanOrEqualTo(0));
      expect(co, greaterThan(ci), reason: '必须先建临时目录，再提交');
      expect(rig.store.hasStagingLeftover, isFalse);
    });

    test('用户拒绝授权时磁盘上什么都不留', () async {
      final rig = makeRig();
      final result = await rig.installer.install(
        pluginZip(),
        consent: (_, __) async => const ConsentResult.deny(),
      );

      expect(result.ok, isFalse);
      expect(result.failedAt, 'consent');
      expect(rig.store.trace.any((t) => t.startsWith('createStaging')), isFalse,
          reason: '授权在落盘之前，拒绝时不该碰磁盘');
      expect(rig.tools.length, 0);
      expect(rig.slots.uiCount, 0);
    });

    test('部分授权时只授给指定权限', () async {
      final rig = makeRig();
      final result = await rig.installer.install(
        pluginZip(permissions: <String>['sys.time', 'ui']),
        consent: (_, __) async => const ConsentResult(
          ConsentDecision.grantPartial,
          granted: <String>['sys.time'],
        ),
      );

      expect(result.ok, isTrue);
      expect(result.grantedPermissions, <String>['sys.time']);
      expect(rig.gatekeeper.check('dev.tsukiro.demo', 'ui').isAllowed, isFalse);
    });

    test('提交阶段出错会回滚，不留半成品', () async {
      final rig = makeRig();
      rig.store.failCommitWith = '磁盘满了';

      final result = await rig.installer.install(pluginZip());

      expect(result.ok, isFalse);
      expect(result.state, InstallState.failed);
      expect(result.failedAt, 'commit');
      expect(rig.store.hasStagingLeftover, isFalse, reason: '临时目录必须被清掉');
      expect(rig.store.trace.any((t) => t.startsWith('discardStaging')), isTrue);
      expect(rig.tools.length, 0, reason: '失败时不该注册任何工具');
    });

    test('Zip Slip 包在落盘前被拒', () async {
      final rig = makeRig();
      final good = pluginZip();
      // 用真实插件目录 + 注入恶意条目
      final tampered = (() {
        final manifest = jsonEncode(<String, dynamic>{
          'manifestVersion': 1,
          'id': 'dev.tsukiro.evil',
          'name': 'evil',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
        });
        return buildZip(<String, String>{
          'manifest.json': manifest,
          'index.js': '// stub',
          '../evil.txt': 'pwned',
        });
      })();
      expect(good, isNotEmpty);

      final result = await rig.installer.install(tampered);
      expect(result.ok, isFalse);
      expect(result.failedAt, 'package');
      expect(rig.store.trace.any((t) => t.startsWith('createStaging')), isFalse);
    });

    test('清单非法时被拒且指出具体字段', () async {
      final rig = makeRig();
      final result = await rig.installer.install(buildZip(<String, String>{
        'manifest.json': jsonEncode(<String, dynamic>{
          'manifestVersion': 1,
          'id': '非法 ID',
          'name': 'x',
          'version': 'bad',
          'runtime': <String, dynamic>{'main': 'index.js'},
        }),
        'index.js': '// stub',
      }));

      expect(result.ok, isFalse);
      expect(result.failedAt, 'manifest');
      expect(result.issues.length, greaterThanOrEqualTo(2),
          reason: '一次性告诉作者所有问题，逐个试错是折磨');
    });

    test('降级安装被拒（不覆盖更新的版本）', () async {
      final rig = makeRig();
      await rig.installer.install(pluginZip(version: '2.0.0'));

      final result = await rig.installer.install(pluginZip(version: '1.0.0'));
      expect(result.ok, isFalse);
      expect(result.issues.join(' '), contains('不能降级'));
    });

    test('升级到更高版本通过', () async {
      final rig = makeRig();
      await rig.installer.install(pluginZip(version: '1.0.0'));
      final result = await rig.installer.install(pluginZip(version: '2.0.0'));

      expect(result.ok, isTrue, reason: result.issues.join('; '));
      expect(await rig.store.installedVersion('dev.tsukiro.demo'), '2.0.0');
    });

    test('用了格式非法的插槽时给出警告但不阻止安装', () async {
      final rig = makeRig();
      final result = await rig.installer.install(pluginZip(
        ui: <Map<String, dynamic>>[
          // 含空格 —— 不是合法路径。
          //
          // 注意：格式**对**但界面还没声明的插槽现在不再告警。
          // 插槽不是白名单 —— 加一个位置不该需要改内核，
          // 而"插件先加载还是界面先渲染"也不该决定谁有效。
          <String, dynamic>{'slot': 'future thing', 'id': 'f', 'type': 'button', 'label': 'F'},
        ],
      ));

      expect(result.ok, isTrue);
      expect(result.warnings.join(' '), contains('future thing'));
    });

    test('卸载把磁盘/权限/工具/插槽四处都清掉', () async {
      final rig = makeRig();
      await rig.installer.install(pluginZip(
        tools: <Map<String, dynamic>>[
          <String, dynamic>{'name': 'get_time', 'description': 'x', 'handler': 'h.js'},
        ],
        ui: <Map<String, dynamic>>[
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 't', 'type': 'button', 'label': 'T'},
        ],
        extraFiles: <String, String>{'h.js': '// stub'},
      ));

      await rig.installer.uninstall('dev.tsukiro.demo');

      expect(rig.tools.lookup('get_time'), isNull);
      expect(rig.slots.uiCount, 0);
      expect(rig.gatekeeper.isRegistered('dev.tsukiro.demo'), isFalse);
      expect(await rig.store.installedVersion('dev.tsukiro.demo'), isNull);
    });

    test('真实插件包能装上（三个测试插件）', () async {
      for (final name in <String>['time-plugin', 'translate-button', 'mini-game']) {
        final rig = makeRig();
        final result = await rig.installer.install(zipDirectory(name));
        expect(result.ok, isTrue, reason: '$name: ${result.issues.join("; ")}');
        expect(result.warnings, isEmpty, reason: '$name 用了未知插槽');
      }
    });
  });

  // ═══════════════════ 任务 8 · Bridge 会话 ═══════════════════

  group('Bridge 会话', () {
    Rig rig = makeRig();
    BridgeSession session = _newSession(rig);

    setUp(() {
      rig = makeRig();
      session = _newSession(rig);
    });

    test('握手前的一切消息被丢弃', () async {
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'req',
        'id': 'r1',
        'method': 'sys.time',
      }));

      expect(response, isNull);
      expect(session.isReady, isFalse);
      expect(
        rig.audit.entries.any((e) => e.primitive == 'bridge.preHandshakeDrop'),
        isTrue,
      );
    });

    test('握手后进入 ready 并返回 bridge.ready', () async {
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'evt',
        'method': 'bridge.hello',
        'params': <String, dynamic>{'pluginId': 'dev.tsukiro.demo', 'hostApi': '^1.0.0'},
      }));

      expect(session.isReady, isTrue);
      expect(response!.kind, BridgeKind.evt);
      expect(response.method, 'bridge.ready');
      expect(response.params!['hostVersion'], isNotNull);
    });

    test('插件冒充其他身份 → 会话被终止', () async {
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'evt',
        'method': 'bridge.hello',
        'params': <String, dynamic>{'pluginId': 'dev.tsukiro.other'},
      }));

      expect(session.isTerminated, isTrue);
      expect(session.terminationReason, contains('冒充'));
      expect(response!.method, 'bridge.fatal');
    });

    test('协议版本过高被拒', () async {
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'evt',
        'method': 'bridge.hello',
        'params': <String, dynamic>{'pluginId': 'dev.tsukiro.demo', 'v': 99},
      }));

      expect(session.isTerminated, isTrue);
      expect(response!.params!['reason'], 'protocol_too_new');
    });

    test('req 被路由到原语注册表并返回 res', () async {
      // 先把插件注册进守门人并授权 —— 否则会先被权限拦下，测不到路由
      rig.gatekeeper.registerPlugin('dev.tsukiro.demo', <String>['sys.time']);
      rig.gatekeeper.grant('dev.tsukiro.demo', 'sys.time');
      await _handshake(session);

      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'req',
        'id': 'r1',
        'method': 'sys.time',
      }));

      expect(response!.kind, BridgeKind.res);
      expect(response.id, 'r1');
      expect((response.result! as Map<String, dynamic>)['iso'], isNotNull);
    });

    test('未授权时返回 err 且带权限错误码', () async {
      await _handshake(session);
      // 没有 install 过，插件未注册 → unknownPlugin
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'req',
        'id': 'r1',
        'method': 'sys.time',
      }));

      expect(response!.kind, BridgeKind.err);
      expect(response.error!.code, TsukiroErrorCode.permissionDenied);
    });

    test('保留命名空间 __host.* 对插件关闭', () async {
      await _handshake(session);
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'req',
        'id': 'r1',
        'method': '__host.secret',
      }));

      expect(response!.kind, BridgeKind.err);
      expect(response.error!.message, contains('保留命名空间'));
    });

    test('未实现的原语返回 UNSUPPORTED', () async {
      await _handshake(session);
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'req',
        'id': 'r1',
        'method': 'media.listPhotos',
      }));

      expect(response!.kind, BridgeKind.err);
      expect(response.error!.code, TsukiroErrorCode.unsupported);
    });

    test('致命消息体不会打断会话（只是被丢弃）', () async {
      await _handshake(session);
      expect(await session.handleRaw('这不是 json'), isNull);
      expect(await session.handleRaw('{"v":1,"kind":"乱写"}'), isNull);
      expect(await session.handleRaw('{"v":1,"kind":"req"}'), isNull);
      expect(session.isReady, isTrue, reason: '坏消息只丢自己，不该毁掉会话');
    });

    test('反向调用能拿到插件的响应', () async {
      await _handshake(session);

      // 模拟宿主发 inv，然后插件回 res
      final future = session.invoke('tool.invoke', params: <String, dynamic>{
        'tool': 'get_time',
      }, timeout: const Duration(milliseconds: 500));

      // 找出宿主发出的 id
      await Future<void>.delayed(Duration.zero);
      final id = _pendingId(session);
      expect(id, isNotNull);

      await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'res',
        'id': id,
        'result': <String, dynamic>{'time': '2026-02-14T10:23:41'},
      }));

      final response = await future;
      expect(response.kind, BridgeKind.res);
      expect((response.result! as Map<String, dynamic>)['time'], '2026-02-14T10:23:41');
    });

    test('插件不响应时反向调用超时返回失败（不抛异常）', () async {
      await _handshake(session);

      final response = await session.invoke(
        'tool.invoke',
        timeout: const Duration(milliseconds: 60),
      );

      expect(response.kind, BridgeKind.err,
          reason: '工具失败要作为一个正常结果交给模型，而不是抛异常打断循环');
      expect(response.error!.code, TsukiroErrorCode.timeout);
    });

    test('未握手时反向调用直接失败', () async {
      final response = await session.invoke('tool.invoke');
      expect(response.kind, BridgeKind.err);
      expect(response.error!.message, contains('尚未就绪'));
    });

    test('插件不该发的 kind 被记审计并忽略', () async {
      await _handshake(session);
      final response = await session.handleRaw(jsonEncode(<String, dynamic>{
        'v': 1,
        'kind': 'inv',
        'id': 'x',
        'method': 'tool.invoke',
      }));

      expect(response, isNull);
      expect(
        rig.audit.entries.any((e) => e.primitive == 'bridge.unexpectedKind'),
        isTrue,
      );
    });

    test('终止会话会失败掉所有悬挂的反向调用', () async {
      await _handshake(session);
      final future = session.invoke('tool.invoke', timeout: const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      await session.shutdown(reason: '测试');

      final response = await future;
      expect(response.kind, BridgeKind.err);
      expect(session.isTerminated, isTrue);
    });

    test('权限变更通知能被构造出来', () async {
      await _handshake(session);
      final evt = session.notifyPermissionChange(revoked: <String>['sys.time']);
      expect(evt!.method, 'permission.change');
      expect(evt.params!['revoked'], <String>['sys.time']);
    });
  });

  // ═══════════════════ 任务 9 · 内存服务 ═══════════════════

  group('上下文注入', () {
    test('注入按 position 与 priority 组装', () async {
      final sink = InMemoryContextSink();
      await sink.inject(
        pluginId: 'a.x',
        text: '尾部',
        position: 'append',
        priority: 100,
      );
      await sink.inject(
        pluginId: 'a.y',
        text: '头部',
        position: 'prepend',
        priority: 100,
      );

      final built = sink.buildInjection();
      expect(built.indexOf('头部'), lessThan(built.indexOf('尾部')));
    });

    test('单插件超上限被拒', () async {
      final sink = InMemoryContextSink(maxBytesPerPlugin: 30);
      await expectLater(
        sink.inject(
          pluginId: 'a.b',
          text: '这是一段很长的文本，肯定超过三十字节的限额了',
          position: 'append',
          priority: 1,
        ),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.rateLimited,
        )),
      );
    });

    test('ttl 到期后自动失效', () async {
      final sink = InMemoryContextSink();
      await sink.inject(
        pluginId: 'a.b',
        text: '短暂',
        position: 'append',
        priority: 1,
        ttl: const Duration(milliseconds: 30),
      );
      expect(sink.count, 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sink.buildInjection(), isEmpty);
    });

    test('按 tag 精确撤销', () async {
      final sink = InMemoryContextSink();
      await sink.inject(
        pluginId: 'a.b',
        text: 'x',
        position: 'append',
        priority: 1,
        tag: 'mood',
      );
      await sink.inject(
        pluginId: 'a.b',
        text: 'y',
        position: 'append',
        priority: 1,
        tag: 'other',
      );

      expect(await sink.clearByTag('a.b', 'mood'), 1);
      expect(sink.count, 1);
    });

    test('插件停用清空其全部注入（不能留后门）', () async {
      final sink = InMemoryContextSink();
      await sink.inject(pluginId: 'a.b', text: 'x', position: 'append', priority: 1);
      await sink.inject(pluginId: 'a.c', text: 'y', position: 'append', priority: 1);

      expect(await sink.clearPlugin('a.b'), 1);
      expect(sink.buildInjection(), 'y');
    });
  });

  group('消息操作', () {
    test('patch 只允许白名单字段，其余静默丢弃并记录', () async {
      final store = InMemoryMessageStore();
      final id = await store.append('s1', const ChatMessage(role: ChatRole.assistant, content: '原'));

      await store.patch(id, <String, dynamic>{
        'content': '新',
        'role': 'system', // 不许改
        'id': 'hacked', // 不许改
        'createdAt': 0, // 不许改
      });

      expect(store.getStored(id)!.content, '新');
      expect(store.getStored(id)!.role, ChatRole.assistant, reason: 'role 不该被改掉');
      expect(store.rejectedPatchFields, containsAll(<String>['role', 'id', 'createdAt']));
    });

    test('patch 不存在的消息抛 NOT_FOUND', () async {
      final store = InMemoryMessageStore();
      await expectLater(
        store.patch('nope', <String, dynamic>{'content': 'x'}),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.notFound,
        )),
      );
    });

    test('append 不触发模型调用，send 会', () async {
      var sendCalls = 0;
      final store = InMemoryMessageStore(
        sendHandler: (sessionId, content) async {
          sendCalls++;
          return 'triggered';
        },
      );

      await store.append('s1', const ChatMessage(role: ChatRole.user, content: 'a'));
      expect(sendCalls, 0);

      await store.send('s1', 'b');
      expect(sendCalls, 1, reason: 'send 会触发模型调用（消耗点数），append 不会');
    });

    test('list 按会话返回且受 limit 限制', () async {
      final store = InMemoryMessageStore();
      for (var i = 0; i < 10; i++) {
        await store.append('s1', ChatMessage(role: ChatRole.user, content: '$i'));
      }
      await store.append('s2', const ChatMessage(role: ChatRole.user, content: 'other'));

      expect((await store.list('s1')).length, 10);
      expect((await store.list('s1', limit: 3)).length, 3);
      expect((await store.list('s1', limit: 3)).last['content'], '9');
      expect((await store.list('s2')).length, 1);
    });

    test('删除消息', () async {
      final store = InMemoryMessageStore();
      final id = await store.append('s1', const ChatMessage(role: ChatRole.user, content: 'x'));
      expect(await store.delete(id), isTrue);
      expect(await store.delete(id), isFalse);
      expect(store.count, 0);
    });
  });

  group('调度', () {
    test('周期短于下限被拒（想更频繁请用事件）', () async {
      final scheduler = InMemoryScheduler(minPeriod: const Duration(seconds: 60));
      addTearDown(scheduler.dispose);

      await expectLater(
        scheduler.interval(
          pluginId: 'a.b',
          period: const Duration(seconds: 5),
          handler: 'h.js',
        ),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.invalidArgs,
        )),
      );
    });

    test('单插件任务数超上限被拒', () async {
      final scheduler = InMemoryScheduler(
        minPeriod: const Duration(milliseconds: 10),
        maxTasksPerPlugin: 2,
      );
      addTearDown(scheduler.dispose);

      for (var i = 0; i < 2; i++) {
        await scheduler.interval(
          pluginId: 'a.b',
          period: const Duration(milliseconds: 50),
          handler: 'h$i.js',
        );
      }

      await expectLater(
        scheduler.interval(
          pluginId: 'a.b',
          period: const Duration(milliseconds: 50),
          handler: 'h3.js',
        ),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.rateLimited,
        )),
      );
    });

    test('once 在延迟后触发，只触发一次', () async {
      var fires = 0;
      final scheduler = InMemoryScheduler(onFire: (_) => fires++);
      addTearDown(scheduler.dispose);

      await scheduler.once(
        pluginId: 'a.b',
        delay: const Duration(milliseconds: 30),
        handler: 'h.js',
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fires, 1);
      expect(scheduler.count, 0, reason: 'once 触发后自动移除');
    });

    test('interval 反复触发', () async {
      var fires = 0;
      final scheduler = InMemoryScheduler(
        minPeriod: const Duration(milliseconds: 10),
        onFire: (_) => fires++,
      );
      addTearDown(scheduler.dispose);

      await scheduler.interval(
        pluginId: 'a.b',
        period: const Duration(milliseconds: 20),
        handler: 'h.js',
      );

      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(fires, greaterThanOrEqualTo(2));
    });

    test('插件不再活跃时任务自动取消（不留僵尸任务）', () async {
      var fires = 0;
      var active = true;
      final scheduler = InMemoryScheduler(
        minPeriod: const Duration(milliseconds: 10),
        onFire: (_) => fires++,
        isPluginActive: (_) => active,
      );
      addTearDown(scheduler.dispose);

      await scheduler.interval(
        pluginId: 'a.b',
        period: const Duration(milliseconds: 20),
        handler: 'h.js',
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      active = false;
      final firesBefore = fires;
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(fires, firesBefore, reason: '插件停用后不该再触发');
      expect(scheduler.count, 0, reason: '任务应被自动移除');
    });

    test('cancel / clearPlugin / list', () async {
      final scheduler = InMemoryScheduler(minPeriod: const Duration(milliseconds: 10));
      addTearDown(scheduler.dispose);

      final a = await scheduler.interval(
        pluginId: 'a.b',
        period: const Duration(milliseconds: 100),
        handler: 'h.js',
      );
      await scheduler.interval(
        pluginId: 'a.c',
        period: const Duration(milliseconds: 100),
        handler: 'h.js',
      );

      expect((await scheduler.list()).length, 2);
      expect((await scheduler.list(pluginId: 'a.b')).length, 1);
      expect(await scheduler.cancel(a), isTrue);
      expect(await scheduler.cancel(a), isFalse);
      expect(await scheduler.clearPlugin('a.c'), 1);
      expect(scheduler.count, 0);
    });
  });
}

// ─────────────────────────── 辅助 ───────────────────────────

BridgeSession _newSession(Rig rig) => BridgeSession(
      pluginId: 'dev.tsukiro.demo',
      pluginVersion: '1.0.0',
      registry: rig.registry,
      gatekeeper: rig.gatekeeper,
      audit: rig.audit,
    );

Future<void> _handshake(BridgeSession session) async {
  await session.handleRaw(jsonEncode(<String, dynamic>{
    'v': 1,
    'kind': 'evt',
    'method': 'bridge.hello',
    'params': <String, dynamic>{'pluginId': 'dev.tsukiro.demo', 'hostApi': '^1.0.0'},
  }));
}

/// 取当前悬挂的反向调用 id。
///
/// 生产代码不需要知道这个 —— 宿主把消息投递给 WebView 就完事了。
/// 但测试里没有 WebView，需要知道"宿主刚发出了哪个 id"才能模拟插件的回音。
String? _pendingId(BridgeSession session) {
  final ids = session.pendingInvokeIds;
  return ids.isEmpty ? null : ids.first;
}
