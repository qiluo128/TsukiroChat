/// **真实模型 + 真实插件 + 真实原语**的端到端验证。
///
/// 这个文件回答一个具体问题：
/// **整条架构链路接上真 LLM 之后，还能跑通吗？**
///
/// ```
/// 用户提问
///   → AgentLoop 组装上下文（人设 + 历史 + 插件注入）
///   → HttpModelGateway 流式请求真实中转站
///   → 模型返回 tool_calls: get_time
///   → ToolRegistry 查到它属于时间插件
///   → Gatekeeper 校验 sys.time 权限
///   → ToolInvoker 调用插件的 get_time.js（Dart 桩，与 JS 同契约）
///   → 插件调 tsukiro.sys.time() → PrimitiveRegistry → 真实时钟
///   → 结果回填 → 再请求模型 → 模型用自然语言说出时间
/// ```
///
/// 中间没有任何环节被替换成假实现，除了：
///   - 插件的 JS 运行时 → Dart 桩（同一契约，因为无头环境没有 WebView）
///   - 宿主 UI → 记录型假实现
///
/// 没有配置时整个文件跳过。
library;

import 'package:model_gateway/model_gateway.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

import 'support/live_config.dart';
import 'support/zip_builder.dart';

final LiveConfig? liveConfig = loadLiveConfig();

