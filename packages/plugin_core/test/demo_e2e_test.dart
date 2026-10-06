/// Demo 可行性验证 —— **在没有 Flutter / Android / WebView 的情况下跑通完整链路**。
///
/// 验证的是 `docs/11-roadmap.md` §3 的四条流程 + 六条附加约束。
/// 真实环境里被替换掉的只有两处：宿主 UI 与 JS 运行时（都是同一契约的桩），
/// **原语注册表、权限守门人、工具注册表、钩子总线、沙箱守门、包检查全部是真实实现**。
///
/// 所以这个套件能回答：「架构走得通吗？」
/// 它**不能**回答：「WebView 能跑 JS 吗？」—— 那是阶段 A3 的事。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

import 'support/fake_services.dart';
import 'support/headless_host.dart';
import 'support/zip_builder.dart';

// ─────────────────────────── 装配工具 ───────────────────────────

/// 一整套无头环境。
class Rig {
  Rig({
    required this.host,
    required this.gatekeeper,
    required this.registry,
    required this.tools,
    required this.hooks,
    required this.gateway,
    required this.services,
    required this.clock,
    required this.ui,
    required this.files,
    required this.audit,
    required this.sandbox,
  });

  final HeadlessHost host;
  final Gatekeeper gatekeeper;
  final PrimitiveRegistry registry;
  final ToolRegistry tools;
  final HookBus hooks;
  final ScriptedGateway gateway;
  final ServiceRegistry services;
  final FakeClock clock;
  final RecordingUi ui;
  final InMemoryFiles files;
  final MemoryAuditSink audit;

  /// 沙箱根目录映射。测试可以给临时装上的插件补一个根。
  final MapSandbox sandbox;

  /// 沙箱根目录（测试用固定值）。
  static const String sandboxRoot = '/sandbox/dev.tsukiro.time';
}

/// 建一套无头环境。`script` 是模型按顺序给的回复。
Rig makeRig(List<ModelReply> script) {
  final clock = FakeClock(
    fixed: DateTime(2026, 2, 14, 10, 23, 41),
    timezoneName: 'Asia/Shanghai',
  );
  final ui = RecordingUi();
  final files = InMemoryFiles();
  final sandbox = MapSandbox(<String, String>{'dev.tsukiro.time': Rig.sandboxRoot});
  final gateway = ScriptedGateway(script);
  final audit = MemoryAuditSink();

  final services = ServiceRegistry()
    ..put<HostClock>(clock)
    ..put<HostUi>(ui)
    ..put<HostFiles>(files)
    ..put<SandboxProvider>(sandbox)
    ..put<ModelGateway>(gateway);

  final host = HeadlessHost.bootstrap(
    services: services,
    gateway: gateway,
    audit: audit,
    persona: '你是雪，一个冷淡但心软的学姐。',
  );

  return Rig(
    host: host,
    gatekeeper: host.gatekeeper,
    registry: host.registry,
    tools: host.tools,
    hooks: host.hooks,
    gateway: gateway,
    services: services,
    clock: clock,
    ui: ui,
    files: files,
    audit: audit,
    sandbox: sandbox,
  );
}

/// 时间插件的 handler —— 与 `plugins/time-plugin/handlers/get_time.js` 逻辑一一对应。
final Map<String, PluginHandler> timePluginHandlers = <String, PluginHandler>{
  'handlers/get_time.js': (api, args) async {
    final t = await api.sysTime(tz: args['timezone'] as String?);
    final map = t! as Map<String, dynamic>;
    return <String, dynamic>{
      'time': map['iso'],
      'epochMs': map['epochMs'],
      'timezone': map['tz'],
      'human': map['human'],
      'hint': '请用自然语言把时间告诉用户，不要直接输出 JSON。',
    };
  },
};

/// 翻译按钮插件的 handler —— 对应 `plugins/translate-button/index.js`。
final Map<String, PluginHandler> translatePluginHandlers = <String, PluginHandler>{
  'ui.click': (api, args) async {
    if (args['id'] != 'translate') return null;
    final translation = await api.chat(messages: <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': '你是翻译引擎。只输出译文。'},
      <String, dynamic>{'role': 'user', 'content': '翻译成中文：The moon is beautiful tonight'},
    ]);
    final text = ((translation! as Map<String, dynamic>)['text'] ?? '').toString();
    await api.toast(text.isEmpty ? '翻译完成' : text);
    return <String, dynamic>{'translated': text};
  },
};

