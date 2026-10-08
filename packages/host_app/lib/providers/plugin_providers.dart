/// 插件系统的 provider 接线。
///
/// 这里把三样东西连起来：
///   工具表（模型能看到哪些工具）
///   权限门禁（插件能不能调某个原语）
///   插件宿主（WebView 运行时 + 工具路由）
///
/// **三者必须是同一组实例** —— 否则会出现「插件注册的工具在另一个
/// 工具表里」「门禁不知道这个插件」这类问题，而且表现为静默失效。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';

import '../plugin/host_services_impl.dart';
import '../plugin/native_window.dart';
import '../plugin/plugin_state.dart';
import '../services/data_access.dart';
import '../services/memory_providers.dart';
import '../services/utility_model.dart';
import '../plugin/plugin_host.dart';
import '../plugin/surface_controller.dart';
import '../plugin/app_keys.dart';
import 'app_providers.dart';

/// 已安装的演示插件（首次启动和版本迁移时增量安装）。
///
/// 这是构建包中的完整演示集合；新增插件时同步提高 [demoTemplateSetVersion]。
const List<String> demoTemplatePlugins = <String>[
  'assets/demo_plugins/time-plugin',
  'assets/demo_plugins/translate-button',
  'assets/demo_plugins/sakura-theme',
  'assets/demo_plugins/status-panel',
  'assets/demo_plugins/mini-game',
  'assets/demo_plugins/rock-paper-scissors',
  'assets/demo_plugins/gift-case',
];

const int demoTemplateSetVersion = 2;

/// 原语注册表。
///
/// 现在实现的是 `demoPrimitiveHandlers` 里那 7 个（sys.time / ui.toast /
/// fs.read / model.chat / primitive.list / hook.phases / host.capabilities）。
/// 其余 105 个已注册未实现 —— 插件调它们会拿到 `NOT_IMPLEMENTED`，
/// 这是**如实报错**，不是假装成功。
/// 当前打开的对话（插件 `chat.*` 用）。
///
/// 聊天页进入/退出时改它。**必须是单例** —— 每次 read 都新建的话，
/// 聊天页设的是 A、原语读的是 B，插件永远拿不到当前对话。
final chatContextProvider = Provider<AppChatContext>(
  (ref) => AppChatContext(repos: ref.watch(reposProvider.future)),
);

final surfaceControllerProvider = Provider<PluginSurfaceController>((ref) =>
    PluginSurfaceController(navigatorKey: appNavigatorKey));

/// 记忆实现的注册表。
///
/// **这是外部记忆插件将来接入的那个入口。** 插件实现 MemoryProvider 后，
/// 往这里 register 一下，AgentContextBuilder 与 memory.* 原语就会按
/// `agent.memory.providerPluginId` 找到它 —— 上层一行不用改。
///
/// 内置实现永远在（兜底），插件摘掉时自动退回它。
final memoryRegistryProvider = Provider<MemoryProviderRegistry>((ref) {
  return MemoryProviderRegistry(
    builtin: BuiltinMemoryProvider(ref.watch(reposProvider.future)),
    audit: ref.watch(auditSinkProvider),
  );
});

/// 插件的智能体状态（心情、看法…）。
///
/// **单独做成 provider 而不是塞在服务表里** —— 界面要 watch 它。
/// 服务表是命令式的（按类型 get），Riverpod 观察不到它的变化；
/// 而"插件改了状态 → 面板要重画"这件事必须有响应式通道。
final agentStateProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, pluginId) async {
  final service = ref.watch(agentStateServiceProvider);
  try {
    return await service.getState(pluginId);
  } catch (_) {
    // 没有当前智能体时返回空表，界面显示"读取中…"而不是崩
    return <String, dynamic>{};
  }
});

/// 智能体状态服务的单例。
final Provider<AppAgentState> agentStateServiceProvider = Provider<AppAgentState>((ref) {
  return AppAgentState(
    repos: ref.watch(reposProvider.future),
    chat: ref.watch(chatContextProvider),
    utility: ref.watch(utilityModelServiceProvider),
    agentGateway: (agentId) => ref.read(gatewayForAgentProvider(agentId)),
    surfaceController: ref.watch(surfaceControllerProvider),
    // 插件改状态 → 让对应的 provider 失效 → 面板重画
    onChanged: (pluginId) => ref.invalidate(agentStateProvider(pluginId)),
  );
});

