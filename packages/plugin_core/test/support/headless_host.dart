/// 无头宿主 —— 在没有 Flutter / Android / WebView 的情况下跑通**完整链路**。
///
/// 这是 Demo 的可行性验证台。它替代的东西只有两处：
///
/// | 真实环境 | 这里 | 是否影响架构验证 |
/// |---|---|---|
/// | Flutter 宿主 UI | [TestFakeServices] 里的记录型实现 | ❌ 不影响：内核只依赖抽象接口 |
/// | WebView + JS 插件运行时 | [PluginRuntimeStub] | ❌ 不影响：Bridge 契约一致 |
/// | 真实模型 API | `ScriptedGateway` | ❌ 不影响：`ModelGateway` 契约一致 |
///
/// **不替代的**：原语注册表、权限守门人、工具注册表、钩子总线、
/// 沙箱路径守门、包检查、Bridge 编解码 —— 全部是真实的实现。
///
/// 所以这个验证台能证明「架构成立」，不能证明「JS 引擎能跑」。
library;

import 'dart:typed_data';

import 'package:plugin_core/plugin_core.dart';

// ─────────────────────────── 插件运行时桩 ───────────────────────────

/// 插件侧 `tsukiro.*` API 的 Dart 等价物。
///
/// 与 JS 侧同一个契约：插件**只能**通过这些方法触达宿主，
/// 因此权限校验、沙箱约束、审计都在同一条路径上。
class PluginApi {
  PluginApi({
    required this.pluginId,
    required this.registry,
    required this.tools,
    required this.hooks,
  });

  final String pluginId;
  final PrimitiveRegistry registry;
  final ToolRegistry tools;
  final HookBus hooks;

  /// 调原语（等价于 JS 里的 `tsukiro.sys.time(...)`）。
  Future<Object?> call(String primitive, [Map<String, dynamic>? args]) =>
      registry.invoke(pluginId, primitive, args);

  // ── 常用原语的语法糖，与 JS 侧 SDK 一一对应 ──

  Future<Object?> sysTime({String? tz}) => call('sys.time', <String, dynamic>{if (tz != null) 'tz': tz});

  Future<void> toast(String text, {String kind = 'info'}) =>
      call('ui.toast', <String, dynamic>{'text': text, 'kind': kind});

  Future<Object?> readFile(String path) =>
      call('fs.read', <String, dynamic>{'path': path});

  Future<Object?> chat({
    required List<Map<String, dynamic>> messages,
    String? model,
    double? temperature,
    bool stream = false,
  }) =>
      call('model.chat', <String, dynamic>{
        'messages': messages,
        if (model != null) 'model': model,
        if (temperature != null) 'temperature': temperature,
        'stream': stream,
      });

  /// 调别的插件提供的工具（等价于 `tsukiro.tool.call`）。
  Future<Object?> callTool(String name, [Map<String, dynamic>? args]) async {
    final tool = tools.lookup(name);
    if (tool == null) {
      throw TsukiroException(
        TsukiroErrorCode.notFound,
        '未知工具 "$name"',
        details: <String, dynamic>{'tool': name},
      );
    }
    if (!tool.exposed) {
      throw TsukiroException(
        TsukiroErrorCode.permissionDenied,
        '工具 "$name" 未开放给其他插件调用',
      );
    }
    return call('tool.call', <String, dynamic>{'name': name, 'args': args ?? const <String, dynamic>{}});
  }
}

/// 插件 handler 的函数签名。
///
/// 对应 JS 里的 `export default async function handler(args) { ... }`。
typedef PluginHandler = Future<Object?> Function(PluginApi api, Map<String, dynamic> args);

/// 插件运行时桩：handler 相对路径 → Dart 实现。
///
/// 真实环境里这是「WebView 里 import 那个 .js 文件」。
class PluginRuntimeStub {
  PluginRuntimeStub(this.pluginId, this.handlers);

  final String pluginId;

  /// `handlers/get_time.js` → 闭包。
  final Map<String, PluginHandler> handlers;

  PluginHandler? operator [](String handlerPath) => handlers[handlerPath];

  bool has(String handlerPath) => handlers.containsKey(handlerPath);
}

// ─────────────────────────── 安装 ───────────────────────────

/// 安装结果。
class InstallOutcome {
  const InstallOutcome({
    required this.ok,
    this.manifest,
    this.grantedPermissions = const <String>[],
    this.issues = const <String>[],
    this.rejectedBy,
  });

  final bool ok;
  final PluginManifest? manifest;
  final List<String> grantedPermissions;
  final List<String> issues;

  /// 被哪一步拦下：`package` / `manifest` / `compatibility` / `permissions`。
  final String? rejectedBy;

  @override
  String toString() =>
      ok ? 'InstallOutcome(ok: ${manifest?.id})' : 'InstallOutcome(REJECTED by $rejectedBy: ${issues.join("; ")})';
}