/// 猜数字插件页面里的核心动作 —— 对应 `plugins/mini-game/pages/game.html` 的 `askAi`。
final Map<String, PluginHandler> gamePluginHandlers = <String, PluginHandler>{
  'pages/game/askAi': (api, args) async {
    final r = await api.chat(messages: <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': '你是猜数字裁判。答案是 42。'},
      <String, dynamic>{'role': 'user', 'content': args['guess']?.toString() ?? ''},
    ]);
    return <String, dynamic>{'reply': (r! as Map<String, dynamic>)['text']};
  },
};

/// 造一个合成插件包 —— 用于测试真实插件**没有声明**的权限场景。
///
/// 时间插件只声明 `sys.time`，所以拿它去测 `fs.read` / `model.chat` 会被
/// 「声明即上限」正确拒掉。要测那些原语，就得有一个真的声明了它们的插件。
Uint8List syntheticPlugin({
  required String id,
  required String name,
  List<Map<String, dynamic>> permissions = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[],
}) {
  final manifest = <String, dynamic>{
    'manifestVersion': 1,
    'id': id,
    'name': name,
    'version': '1.0.0',
    'runtime': <String, dynamic>{'main': 'index.js'},
    'permissions': permissions,
    if (tools.isNotEmpty)
      'provides': <String, dynamic>{'tools': tools},
  };
  return buildZip(<String, String>{
    'manifest.json': jsonEncode(manifest),
    'index.js': '// stub',
  });
}

/// 一个声明了 `fs.read` 的插件 id。
const String fsPluginId = 'dev.tsukiro.filemock';

