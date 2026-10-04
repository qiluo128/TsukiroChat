/// 插件宿主：安装、启停、把插件的工具接进工具循环。
///
/// 这是"插件"从磁盘上的一堆文件变成**能用的能力**的地方。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:plugin_core/plugin_core.dart';

import 'plugin_bundle.dart';
import 'plugin_runtime.dart';

/// 一个已安装的插件。
class InstalledPlugin {
  InstalledPlugin({
    required this.manifest,
    required this.directory,
    this.enabled = true,
    this.autoStart = true,
    this.installedAt,
  });

  final PluginManifest manifest;
  final String directory;
  bool enabled;
  bool autoStart;
  DateTime? installedAt;

  PluginRuntime? runtime;

  String get id => manifest.id;
  String get name => manifest.name;
  String get version => manifest.version;

  RuntimeState get state => runtime?.state ?? RuntimeState.created;
  bool get isReady => runtime?.isReady ?? false;

  List<ToolDeclaration> get tools => manifest.provides.tools;
}

/// 插件宿主。
///
/// **一个实例管全部插件**。它负责：
///   - 扫描已安装目录
///   - 把插件的声明注册进工具表与权限门禁
///   - 创建/销毁 WebView 运行时
///   - 把工具调用路由到对应插件
///
/// 不做的事：不决定 UI 怎么展示（那是插件管理页的事），
/// 也不缓存运行时状态（状态就在 [InstalledPlugin] 上）。
class PluginHost extends ChangeNotifier {
  PluginHost({
    required this.toolRegistry,
    required this.gatekeeper,
    required this.primitiveRegistry,
    required this.audit,
    SlotRegistry? slotRegistry,
  }) : slotRegistry = slotRegistry ?? SlotRegistry();

  final ToolRegistry toolRegistry;
  final Gatekeeper gatekeeper;
  final PrimitiveRegistry primitiveRegistry;
  final AuditSink audit;

  /// 插槽注册表。**和工具表一样，必须是调用方传进来的那一份** ——
  /// 界面渲染时查的是它，如果这里 new 一个新的，界面上永远看不到插件 UI。
  final SlotRegistry slotRegistry;

  final List<InstalledPlugin> _plugins = <InstalledPlugin>[];
  String? _rootDir;
  bool _initialized = false;

  List<InstalledPlugin> get plugins => List<InstalledPlugin>.unmodifiable(_plugins);

  bool get isInitialized => _initialized;

  /// 已就绪的插件数 —— 界面上显示"3 个插件运行中"用。
  int get runningCount => _plugins.where((x) => x.isReady).length;

  // ─────────────────────────── 初始化 ───────────────────────────

  /// 扫描已安装插件并启动自动启动的那些。
  Future<void> initialize() async {
    if (_initialized) return;
    final docs = await getApplicationDocumentsDirectory();
    _rootDir = p.join(docs.path, 'plugins');
    await Directory(_rootDir!).create(recursive: true);

    await _scan();
    _initialized = true;
    notifyListeners();

    // 自动启动是**后台**的：插件起不来不该拖住 App 启动
    unawaited(startAutoStartPlugins());
  }

  Future<void> _scan() async {
    _plugins.clear();
    final root = Directory(_rootDir!);
    if (!root.existsSync()) return;

    for (final entry in root.listSync().whereType<Directory>()) {
      final manifestFile = File(p.join(entry.path, 'manifest.json'));
      if (!manifestFile.existsSync()) continue;
      try {
        final parsed = parseManifestJson(await manifestFile.readAsString());
        if (!parsed.isValid) {
          debugPrint('[plugin] ${entry.path} 清单不合法：${parsed.issues.join('；')}');
          continue;
        }
        final manifest = parsed.manifest!;
        _plugins.add(InstalledPlugin(
          manifest: manifest,
          directory: entry.path,
          enabled: manifest.runtime?.autoStart ?? true,
          autoStart: manifest.runtime?.autoStart ?? true,
          installedAt: manifestFile.lastModifiedSync(),
        ));
      } catch (e) {
        debugPrint('[plugin] 读 ${entry.path} 失败：$e');
      }
    }

    // 注册声明（工具表 + 权限门禁）。
    // 放在扫描阶段而不是启动阶段：**即使用户选了不自动启动**，
    // 他的工具也应当出现在能力列表里，否则界面上会显得插件"没装上"。
    for (final plugin in _plugins) {
      _registerDeclarations(plugin);
    }
  }