/// 钩子总线。
///
/// **dispatcher 用 `ref.read` 延迟解析 PluginHost** ——
/// 钩子是在用户操作发生时才跑的，不在 provider build 时求值，
/// 所以不会和 pluginHostProvider 形成循环依赖。
///
/// 这是钩子从「留了相位」变成「真的能拦截」的那一步：
/// 没有这个 dispatcher，插件注册的钩子永远收不到调用。
final Provider<HookBus> hookBusProvider = Provider<HookBus>((ref) {
  return HookBus(
    audit: ref.watch(auditSinkProvider),
    dispatcher: (registration, context) async {
      final host = ref.read(pluginHostValueProvider);
      if (host == null) return null;
      return host.invokeHook(
        registration.pluginId,
        registration.phase.name,
        // 把整个 vars 交给插件 —— 里面按相位放着 messageOp / 工具参数等。
        // 壳层的 HookContext（systemPrompt / messages）不进 JSON：
        // 那些是可变的 Dart 对象，序列化过去插件也改不回来。
        Map<String, dynamic>.from(context.vars),
      );
    },
  );
});

final Provider<PrimitiveRegistry> primitiveRegistryProvider = Provider<PrimitiveRegistry>((ref) {
  // 先建一个**可变的服务表**，再把它交给注册表 ——
  // `primitive.list` / `host.capabilities` 要自省 PrimitiveRegistry 本身，
  // 所以必须先有注册表才能把它塞进服务表。共享一个可变表绕开这个循环。
  final services = ServiceRegistry();

  final registry = PrimitiveRegistry(
    gatekeeper: ref.watch(gatekeeperProvider),
    services: services,
  );
  registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));

  // **这一步以前完全缺失。**
  //
  // 内核把宿主能力设计成「按类型注入的服务」，但宿主一个都没注入，
  // 于是所有需要宿主服务的原语（sys.time / ui.toast / fs.read / model.chat）
  // 必然抛「宿主未注入服务 X」。
  // 表现是：插件跑起来了、工具也调到了，一执行就报错。
  services
    ..put<HostClock>(const AppHostClock())
    ..put<HostUi>(const AppHostUi())
    ..put<PrimitiveRegistry>(registry)
    ..put<HookBus>(ref.watch(hookBusProvider))
    ..put<HostChatContext>(ref.watch(chatContextProvider))
    ..put<HostAgentState>(ref.watch(agentStateServiceProvider))
    ..put<HostPluginConfig>(AppPluginConfig(repos: ref.watch(reposProvider.future)))
    // 数据访问：SQL 由内核编译（可脱离数据库穷尽单测），宿主只负责执行
    // 插件自己的键值存储（按 pluginId 分区）
    ..put<HostPluginState>(AppPluginState(ref.watch(reposProvider.future)))
    // 原生窗口：插件描述界面，宿主用 Flutter 画（自动套主题）
    ..put<HostNativeWindow>(AppNativeWindow(
      navigatorKey: appNavigatorKey,
      dispatchEvent: (pluginId, event, payload) =>
          ref.read(pluginHostValueProvider)?.dispatchUiEvent(pluginId, event, payload: payload) ?? false,
    ))
    ..put<HostDataAccess>(AppDataAccess(
      repos: ref.watch(reposProvider.future),
      chat: ref.watch(chatContextProvider),
    ));

  // model.chat 用的模型网关。
  //
  // 用**工具模型**而不是当前智能体的模型：插件调 model.chat 做的是
  // 翻译、摘要这类副任务，而工具模型正是为这类任务准备的（便宜、够快）。
  // 顺带也避免了"插件偷偷用用户主聊天那个贵模型"的问题。
  final utilityGateway = ref.watch(utilityGatewayProvider);
  if (utilityGateway != null) {
    services.put<ModelGateway>(utilityGateway);
  }

  return registry;
});

