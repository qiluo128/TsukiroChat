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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';

import '../plugin/host_services_impl.dart';
import '../services/utility_model.dart';
import '../plugin/plugin_host.dart';
import 'app_providers.dart';

/// 已安装的演示插件（首次启动自动装）。
///
/// 只带三个轻量的：时间插件（演示工具调用）、翻译按钮（演示 UI 插槽）、
/// 樱花主题（演示零代码插件）。mini-game 太大且需要更多原语，先不装。
const List<String> demoTemplatePlugins = <String>[
  'assets/demo_plugins/time-plugin',
  'assets/demo_plugins/translate-button',
  'assets/demo_plugins/sakura-theme',
  'assets/demo_plugins/status-panel',
];

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

final primitiveRegistryProvider = Provider<PrimitiveRegistry>((ref) {
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
    ..put<HostPluginConfig>(AppPluginConfig(repos: ref.watch(reposProvider.future)));

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

/// 插件状态版本号。
///
/// 插槽 UI watch 它：插件启停 / 安装 / 卸载时 `PluginHost` 会
/// `notifyListeners()`，这里把计数加一，界面就重建。
///
/// **不用 `invalidateSelf`** —— 那会把整个宿主重建掉，
/// WebView 也跟着重建，插件会被重启。只是让界面重画就够了。
final pluginHostRevisionProvider = StateProvider<int>((ref) => 0);

/// 插件宿主。
final pluginHostProvider = FutureProvider<PluginHost>((ref) async {
  // 显式 watch，保证工具表 / 门禁 / 原语注册表 / 插槽表都是同一组实例，
  // 且在宿主存活期间不被回收
  final tools = ref.watch(toolRegistryProvider);
  final gatekeeper = ref.watch(gatekeeperProvider);
  final primitives = ref.watch(primitiveRegistryProvider);
  final slots = ref.watch(slotRegistryProvider);
  final audit = ref.watch(auditSinkProvider);

  final host = PluginHost(
    toolRegistry: tools,
    gatekeeper: gatekeeper,
    primitiveRegistry: primitives,
    slotRegistry: slots,
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
  await _installDemoPluginsIfFirstRun(ref, host);

  return host;
});

/// 首次启动装演示插件。
///
/// 用 settings 表记一个标记而不是"看目录空不空"：
/// 用户主动卸光了插件时，不该下次启动又给他装回来。
Future<void> _installDemoPluginsIfFirstRun(Ref ref, PluginHost host) async {
  final repos = await ref.read(reposProvider.future);
  if (await repos.settings.get('demoPluginsInstalled') == '1') return;

  for (final assetDir in demoTemplatePlugins) {
    try {
      await host.installFromAssets(assetDir);
    } catch (e) {
      // 单个插件装不上不该影响其他插件，也不该拦住 App 启动
      // ignore: avoid_print
      print('[plugin] 安装演示插件 $assetDir 失败：$e');
    }
  }
  await repos.settings.set('demoPluginsInstalled', '1');
}

/// 已经就绪的插件宿主（界面用）。
final pluginHostValueProvider = Provider<PluginHost?>(
  (ref) => ref.watch(pluginHostProvider).valueOrNull,
);