// ─────────────────────────── 结果类型（复用库里的定义） ───────────────────────────

// 刻意**不**在这里另写一套循环结果类型：
// Agent 循环已经落在 plugin_core/lib/src/host/agent_loop.dart，
// 无头验证台、Flutter 宿主、真模型集成测试用的必须是同一份实现。
// 各写一遍的后果是"测过的逻辑和线上跑的不是同一个"。
typedef TurnResult = AgentTurnResult;



// ─────────────────────────── 宿主 ───────────────────────────

/// 无头宿主。
///
/// **[hostApiVersion] 是「宿主 API 版本」，不是「产品版本」。**
/// 插件 manifest 里写的是 `hostApi: "^1.0.0"`，所以宿主必须报 1.x ——
/// 报 0.x 会让所有插件在兼容性检查那一步被拒。
///
/// 这个坑值得记：`minHostVersion` 是下限（0.1.0 满足被 1.0.0 满足），
/// 而 `hostApi` 是**范围匹配**（major 必须相同），两者语义不同。
/// 如果宿主版本号与 hostApi 的主版本对不上，插件一个都装不上。
const String hostApiVersion = '1.0.0';

class HeadlessHost {
  HeadlessHost({
    required this.gatekeeper,
    required this.registry,
    required this.tools,
    required this.hooks,
    required this.gateway,
    required this.services,
    this.persona = '你是一个简洁的助手。',
    this.hostVersion = hostApiVersion,
    this.maxSteps = 3,
    AuditSink? audit,
  }) : audit = audit ?? const NullAuditSink();

  final Gatekeeper gatekeeper;
  final PrimitiveRegistry registry;
  final ToolRegistry tools;
  final HookBus hooks;
  final ModelGateway gateway;
  final ServiceRegistry services;
  final AuditSink audit;
  final String persona;
  final String hostVersion;

  /// 防死循环。真实产品里没有上限的 Agent 循环遇到"反复调同一工具"会无限烧钱。
  final int maxSteps;

  final Map<String, PluginRuntimeStub> _runtimes = <String, PluginRuntimeStub>{};

  /// 已安装插件（id → manifest）。
  final Map<String, PluginManifest> installed = <String, PluginManifest>{};

  final ZipReader _zipReader = const ZipReader();

  // ── 装配工厂 ──