/// 审计日志（内存，界面上能看到最近的插件活动）。
final auditSinkProvider = Provider<AuditSink>((ref) => MemoryAuditSink());

/// 插槽注册表。
///
/// **必须是单例** —— 界面渲染时查的是它，
/// 如果界面拿的是另一个实例，插件 UI 永远显示不出来。
final slotRegistryProvider = Provider<SlotRegistry>((ref) => SlotRegistry());
final surfaceRegistryProvider = Provider<SurfaceRegistry>((ref) => SurfaceRegistry());

/// 插件状态版本号。
///
/// 插槽 UI watch 它：插件启停 / 安装 / 卸载时 `PluginHost` 会
/// `notifyListeners()`，这里把计数加一，界面就重建。
///
/// **不用 `invalidateSelf`** —— 那会把整个宿主重建掉，
/// WebView 也跟着重建，插件会被重启。只是让界面重画就够了。
final pluginHostRevisionProvider = StateProvider<int>((ref) => 0);

/// 插件宿主。
final FutureProvider<PluginHost> pluginHostProvider = FutureProvider<PluginHost>((ref) async {
  // 显式 watch，保证工具表 / 门禁 / 原语注册表 / 插槽表都是同一组实例，
  // 且在宿主存活期间不被回收
  final tools = ref.watch(toolRegistryProvider);
  final gatekeeper = ref.watch(gatekeeperProvider);
  final primitives = ref.watch(primitiveRegistryProvider);
  final slots = ref.watch(slotRegistryProvider);
  final surfaces = ref.watch(surfaceRegistryProvider);
  final audit = ref.watch(auditSinkProvider);

  final host = PluginHost(
    toolRegistry: tools,
    gatekeeper: gatekeeper,
    primitiveRegistry: primitives,
    slotRegistry: slots,
    surfaceRegistry: surfaces,
    audit: audit,
    // 传仓储进去，启停状态才能持久化 ——
    // 否则每次重启都从清单的 autoStart 重读，用户关掉的插件会自己回来
    settings: await ref.watch(reposProvider.future).then((r) => r.settings),
  );
  ref.onDispose(host.dispose);

  final revision = ref.read(pluginHostRevisionProvider.notifier);
  void bump() => revision.state = revision.state + 1;
  host.addListener(bump);
  ref.onDispose(() => host.removeListener(bump));

  await host.initialize();
  ref.read(surfaceControllerProvider).attachHost(host);
  await _installDemoPluginsIfFirstRun(ref, host);

  return host;
});

/// 首次启动装演示插件。
///
/// 用 settings 表记一个标记而不是"看目录空不空"：
/// 用户主动卸光了插件时，不该下次启动又给他装回来。
Future<void> _installDemoPluginsIfFirstRun(Ref ref, PluginHost host) async {
  final repos = await ref.read(reposProvider.future);
  final previousVersion = int.tryParse(
        await repos.settings.get('demoPluginsSetVersion') ?? '',
      ) ?? 0;
  if (previousVersion < demoTemplateSetVersion) {
    // 新增演示插件时，旧版本的 suppressed 状态不能阻止首次补装。
    await repos.settings.set('demoPluginsSetVersion', '$demoTemplateSetVersion');
    await repos.settings.set('plugin.demo.suppressed.dev.tsukiro.rock-paper-scissors', '0');
  }
  var installedAny = false;
  for (final assetDir in demoTemplatePlugins) {
    try {
      installedAny = await host.ensureFromAssets(assetDir) || installedAny;
    } catch (e) {
      // 单个插件装不上不该影响其他插件，也不该拦住 App 启动；
      // 同时保留失败原因，插件页可以显示具体问题并支持重试。
      host.installErrors[assetDir] = '$e';
      debugPrint('[plugin] 增量安装演示插件 $assetDir 失败：$e');
    }
  }
  if (installedAny || await repos.settings.get('demoPluginsInstalled') != '1') {
    await repos.settings.set('demoPluginsInstalled', '1');
  }
}

/// 已经就绪的插件宿主（界面用）。
final pluginHostValueProvider = Provider<PluginHost?>(
  (ref) => ref.watch(pluginHostProvider).valueOrNull,
);
