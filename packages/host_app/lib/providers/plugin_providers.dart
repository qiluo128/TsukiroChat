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
];

/// 原语注册表。
///
/// 现在实现的是 `demoPrimitiveHandlers` 里那 7 个（sys.time / ui.toast /
/// fs.read / model.chat / primitive.list / hook.phases / host.capabilities）。
/// 其余 105 个已注册未实现 —— 插件调它们会拿到 `NOT_IMPLEMENTED`，
/// 这是**如实报错**，不是假装成功。
final primitiveRegistryProvider = Provider<PrimitiveRegistry>((ref) {
  // 原语注册表要持门禁 —— 每个原语调用都要过它。
  // 用 ref.watch 而不是每次 new：**门禁必须是同一实例**，
  // 否则插件注册在这一个、原语查的是另一个，调用会被"未注册"拒掉。
  final registry = PrimitiveRegistry(gatekeeper: ref.watch(gatekeeperProvider));
  registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
  return registry;
});

/// 审计日志（内存，界面上能看到最近的插件活动）。
final auditSinkProvider = Provider<AuditSink>((ref) => MemoryAuditSink());

/// 插件宿主。
final pluginHostProvider = FutureProvider<PluginHost>((ref) async {
  // 显式 watch，保证工具表 / 门禁 / 原语注册表都是同一组实例，
  // 且在宿主存活期间不被回收
  final tools = ref.watch(toolRegistryProvider);
  final gatekeeper = ref.watch(gatekeeperProvider);
  final primitives = ref.watch(primitiveRegistryProvider);
  final audit = ref.watch(auditSinkProvider);

  final host = PluginHost(
    toolRegistry: tools,
    gatekeeper: gatekeeper,
    primitiveRegistry: primitives,
    audit: audit,
  );
  ref.onDispose(host.dispose);

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