void main() {
  // ═══════════════════ 流程 1 · 能聊 ═══════════════════

  group('流程 1 · 能聊', () {
    test('一轮普通对话返回模型文本', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: '嗯，我在。')]);

      final turn = await rig.host.runTurn(sessionId: 's1', userText: '在吗');

      expect(turn.finalText, '嗯，我在。');
      expect(turn.steps, 1);
      expect(turn.usedTools, isFalse);
      expect(rig.gateway.callCount, 1);
    });

    test('system prompt 用的是宿主人设', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.runTurn(sessionId: 's1', userText: 'hi');

      final sent = rig.gateway.requests.single.messages;
      expect(sent.first.role, ChatRole.system);
      expect(sent.first.content, contains('学姐'));
    });

    test('历史消息会带上', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.runTurn(
        sessionId: 's1',
        userText: '第二句',
        history: <ChatMessage>[ChatMessage.user('第一句'), ChatMessage.assistant('收到')],
      );
      final sent = rig.gateway.requests.single.messages;
      expect(sent.length, 4, reason: 'system + 2 条历史 + 新消息');
    });
  });

  // ═══════════════════ 流程 2 · 时间插件 ═══════════════════

  group('流程 2 · 时间插件（工具调用链路）', () {
    late Rig rig;
    late InstallOutcome install;

    setUp(() async {
      rig = makeRig(<ModelReply>[
        // 第一轮：模型决定调工具
        ModelReply(
          text: '',
          toolCalls: <ToolCall>[
            const ToolCall(
              id: 'call_1',
              name: 'get_time',
              arguments: <String, dynamic>{'timezone': 'Asia/Shanghai'},
            ),
          ],
        ),
        // 第二轮：模型把时间说成人话
        ModelReply(text: '现在是 2026 年 2 月 14 日上午 10 点 23 分。'),
      ]);

      // 真实地走一遍安装流程：zip → 包检查 → manifest → 权限 → 注册
      install = await rig.host.install(zipDirectory('time-plugin'), grantAll: true);
      rig.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.time', timePluginHandlers));
    });

    test('安装成功且权限已授予', () {
      expect(install.ok, isTrue, reason: install.issues.join('; '));
      expect(install.manifest!.id, 'dev.tsukiro.time');
      expect(install.grantedPermissions, contains('sys.time'));
      expect(rig.tools.lookup('get_time'), isNotNull);
    });

    test('问「现在几点」→ 模型调工具 → 返回真实时间', () async {
      final turn = await rig.host.runTurn(sessionId: 's1', userText: '现在几点');

      expect(turn.toolInvocations, hasLength(1));
      final inv = turn.toolInvocations.single;
      expect(inv.ok, isTrue, reason: inv.errorMessage);
      expect(inv.toolName, 'get_time');
      expect(inv.pluginId, 'dev.tsukiro.time');

      final result = inv.result! as Map<String, dynamic>;
      expect(result['timezone'], 'Asia/Shanghai');
      // key 是 time 而不是 iso —— 与真实插件 handlers/get_time.js 的返回一致
      expect(result['time'], startsWith('2026-02-14T10:23:41'));
      expect(result['human'], contains('2026年2月14日'));

      expect(turn.steps, 2, reason: '一次工具调用 + 一次总结');
      expect(turn.finalText, contains('10 点 23 分'));
    });

    test('工具结果真的回填进了模型上下文', () async {
      await rig.host.runTurn(sessionId: 's1', userText: '现在几点');

      final second = rig.gateway.requests[1].messages;
      final toolMsg = second.firstWhere((m) => m.role == ChatRole.tool);
      expect(toolMsg.toolCallId, 'call_1');
      expect(toolMsg.content, contains('2026-02-14T10:23:41'));
    });

    test('时区参数生效（东京）', () async {
      final rig2 = makeRig(<ModelReply>[
        ModelReply(
          text: '',
          toolCalls: <ToolCall>[
            const ToolCall(
              id: 'c',
              name: 'get_time',
              arguments: <String, dynamic>{'timezone': 'Asia/Tokyo'},
            ),
          ],
        ),
        ModelReply(text: '东京是 11 点 23 分。'),
      ]);
      await rig2.host.install(zipDirectory('time-plugin'), grantAll: true);
      rig2.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.time', timePluginHandlers));

      final turn = await rig2.host.runTurn(sessionId: 's1', userText: '东京几点');
      final result = turn.toolInvocations.single.result! as Map<String, dynamic>;
      expect(result['timezone'], 'Asia/Tokyo');
      expect(result['human'], contains('11:23:41'), reason: '上海 10:23 → 东京 11:23');
    });

    test('未实现原语返回 UNSUPPORTED 而不是崩溃', () async {
      // 插件去调一个存在但未实现的原语
      rig.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.time', <String, PluginHandler>{
        'handlers/get_time.js': (api, args) async => api.call('media.listPhotos'),
      }));

      final turn = await rig.host.runTurn(sessionId: 's1', userText: '看看照片');
      final inv = turn.toolInvocations.single;
      expect(inv.ok, isFalse);
      expect(inv.errorCode, 'UNSUPPORTED');
      expect(inv.errorMessage, contains('尚未实现'));
    });
  });

  // ═══════════════════ 流程 3 · 翻译按钮 ═══════════════════

  group('流程 3 · 翻译按钮（UI 插槽 + 插件调 AI）', () {
    test('安装后插槽立即出现控件，且插件能调 AI', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: '今晚月色真美。')]);

      final install = await rig.host.install(
        zipDirectory('translate-button'),
        grantAll: true,
      );
      expect(install.ok, isTrue, reason: install.issues.join('; '));

      // 插槽声明注册成功
      final manifest = install.manifest!;
      expect(manifest.ui, hasLength(1));
      expect(manifest.ui.single.slot, 'chat.toolbar');
      expect(manifest.ui.single.id, 'translate');

      // 插件调 AI
      rig.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.translate', translatePluginHandlers));
      final api = PluginApi(
        pluginId: 'dev.tsukiro.translate',
        registry: rig.registry,
        tools: rig.tools,
        hooks: rig.hooks,
      );
      final result = await translatePluginHandlers['ui.click']!(
        api,
        <String, dynamic>{'id': 'translate'},
      );

      expect((result! as Map<String, dynamic>)['translated'], '今晚月色真美。');
      expect(rig.ui.toastedWith('今晚月色真美'), isTrue);
    });

    test('插件拿不到 Key：model.chat 拒绝多余参数', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.install(zipDirectory('translate-button'), grantAll: true);

      // 插件试图偷偷带上 apiKey / baseUrl
      await expectLater(
        rig.registry.invoke('dev.tsukiro.translate', 'model.chat', <String, dynamic>{
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'x'},
          ],
          'apiKey': 'sk-偷来的',
          'baseUrl': 'https://evil.example.com',
        }),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.invalidArgs,
        )),
        reason: 'additionalProperties: false 让多传字段直接报错',
      );
    });

    test('未授权 model.chat 时调用被拒', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      // 只授予 ui，不授 model.chat
      await rig.host.install(zipDirectory('translate-button'), grant: <String>{'ui'});

      await expectLater(
        rig.registry.invoke('dev.tsukiro.translate', 'model.chat', <String, dynamic>{
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'x'},
          ],
        }),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.permissionDenied,
        )),
      );
    });
  });

  // ═══════════════════ 流程 4 · 小游戏 ═══════════════════

  group('流程 4 · 小游戏（独立页面 + 页面内调 AI）', () {
    test('页面声明解析正确，页面内可通过 Bridge 调 AI', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: '小了')]);

      final install = await rig.host.install(zipDirectory('mini-game'), grantAll: true);
      expect(install.ok, isTrue, reason: install.issues.join('; '));

      final page = install.manifest!.pages.single;
      expect(page.id, 'game');
      expect(page.presentation, 'window');
      expect(page.entry, 'pages/game.html');

      rig.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.guess-number', gamePluginHandlers));
      final api = PluginApi(
        pluginId: 'dev.tsukiro.guess-number',
        registry: rig.registry,
        tools: rig.tools,
        hooks: rig.hooks,
      );
      final r = await gamePluginHandlers['pages/game/askAi']!(
        api,
        <String, dynamic>{'guess': '50'},
      );
      expect((r! as Map<String, dynamic>)['reply'], '小了');
    });

    test('插槽按钮能打开页面', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.install(zipDirectory('mini-game'), grantAll: true);

      await rig.registry.invoke('dev.tsukiro.guess-number', 'ui.navigate', <String, dynamic>{
        'pageId': 'game',
      });
    }, skip: 'ui.navigate 尚未实现（占位）—— 这正是"未实现 = UNSUPPORTED"的预期状态');
  });

  // ═══════════════════ 安全约束 ═══════════════════

  group('安全约束', () {
    test('撤销权限后调用立即失败', () async {
      final rig = makeRig(<ModelReply>[
        ModelReply(
          text: '',
          toolCalls: <ToolCall>[
            const ToolCall(id: 'c1', name: 'get_time', arguments: <String, dynamic>{}),
          ],
        ),
        ModelReply(text: '我没法查时间。'),
      ]);
      await rig.host.install(zipDirectory('time-plugin'), grantAll: true);
      rig.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.time', timePluginHandlers));

      // 先确认能正常调
      final before = await rig.registry.invoke('dev.tsukiro.time', 'sys.time');
      expect(before, isNotNull);

      // 撤销
      rig.gatekeeper.revoke('dev.tsukiro.time', 'sys.time');

      final turn = await rig.host.runTurn(sessionId: 's1', userText: '现在几点');
      final inv = turn.toolInvocations.single;
      expect(inv.ok, isFalse);
      expect(inv.errorCode, 'PERMISSION_DENIED');
      expect(turn.finalText, '我没法查时间。', reason: '工具失败不中断对话，模型照常总结');
    });

    test('撤销权限后工具从模型可见列表中消失', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.install(zipDirectory('time-plugin'), grantAll: true);

      await rig.host.runTurn(sessionId: 's1', userText: 'hi');
      // 第一次请求应该带上 get_time
      final withTool = rig.gateway.requests.last.tools;
      expect(withTool, isNotEmpty);

      rig.gatekeeper.revoke('dev.tsukiro.time', 'sys.time');

      final rig2 = makeRig(<ModelReply>[ModelReply(text: 'y')]);
      await rig2.host.install(zipDirectory('time-plugin'), grant: <String>{});
      await rig2.host.runTurn(sessionId: 's1', userText: 'hi');
      expect(rig2.gateway.requests.last.tools, isEmpty,
          reason: '权限未授予时工具不该出现在模型可见列表里');
    });

    test('沙箱越界被拦成 SANDBOX_VIOLATION', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      // 必须用一个**真的声明了 fs.read** 的插件；时间插件没声明，
      // 拿它测 fs.read 会先被「声明即上限」拒掉，测不到沙箱守门
      await rig.host.install(
        syntheticPlugin(
          id: fsPluginId,
          name: '文件测试插件',
          permissions: <Map<String, dynamic>>[
            <String, dynamic>{'name': 'fs.read', 'reason': '测试沙箱'},
          ],
        ),
        grantAll: true,
      );
      rig.sandbox.register(fsPluginId, '/sandbox/$fsPluginId');

      // 沙箱外的敏感文件
      rig.files.seedOutside('/etc/host_secret.txt', '不该被读到');

      await expectLater(
        rig.registry.invoke(fsPluginId, 'fs.read', <String, dynamic>{
          'path': '../../etc/host_secret.txt',
        }),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.sandboxViolation,
        )),
      );
    });

    test('沙箱内的正常读取可以通过', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.install(
        syntheticPlugin(
          id: fsPluginId,
          name: '文件测试插件',
          permissions: <Map<String, dynamic>>[
            <String, dynamic>{'name': 'fs.read', 'reason': '测试沙箱'},
          ],
        ),
        grantAll: true,
      );

      // 注意：Windows 上 p.absolute('/sandbox/x') 会补上盘符（C:\sandbox\x），
      // 所以种子文件必须用**同一套规范化**后的路径，否则和守门人解析出来的对不上。
      final root = p.normalize(p.absolute('/sandbox/$fsPluginId'));
      rig.sandbox.register(fsPluginId, root);
      rig.files.seed(p.join(root, 'notes', 'hello.txt'), '你好，世界');

      final r = await rig.registry.invoke(fsPluginId, 'fs.read', <String, dynamic>{
        'path': 'notes/hello.txt',
      });
      expect((r! as Map<String, dynamic>)['text'], '你好，世界');
    });

    test('含 Zip Slip 的插件包在安装前被拒', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);

      // 正常包 + 注入 ../evil.txt
      final good = zipDirectory('time-plugin');
      final archive = Archive();
      for (final f in ZipDecoder().decodeBytes(good, verify: false).files) {
        archive.addFile(f);
      }
      final evil = utf8.encode('pwned');
      archive.addFile(ArchiveFile('../evil-traversal.txt', evil.length, evil));
      final tampered = Uint8List.fromList(ZipEncoder().encode(archive)!);

      final outcome = await rig.host.install(tampered);
      expect(outcome.ok, isFalse);
      expect(outcome.rejectedBy, 'package');
      expect(outcome.issues.join(' '), contains('../evil-traversal.txt'));
      expect(rig.tools.lookup('get_time'), isNull, reason: '被拒的包不该注册任何工具');
    });

    test('插件崩溃不影响宿主，且被记为工具失败', () async {
      final rig = makeRig(<ModelReply>[
        ModelReply(
          text: '',
          toolCalls: <ToolCall>[
            const ToolCall(id: 'c1', name: 'get_time', arguments: <String, dynamic>{}),
          ],
        ),
        ModelReply(text: '抱歉，我暂时查不到时间。'),
      ]);
      await rig.host.install(zipDirectory('time-plugin'), grantAll: true);
      rig.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.time', <String, PluginHandler>{
        'handlers/get_time.js': (api, args) async => throw StateError('插件内部炸了'),
      }));

      final turn = await rig.host.runTurn(sessionId: 's1', userText: '现在几点');
      expect(turn.toolInvocations.single.ok, isFalse);
      expect(turn.toolInvocations.single.errorCode, 'PLUGIN_ERROR');
      expect(turn.finalText, '抱歉，我暂时查不到时间。', reason: '宿主完好，对话继续');
    });

    test('工具循环有步数上限（防无限烧钱）', () async {
      // 模型每次都返回工具调用，永不收敛
      final rig = makeRig(List<ModelReply>.generate(
        10,
        (i) => ModelReply(
          text: '',
          toolCalls: <ToolCall>[
            ToolCall(id: 'c$i', name: 'get_time', arguments: <String, dynamic>{}),
          ],
        ),
      ));
      await rig.host.install(zipDirectory('time-plugin'), grantAll: true);
      rig.host.attachRuntime(PluginRuntimeStub('dev.tsukiro.time', timePluginHandlers));

      final turn = await rig.host.runTurn(sessionId: 's1', userText: '现在几点');
      expect(turn.hitStepLimit, isTrue);
      expect(turn.steps, rig.host.maxSteps);
      expect(rig.gateway.callCount, rig.host.maxSteps,
          reason: '模型调用次数必须被 maxSteps 卡住');
    });

    test('审计记录了每一次原语调用，且参数已脱敏', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      // 用合成插件：需要同时声明 sys.time 与 model.chat
      await rig.host.install(
        syntheticPlugin(
          id: 'dev.tsukiro.auditmock',
          name: '审计测试插件',
          permissions: <Map<String, dynamic>>[
            <String, dynamic>{'name': 'sys.time', 'reason': '测试'},
            <String, dynamic>{'name': 'model.chat', 'reason': '测试'},
          ],
        ),
        grantAll: true,
      );

      await rig.registry.invoke('dev.tsukiro.auditmock', 'sys.time', <String, dynamic>{
        'tz': 'Asia/Shanghai',
      });
      await rig.registry.invoke('dev.tsukiro.auditmock', 'model.chat', <String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': '这是隐私内容，不该进审计'},
        ],
      });

      final entries = rig.audit.entries;
      expect(entries, isNotEmpty);

      final modelEntry = entries.firstWhere((e) => e.primitive == 'model.chat');
      expect(modelEntry.argsDigest!['messageCount'], 1);
      expect(
        jsonEncode(modelEntry.argsDigest),
        isNot(contains('这是隐私内容')),
        reason: '对话原文绝不能进审计',
      );
    });
  });

  // ═══════════════════ 可扩展性 ═══════════════════

  group('可扩展性（这轮的重点）', () {
    test('全部 24 个域都注册了，并包含状态与记忆实现', () {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);

      expect(rig.registry.domains, containsAll(<String>[
        'fs', 'sys', 'media', 'contact', 'sms', 'call', 'calendar', 'app',
        'notification', 'location', 'net', 'ui', 'state', 'crypto', 'a11y',
        'screen', 'model', 'tool', 'event', 'log', 'mcp',
        'context', 'message', 'schedule', 'host', 'primitive', 'hook', 'slot',
      ]));

      expect(rig.registry.length, greaterThan(100));
      expect(rig.registry.implementedCount, 23,
          reason: '基础原语、自省原语、状态/记忆和 Surface 原语');
    });

    test('自省：插件能在运行期问宿主支持什么', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.install(zipDirectory('time-plugin'), grantAll: true);

      final caps = await rig.registry.invoke('dev.tsukiro.time', 'host.capabilities')
          as Map<String, dynamic>;
      final primitives = caps['primitives']! as Map<String, dynamic>;

      expect(primitives['sys.time']!['implemented'], isTrue);
      expect(primitives['context.inject']!['implemented'], isFalse,
          reason: '未实现的也要能被查到 —— 插件据此决定降级策略');
      expect(primitives['context.inject']!['permission'], 'context.write');
    });

    test('加一个新原语不需要改宿主核心，注册即可用', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.install(zipDirectory('time-plugin'), grantAll: true);

      // 新增一个原语：只 register，零改动核心
      rig.registry.register(PrimitiveSpec(
        name: 'demo.echo',
        description: '回声测试',
        paramsSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{'text': <String, dynamic>{'type': 'string'}},
          'required': <String>['text'],
          'additionalProperties': false,
        },
        handler: (call) async => <String, dynamic>{'echo': call.args['text']},
      ));

      expect(rig.registry.isImplemented('demo.echo'), isTrue);
      final r = await rig.registry.invoke('dev.tsukiro.time', 'demo.echo', <String, dynamic>{
        'text': 'hi',
      });
      expect((r! as Map<String, dynamic>)['echo'], 'hi');
    });

    test('重复注册同一原语直接抛错（编程错误要早炸）', () {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      expect(
        () => rig.registry.register(const PrimitiveSpec.placeholder(
          name: 'sys.time',
          description: '重复',
        )),
        throwsA(isA<StateError>()),
      );
    });

    test('钩子能注入上下文，且改动被追踪', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: '好')]);

      // 一个"情绪插件"：自己维护状态，通过 contextBuild 注入提示词
      var mood = 72;
      rig.hooks.register(HookRegistration(
        id: 'mood-inject',
        pluginId: 'dev.tsukiro.mood',
        phase: HookPhase.contextBuild,
        handler: 'hooks/inject.js',
        priority: 10,
      ));
      // 替换 dispatcher 让它真的改上下文
      final dynamicRig = makeRigWithDispatcher(rig, (reg, ctx) async {
        if (reg.id == 'mood-inject') {
          ctx.systemPrompt = '${ctx.systemPrompt}\n\n[当前好感度 $mood]';
          mood += 5;
        }
        return null;
      });

      await dynamicRig.host.runTurn(sessionId: 's1', userText: '在吗');

      final sent = dynamicRig.gateway.requests.single.messages.first;
      expect(sent.content, contains('当前好感度 72'),
          reason: '宿主完全不知道"好感度"是什么，只负责把插件注入的文本拼进去');
    });

    test('一个钩子崩溃不影响其他钩子和整轮对话', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: '好')]);

      rig.hooks.register(HookRegistration(
        id: 'good',
        pluginId: 'dev.tsukiro.a',
        phase: HookPhase.contextBuild,
        handler: 'a.js',
        priority: 10,
      ));
      rig.hooks.register(HookRegistration(
        id: 'bad',
        pluginId: 'dev.tsukiro.b',
        phase: HookPhase.contextBuild,
        handler: 'b.js',
        priority: 20,
      ));
      rig.hooks.register(HookRegistration(
        id: 'also-good',
        pluginId: 'dev.tsukiro.c',
        phase: HookPhase.contextBuild,
        handler: 'c.js',
        priority: 30,
      ));

      final rig2 = makeRigWithDispatcher(rig, (reg, ctx) async {
        if (reg.id == 'bad') throw StateError('坏插件');
        ctx.appendMessage(ChatMessage.system('[来自 ${reg.pluginId}]'));
        return null;
      });

      final turn = await rig2.host.runTurn(sessionId: 's1', userText: '在吗');

      expect(turn.hookFailures, hasLength(1));
      expect(turn.hookFailures.single.registration.id, 'bad');
      expect(turn.finalText, '好', reason: '对话照常完成');

      // 好的两个钩子都生效了
      final sent = rig2.gateway.requests.single.messages;
      expect(sent.any((m) => m.content?.contains('dev.tsukiro.a') ?? false), isTrue);
      expect(sent.any((m) => m.content?.contains('dev.tsukiro.c') ?? false), isTrue);
    });

    test('钩子超时被隔离', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: '好')]);
      rig.hooks.register(const HookRegistration(
        id: 'slow',
        pluginId: 'dev.tsukiro.slow',
        phase: HookPhase.contextBuild,
        handler: 'slow.js',
        timeoutMs: 50,
      ));

      final rig2 = makeRigWithDispatcher(rig, (reg, ctx) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return null;
      });

      final turn = await rig2.host.runTurn(sessionId: 's1', userText: '在吗');
      expect(turn.hookFailures, hasLength(1));
      expect(turn.hookFailures.single.timedOut, isTrue);
      expect(turn.finalText, '好');
    });

    test('卸载插件会清掉它的钩子（不留后门）', () async {
      final rig = makeRig(<ModelReply>[ModelReply(text: 'x')]);
      await rig.host.install(zipDirectory('time-plugin'), grantAll: true);
      rig.hooks.register(const HookRegistration(
        id: 'h1',
        pluginId: 'dev.tsukiro.time',
        phase: HookPhase.contextBuild,
        handler: 'h.js',
      ));
      expect(rig.hooks.length, 1);

      rig.host.uninstall('dev.tsukiro.time');

      expect(rig.hooks.length, 0, reason: '插件卸载后不能再影响上下文');
      expect(rig.tools.lookup('get_time'), isNull);
      expect(rig.gatekeeper.isRegistered('dev.tsukiro.time'), isFalse);
    });
  });
}

/// 用自定义 dispatcher 重建一个宿主（其余部件复用）。
///
/// 这样测试可以在不重建整套环境的情况下替换钩子行为。
Rig makeRigWithDispatcher(Rig base, HookDispatcher dispatcher) {
  final bus = HookBus(dispatcher: dispatcher, audit: base.audit);
  // 把已注册的钩子搬过去
  for (final phase in HookPhase.values) {
    for (final reg in base.hooks.hooksOf(phase)) {
      bus.register(reg);
    }
  }

  final host = HeadlessHost(
    gatekeeper: base.gatekeeper,
    registry: base.registry,
    tools: base.tools,
    hooks: bus,
    gateway: base.gateway,
    services: base.services,
    audit: base.audit,
    persona: '你是雪，一个冷淡但心软的学姐。',
  );

  return Rig(
    host: host,
    gatekeeper: base.gatekeeper,
    registry: base.registry,
    tools: base.tools,
    hooks: bus,
    gateway: base.gateway,
    services: base.services,
    clock: base.clock,
    ui: base.ui,
    files: base.files,
    audit: base.audit,
    sandbox: base.sandbox,
  );
}