  void _registerDeclarations(InstalledPlugin plugin) {
    gatekeeper.registerPlugin(
      plugin.id,
      plugin.manifest.permissions.map((d) => d.name),
    );
    // 安装即授权：Demo 阶段不做逐项确认流程。
    // 正式版这里应当改成"先问用户，再 grantAll"——
    // 但**声明即上限**这条约束不受影响，插件仍然调不到没声明的东西。
    gatekeeper.grantAll(
      plugin.id,
      plugin.manifest.permissions.map((d) => d.name),
    );

    final conflicts = toolRegistry.registerPlugin(plugin.manifest);
    if (conflicts.isNotEmpty) {
      debugPrint('[plugin] ${plugin.id} 有工具名冲突：'
          '${conflicts.map((c) => c.requested).join(', ')}');
    }

    // 插槽：未知插槽**不报错也不注册**（只记一条日志）。
    // 这是刻意的 —— 未知插槽静默忽略，插件往新版宿主才有的插槽放东西时，
    // 在旧宿主上只是不显示，而不是装都装不上。
    final unknownSlots = slotRegistry.registerPlugin(plugin.manifest);
    if (unknownSlots.isNotEmpty) {
      debugPrint('[plugin] ${plugin.id} 用了未知插槽：${unknownSlots.join(', ')}'
          '（已忽略，不影响其他功能）');
    }
  }

  // ─────────────────────────── 插槽 ───────────────────────────

  /// 某个插槽里当前应该显示什么。
  ///
  /// [context] 是渲染上下文（如 `{hasMessages: true, isStreaming: false}`），
  /// 用来求值声明里的 `when`。
  ///
  /// 三层过滤，缺一不可：
  ///   1. 插件必须是启用且已加载的 —— 停用的插件不该还占着界面
  ///   2. 声明上要求的权限必须是插件已经拿到的
  ///   3. `when` 条件必须成立
  List<RegisteredUi> visibleUi(String slot, {Map<String, dynamic> context = const {}}) {
    final enabledIds = _plugins.where((x) => x.enabled).map((x) => x.id).toSet();
    final granted = <String, Set<String>>{
      for (final p in _plugins) p.id: gatekeeper.grantedOf(p.id),
    };

    return slotRegistry.uiIn(slot).where((ui) {
      if (!enabledIds.contains(ui.pluginId)) return false;

      // 权限：声明里要求了但没拿到 → 不显示。
      // 显示出来再让点击失败是更糟的体验（用户以为能用）。
      final need = ui.declaration.permissions;
      if (need.isNotEmpty) {
        final have = granted[ui.pluginId] ?? const <String>{};
        for (final p in need) {
          if (!have.contains(p)) return false;
        }
      }

      return _matchesWhen(ui.declaration.when, context);
    }).toList(growable: false);
  }