  /// 建一个开箱可用的无头宿主：全量注册原语（只有 8 个有实现）+ 空注册表。
  static HeadlessHost bootstrap({
    required ServiceRegistry services,
    required ModelGateway gateway,
    AuditSink? audit,
    String persona = '你是一个简洁的助手。',
  }) {
    final gk = Gatekeeper();
    final reg = PrimitiveRegistry(
      gatekeeper: gk,
      services: services,
      audit: audit,
    );
    // 全部 24 个域都注册；只有 demo handler 有真实现
    reg.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));

    final bus = HookBus(dispatcher: (_, __) async => null, audit: audit);
    final toolReg = ToolRegistry();

    // 自省原语需要能拿到 registry / bus
    services.put<PrimitiveRegistry>(reg);
    services.put<HookBus>(bus);
    services.put<ToolRegistry>(toolReg);
    services.put<Gatekeeper>(gk);

    return HeadlessHost(
      gatekeeper: gk,
      registry: reg,
      tools: toolReg,
      hooks: bus,
      gateway: gateway,
      services: services,
      audit: audit,
      persona: persona,
    );
  }

  // ── 安装 ──

  /// 安装插件包。
  ///
  /// 依次过：**包检查 → manifest 解析 → 宿主兼容 → 权限声明 → 注册**。
  /// 这一步与真实宿主的安装流程完全同构，只是没有磁盘 IO 与权限弹窗。
  Future<InstallOutcome> install(
    Uint8List zipBytes, {
    Set<String> grant = const <String>{},
    bool grantAll = false,
  }) async {
    // ① 包检查（Zip Slip / 符号链接 / 体积 / manifest 定位）
    final PluginArchive archive;
    try {
      archive = _zipReader.read(zipBytes);
    } on TsukiroException catch (e) {
      return InstallOutcome(ok: false, rejectedBy: 'package', issues: <String>[e.message]);
    }

    if (!archive.inspection.isSafe) {
      return InstallOutcome(
        ok: false,
        rejectedBy: 'package',
        issues: archive.inspection.fatalIssues.map((i) => i.toString()).toList(growable: false),
      );
    }

    // ② manifest
    final json = archive.readJson('manifest.json');
    if (json == null) {
      return const InstallOutcome(
        ok: false,
        rejectedBy: 'manifest',
        issues: <String>['包内没有 manifest.json'],
      );
    }
    final parsed = parseManifest(json);
    if (!parsed.isValid) {
      return InstallOutcome(
        ok: false,
        rejectedBy: 'manifest',
        issues: parsed.issues.map((i) => i.toString()).toList(growable: false),
      );
    }
    final manifest = parsed.manifest!;

    // ③ 宿主兼容
    final incompat = checkHostCompatibility(manifest, hostVersion);
    if (incompat != null) {
      return InstallOutcome(
        ok: false,
        manifest: manifest,
        rejectedBy: 'compatibility',
        issues: <String>[incompat],
      );
    }

    // ④ 权限声明（未知权限名 / denied 级）
    final rejectedPerms = gatekeeper.validateForInstall(manifest.permissionNames);
    if (rejectedPerms.isNotEmpty) {
      return InstallOutcome(
        ok: false,
        manifest: manifest,
        rejectedBy: 'permissions',
        issues: <String>['宿主不接受的权限：${rejectedPerms.join(", ")}'],
      );
    }

    // ⑤ 注册：权限 → 工具
    final unknown = gatekeeper.registerPlugin(manifest.id, manifest.permissionNames);
    if (unknown.isNotEmpty) {
      return InstallOutcome(
        ok: false,
        manifest: manifest,
        rejectedBy: 'permissions',
        issues: <String>['未知权限：${unknown.join(", ")}'],
      );
    }
    tools.registerPlugin(manifest);
    installed[manifest.id] = manifest;

    // ⑥ 授权（真实环境是弹窗，这里由调用方决定）
    final granted = gatekeeper.grantAll(
      manifest.id,
      grantAll ? manifest.permissionNames : grant,
    );

    audit.write(AuditEntry(
      pluginId: manifest.id,
      pluginVersion: manifest.version,
      kind: 'plugin',
      primitive: 'plugin.install',
      result: 'ok',
      argsDigest: <String, dynamic>{
        'granted': granted,
        'declared': manifest.permissionNames,
      },
    ));

    return InstallOutcome(
      ok: true,
      manifest: manifest,
      grantedPermissions: granted,
    );
  }

  /// 挂上插件运行时（真实环境里是创建 WebView 并加载 `index.js`）。
  void attachRuntime(PluginRuntimeStub runtime) {
    _runtimes[runtime.pluginId] = runtime;
  }

  /// 卸载插件：**必须清掉钩子与工具**，否则"插件已卸载但仍在影响 AI 上下文"。
  void uninstall(String pluginId) {
    tools.unregisterPlugin(pluginId);
    hooks.unregisterPlugin(pluginId);
    gatekeeper.unregisterPlugin(pluginId);
    _runtimes.remove(pluginId);
    installed.remove(pluginId);
  }

  // ── 一轮对话 ──

  /// 宿主注入的上下文组装源（插件通过 `context.inject` 写进去的东西）。
  ///
  /// 可空：不需要验证上下文注入时留空即可。
  ContextAssembler? contextAssembler;

  /// 跑一轮对话。
  ///
  /// **委托给库里的 [AgentLoop]** —— 无头验证台不自己实现一遍循环。
  /// 否则会出现"测试跑的是 A 实现、Flutter 宿主跑的是 B 实现"，
  /// 测过了也不代表线上对。
  Future<TurnResult> runTurn({
    required String sessionId,
    required String userText,
    List<ChatMessage> history = const <ChatMessage>[],
  }) {
    final loop = AgentLoop(
      gatekeeper: gatekeeper,
      tools: tools,
      hooks: hooks,
      gateway: gateway,
      invokeTool: _invokePluginTool,
      persona: persona,
      maxSteps: maxSteps,
      audit: audit,
      contextAssembler: contextAssembler,
    );
    return loop.run(sessionId: sessionId, userText: userText, history: history);
  }

  /// 把工具调用转给插件运行时。
  ///
  /// 权限校验、钩子、审计**都不在这里做** —— [AgentLoop] 已经做过。
  /// 这里只负责"找到插件、调用 handler"，职责单一所以也不会被绕过。
  Future<ToolInvocationResult> _invokePluginTool(
    String pluginId,
    String handlerPath,
    Map<String, dynamic> args,
  ) async {
    final runtime = _runtimes[pluginId];
    if (runtime == null) {
      return ToolInvocationResult.failure('NO_RUNTIME', '插件 $pluginId 的运行时未加载');
    }

    final handler = runtime[handlerPath];
    if (handler == null) {
      return ToolInvocationResult.failure('HANDLER_MISSING', '插件包里没有 $handlerPath');
    }

    try {
      final api = PluginApi(
        pluginId: pluginId,
        registry: registry,
        tools: tools,
        hooks: hooks,
      );
      return ToolInvocationResult.ok(await handler(api, args));
    } on TsukiroException catch (e) {
      return ToolInvocationResult.failure(errorCodeToString(e.code), e.message);
    } catch (e) {
      return ToolInvocationResult.failure('PLUGIN_ERROR', '$e');
    }
  }
}