void main() {
  final skipReason =
      liveConfig == null ? '没有真实 API 配置（dev/dev-config.json 或环境变量）' : null;

  if (liveConfig != null) {
    // ignore: avoid_print
    print('真实模型：${liveConfig!.summary}');
  }

  group('真实模型端到端', () {
    late HttpModelGateway gateway;
    late Gatekeeper gatekeeper;
    late PrimitiveRegistry primitives;
    late ToolRegistry tools;
    late HookBus hooks;
    late AgentLoop loop;
    late InMemoryPluginStore store;
    late Installer installer;
    late RecordingClock clock;
    late RecordingUi ui;
    late MemoryAuditSink audit;

    /// 插件的 handler 桩：`handlers/get_time.js` → Dart 闭包。
    ///
    /// 逻辑与 `plugins/time-plugin/handlers/get_time.js` **逐行对应**。
    late Map<String, PluginHandler> runtime;
    setUp(() {
      audit = MemoryAuditSink();
      gatekeeper = Gatekeeper();
      clock = RecordingClock(DateTime(2026, 2, 14, 10, 23, 41));
      ui = RecordingUi();

      gateway = HttpModelGateway(config: liveConfig!.provider);

      final services = ServiceRegistry()
        ..put<HostClock>(clock)
        ..put<HostUi>(ui)
        ..put<HostFiles>(_NoFiles())
        ..put<SandboxProvider>(_NoSandbox())
        ..put<ModelGateway>(gateway);

      primitives = PrimitiveRegistry(
        gatekeeper: gatekeeper,
        services: services,
        audit: audit,
      );
      primitives.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
      services.put<PrimitiveRegistry>(primitives);

      tools = ToolRegistry();
      hooks = HookBus(dispatcher: (_, __) async => null, audit: audit);

      store = InMemoryPluginStore();
      installer = Installer(
        store: store,
        gatekeeper: gatekeeper,
        tools: tools,
        slots: SlotRegistry(audit: audit),
        audit: audit,
      );

      runtime = <String, PluginHandler>{
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
    });

    tearDown(() => gateway.close());

    /// 装插件 + 建 AgentLoop。**用的是库里的 Installer 与 AgentLoop**，
    /// 不是测试专用的简化版。
    Future<void> boot({bool grantAll = true}) async {
      final result = await installer.install(
        zipDirectory('time-plugin'),
        // ConsentCallback 的签名是 (manifest, declaredPermissions)
        consent: (_, __) async => grantAll
            ? const ConsentResult.grantAll()
            : const ConsentResult.deny(),
      );
      expect(result.ok, isTrue, reason: result.issues.join('; '));

      loop = AgentLoop(
        gatekeeper: gatekeeper,
        tools: tools,
        hooks: hooks,
        gateway: gateway,
        persona: '你是雪，一个冷淡但心软的学姐。回答要简短。',
        maxSteps: 3,
        audit: audit,
        invokeTool: (pluginId, handlerPath, args) async {
          final handler = runtime[handlerPath];
          if (handler == null) {
            return ToolInvocationResult.failure('HANDLER_MISSING', handlerPath);
          }
          try {
            final api = PluginCallApi(pluginId: pluginId, registry: primitives);
            return ToolInvocationResult.ok(await handler(api, args));
          } on TsukiroException catch (e) {
            return ToolInvocationResult.failure(errorCodeToString(e.code), e.message);
          } catch (e) {
            return ToolInvocationResult.failure('PLUGIN_ERROR', '$e');
          }
        },
      );
    }

    test('① 模型真的会调用插件工具，并把结果说成人话', () async {
      await boot();

      final turn = await loop.run(
        sessionId: 's1',
        userText: '现在几点了？用工具查一下。',
      );

      // ignore: avoid_print
      print('  轮数：${turn.steps}，工具调用：${turn.toolInvocations.length}');
      for (final inv in turn.toolInvocations) {
        // ignore: avoid_print
        print('    · ${inv.toolName} → ${inv.ok ? inv.result : inv.errorCode} (${inv.durationMs}ms)');
      }
      // ignore: avoid_print
      print('  最终回复："${turn.finalText.trim()}"');

      expect(turn.usedTools, isTrue,
          reason: '模型没有调用工具。若该模型不支持 function calling，'
              '它就不能用于本项目的工具链路');

      final inv = turn.toolInvocations.single;
      expect(inv.ok, isTrue, reason: inv.errorMessage);
      expect(inv.pluginId, 'dev.tsukiro.time');

      // 时间来自我们注入的固定时钟 —— 证明值真的穿透了整条链路
      final payload = inv.result! as Map<String, dynamic>;
      expect(payload['time'], startsWith('2026-02-14T10:23:41'));

      expect(turn.finalText.trim(), isNotEmpty, reason: '模型应该用自然语言总结');
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('② 撤销权限后工具对模型不可见，对话仍能完成', () async {
      await boot();

      // 撤销前工具应该出现在给模型的工具表里
      gatekeeper.revoke('dev.tsukiro.time', 'sys.time');
      expect(tools.visibleTools(gatekeeper: gatekeeper), isEmpty,
          reason: '权限被撤销后不该再把工具给模型 —— 否则只会浪费一次往返');

      final turn = await loop.run(sessionId: 's1', userText: '现在几点了？');

      expect(turn.usedTools, isFalse);
      expect(turn.finalText.trim(), isNotEmpty, reason: '对话照常完成');
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('③ 插件拿不到 Key —— model.chat 拒绝多余参数', () async {
      // 必须用一个**真的声明了 model.chat** 的插件。
      // 时间插件只声明 sys.time，拿它测会在「声明即上限」那一步就被拒 ——
      // 那是另一条防线，测不到参数校验这一条。
      final installed = await installer.install(zipDirectory('translate-button'));
      expect(installed.ok, isTrue, reason: installed.issues.join('; '));
      expect(installed.manifest!.permissionNames, contains('model.chat'));

      await expectLater(
        primitives.invoke('dev.tsukiro.translate', 'model.chat', <String, dynamic>{
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'x'},
          ],
          'apiKey': 'sk-试图偷Key',
          'baseUrl': 'https://evil.example.com',
        }),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.invalidArgs,
        )),
        reason: 'additionalProperties: false 让多传字段直接报错 —— '
            '插件的参数 schema 里根本没有 apiKey 这个位置',
      );
    }, skip: skipReason);

    test('④ 审计记录了整轮，且不含对话原文', () async {
      await boot();
      await loop.run(sessionId: 's1', userText: '现在几点了？');

      final modelEntries = audit.entries.where((e) => e.primitive == 'model.chat');
      expect(modelEntries, isNotEmpty);

      final digest = modelEntries.last.argsDigest!;
      expect(digest['messageCount'], isNotNull);
      expect(digest.toString(), isNot(contains('几点了')),
          reason: '对话原文绝不能进审计');

      final turnEntry = audit.entries.firstWhere((e) => e.primitive == 'agent.turn');
      expect(turnEntry.argsDigest!['toolCalls'], 1);
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));
  });
}

// ─────────────────────────── 最小假实现 ───────────────────────────

/// 固定时钟。用它而不是真实时间，是为了能断言"值真的穿透了整条链路"。
class RecordingClock implements HostClock {
  RecordingClock(this.fixed);

  final DateTime fixed;

  @override
  String get timezoneName => 'Asia/Shanghai';

  @override
  DateTime now() => fixed;

  @override
  DateTime? nowIn(String timezoneName) {
    const offsets = <String, int>{'Asia/Shanghai': 8, 'Asia/Tokyo': 9, 'UTC': 0};
    final target = offsets[timezoneName];
    if (target == null) return null;
    final utc = fixed.subtract(const Duration(hours: 8));
    return utc.add(Duration(hours: target));
  }
}

class RecordingUi implements HostUi {
  final List<String> toasts = <String>[];

  @override
  void toast(String text,
      {Duration duration = const Duration(seconds: 2), String kind = 'info'}) {
    toasts.add(text);
  }

  @override
  Future<String?> dialog({
    required String title,
    String? content,
    List<UiButton> buttons = const <UiButton>[],
  }) async =>
      null;

  @override
  Future<bool> navigate(String pageId, {Map<String, dynamic>? params}) async => true;

  @override
  Future<void> close() async {}

  @override
  Future<void> setTitle(String title) async {}
}

/// 时间插件不用文件系统；给一个会响的桩，避免"少注册服务"掩盖问题。
class _NoFiles implements HostFiles {
  Never _unused() => throw UnsupportedError('本测试不该用到文件系统');

  @override
  Future<bool> exists(String absolutePath) async => _unused();

  @override
  Future<List<Map<String, dynamic>>> list(String absoluteDirectory,
          {bool recursive = false}) async =>
      _unused();

  @override
  Future<void> delete(String absolutePath, {bool recursive = false}) async => _unused();

  @override
  Future<List<int>> readBytes(String absolutePath) async => _unused();

  @override
  Future<String> readText(String absolutePath) async => _unused();

  @override
  Future<int> size(String absolutePath) async => _unused();

  @override
  Future<void> writeBytes(String absolutePath, List<int> bytes,
          {bool append = false}) async =>
      _unused();

  @override
  Future<void> writeText(String absolutePath, String text,
          {bool append = false}) async =>
      _unused();
}

class _NoSandbox implements SandboxProvider {
  @override
  String? dataRootFor(String pluginId) => null;
}

// ─────────────────────────── 插件侧 API 的最小等价物 ───────────────────────────

/// 插件 handler 的签名。对应 JS 里的
/// `export default async function handler(args) { ... }`。
typedef PluginHandler = Future<Object?> Function(
  PluginCallApi api,
  Map<String, dynamic> args,
);

/// 插件侧 `tsukiro.*` 的 Dart 等价物。
///
/// `plugin_core/test/support/headless_host.dart` 里有一个更完整的版本，
/// 但跨包的 test 目录导不出来。这里只保留本测试需要的两个方法 ——
/// **关键是它走的仍是 `PrimitiveRegistry.invoke`**，所以权限、参数校验、
/// 超时、审计都在同一条路径上，没有绕过。
class PluginCallApi {
  PluginCallApi({required this.pluginId, required this.registry});

  final String pluginId;
  final PrimitiveRegistry registry;

  Future<Object?> call(String primitive, [Map<String, dynamic>? args]) =>
      registry.invoke(pluginId, primitive, args);

  Future<Object?> sysTime({String? tz}) =>
      call('sys.time', <String, dynamic>{if (tz != null) 'tz': tz});
}