  /// 求值 `when`：键值相等比较，没有表达式语言。
  ///
  /// 没有表达式语言是**刻意的** —— 有表达式就要有解析器和沙箱，
  /// 而声明式 UI 的价值就在于宿主能完全掌控它渲染什么。
  static bool _matchesWhen(Map<String, dynamic>? when, Map<String, dynamic> context) {
    if (when == null || when.isEmpty) return true;
    for (final entry in when.entries) {
      if (context[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 把界面事件发给插件。
  ///
  /// 走 `evt`（宿主→插件单向），对应插件侧的 `tsukiro.event.on(name, fn)`。
  /// 返回 false 表示插件没在跑 —— 界面据此给用户一个明确反馈，
  /// 而不是点下去毫无反应。
  bool dispatchUiEvent(
    String pluginId,
    String event, {
    Map<String, dynamic>? payload,
  }) {
    final plugin = _find(pluginId);
    final runtime = plugin?.runtime;
    if (runtime == null || !runtime.isReady) {
      debugPrint('[plugin] $pluginId 未运行，事件 $event 丢弃');
      return false;
    }
    return runtime.sendEvent(event, <String, dynamic>{
      'pluginId': pluginId,
      ...?payload,
    });
  }

  // ─────────────────────────── 启停 ───────────────────────────

  Future<void> startAutoStartPlugins() async {
    for (final plugin in List<InstalledPlugin>.from(_plugins)) {
      if (plugin.enabled && plugin.autoStart) {
        await _startOne(plugin);
      }
    }
    notifyListeners();
  }

  Future<void> _startOne(InstalledPlugin plugin) async {
    if (plugin.runtime != null && plugin.runtime!.isReady) return;

    // 零代码插件没有 JS 可跑 —— 它们的价值在声明（主题/人设），
    // 由对应的注册表消费，不需要 WebView。
    if (plugin.manifest.isZeroCode) {
      debugPrint('[plugin] ${plugin.id} 是零代码插件，跳过运行时');
      return;
    }

    try {
      final bundle = await loadBundleFromDirectory(plugin.directory);
      final runtime = WebViewPluginRuntime(
        bundle: bundle,
        registry: primitiveRegistry,
        gatekeeper: gatekeeper,
        audit: audit,
      );
      plugin.runtime = runtime;
      // 注意：这里只创建运行时并配好 WebView。
      // **真正的加载发生在 WebView 首次挂到树上时** —— Android 平台视图
      // 需要 attach 才能跑 JS，所以 start() 由 PluginHostView 触发。
      notifyListeners();
    } catch (e) {
      debugPrint('[plugin] 启动 ${plugin.id} 失败：$e');
    }
  }

  /// 由 [PluginHostView] 在 WebView attach 之后调用。
  Future<void> attachRuntime(InstalledPlugin plugin) async {
    final runtime = plugin.runtime;
    if (runtime == null || runtime.isReady) return;
    try {
      await runtime.start();
      notifyListeners();
    } catch (e) {
      debugPrint('[plugin] ${plugin.id} 握手失败：$e');
      notifyListeners();
    }
  }

  Future<void> setEnabled(String pluginId, bool enabled) async {
    final plugin = _find(pluginId);
    if (plugin == null) return;
    plugin.enabled = enabled;

    if (enabled) {
      await _startOne(plugin);
    } else {
      await plugin.runtime?.stop();
      plugin.runtime = null;
      // 停用时把工具与插槽都摘掉 —— 否则模型还能看到它的工具、
      // 界面还占着它的位置，点了却没人接
      toolRegistry.unregisterPlugin(pluginId);
      slotRegistry.unregisterPlugin(pluginId);
    }
    notifyListeners();
  }

  Future<void> stopAll() async {
    for (final plugin in _plugins) {
      await plugin.runtime?.stop();
    }
    notifyListeners();
  }

  // ─────────────────────────── 安装 / 卸载 ───────────────────────────

  /// 从内置资源安装（首次启动装演示插件）。
  ///
  /// 正式版会从 zip 装（`plugin_core` 的 [Installer] 已经做了原子提交与
  /// Zip Slip / 符号链接 / 原生二进制检查），但那需要文件选择器，
  /// 属于后续工作。这里先把「装完之后能跑」这条路打通。
  Future<InstalledPlugin> installFromAssets(String assetDir) async {
    final bundle = await loadBundleFromAssets(assetDir);
    final target = Directory(p.join(_rootDir!, bundle.manifest.id));

    // 先把全部内容读齐再落盘。
    // 写一半失败会留下一个装不上的残骸目录，而下次启动扫描时会把它
    // 当成一个「清单不合法」的插件 —— 用户看到的是"我装过但没了"。
    final manifestSource = await rootBundle.loadString('$assetDir/manifest.json');
    final entryMain = bundle.manifest.runtime?.main;

    await target.create(recursive: true);
    await File(p.join(target.path, 'manifest.json')).writeAsString(manifestSource);

    if (entryMain != null && bundle.entrySource.isNotEmpty) {
      final file = File(p.join(target.path, entryMain));
      await file.parent.create(recursive: true);
      await file.writeAsString(bundle.entrySource);
    }

    for (final entry in bundle.handlerSources.entries) {
      final file = File(p.join(target.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }

    await _scan();
    notifyListeners();

    final installed = _find(bundle.manifest.id);
    if (installed == null) {
      throw PluginLoadException('安装后扫描不到 ${bundle.manifest.id}');
    }
    return installed;
  }

  Future<void> uninstall(String pluginId) async {
    final plugin = _find(pluginId);
    if (plugin == null) return;
    await plugin.runtime?.stop();
    toolRegistry.unregisterPlugin(pluginId);
    gatekeeper.unregisterPlugin(pluginId);
    slotRegistry.unregisterPlugin(pluginId);

    final dir = Directory(plugin.directory);
    if (dir.existsSync()) await dir.delete(recursive: true);

    _plugins.removeWhere((x) => x.id == pluginId);
    notifyListeners();
  }

  // ─────────────────────────── 工具路由 ───────────────────────────

  /// 给 [AgentLoop] 用的 ToolInvoker。
  ///
  /// [handler] 是清单里的 handler 路径（`handlers/get_time.js`）——
  /// 插件侧就是按这个键注册的，所以直接透传，不做映射。
  Future<ToolInvocationResult> invokeTool(
    String pluginId,
    String handler,
    Map<String, dynamic> args,
  ) async {
    final plugin = _find(pluginId);
    if (plugin == null) {
      return ToolInvocationResult.failure('NO_PLUGIN', '插件 $pluginId 未安装');
    }
    final runtime = plugin.runtime;
    if (runtime == null) {
      return ToolInvocationResult.failure(
        'NOT_RUNNING',
        '插件 $pluginId 未运行（${plugin.enabled ? "正在启动" : "已被停用"}）',
      );
    }
    if (!runtime.isReady) {
      return ToolInvocationResult.failure(
        'NOT_READY',
        '插件 $pluginId 的运行时未就绪（state=${runtime.state.name}）',
      );
    }
    return runtime.invokeTool(handler, args);
  }

  InstalledPlugin? _find(String pluginId) {
    for (final p in _plugins) {
      if (p.id == pluginId) return p;
    }
    return null;
  }

  InstalledPlugin? byId(String pluginId) => _find(pluginId);

  @override
  void dispose() {
    for (final plugin in _plugins) {
      unawaited(plugin.runtime?.stop());
    }
    super.dispose();
  }
}

/// 承载插件 WebView 的控件。
///
/// **必须挂在树里**，因为 Android 的平台视图要先 attach 才会跑 JS。
/// 默认渲染成 1x1 的透明方块躲在角落 —— 插件在后台跑，
/// 界面上不该看得见它。
class PluginHostView extends StatefulWidget {
  const PluginHostView({super.key, required this.host});

  final PluginHost host;

  @override
  State<PluginHostView> createState() => _PluginHostViewState();
}

class _PluginHostViewState extends State<PluginHostView> {
  final Set<String> _started = <String>{};

  @override
  Widget build(BuildContext context) {
    final runtimes = widget.host.plugins
        .where((x) => x.runtime != null)
        .toList(growable: false);

    if (runtimes.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      width: 1,
      height: 1,
      child: Stack(
        children: <Widget>[
          for (final plugin in runtimes)
            SizedBox(
              width: 1,
              height: 1,
              child: _AttachedRuntime(
                key: ValueKey<String>(plugin.id),
                plugin: plugin,
                onAttached: () {
                  // 平台视图 attach 之后再启动，否则 JS 不会执行
                  if (_started.add(plugin.id)) {
                    unawaited(widget.host.attachRuntime(plugin));
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AttachedRuntime extends StatefulWidget {
  const _AttachedRuntime({super.key, required this.plugin, required this.onAttached});

  final InstalledPlugin plugin;
  final VoidCallback onAttached;

  @override
  State<_AttachedRuntime> createState() => _AttachedRuntimeState();
}

class _AttachedRuntimeState extends State<_AttachedRuntime> {
  @override
  void initState() {
    super.initState();
    // 等一帧，确保平台视图已经 attach
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onAttached());
  }

  @override
  Widget build(BuildContext context) =>
      widget.plugin.runtime?.buildView() ?? const SizedBox.shrink();
}
