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

import '../data/repositories.dart';
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

  /// 启动失败的原因。
  ///
  /// **单独记一份**，不从 runtime 上读 —— 加载阶段（读文件、解析清单、
  /// 转 ES module）失败时 runtime 压根没被创建，
  /// 而"为什么没起来"恰恰是用户最需要知道的。
  String? startupError;

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
    SurfaceRegistry? surfaceRegistry,
    CapabilityRegistry? capabilityRegistry,
    this.settings,
  })  : slotRegistry = slotRegistry ?? SlotRegistry(),
        surfaceRegistry = surfaceRegistry ?? SurfaceRegistry(),
        capabilityRegistry = capabilityRegistry ?? CapabilityRegistry();

  final ToolRegistry toolRegistry;
  final Gatekeeper gatekeeper;
  final PrimitiveRegistry primitiveRegistry;
  final AuditSink audit;

  /// 用来持久化启停状态。
  ///
  /// 为 null 时启停只影响本次运行 —— 测试里不需要数据库。
  final SettingsRepository? settings;

  /// 插槽注册表。**和工具表一样，必须是调用方传进来的那一份** ——
  /// 界面渲染时查的是它，如果这里 new 一个新的，界面上永远看不到插件 UI。
  final SlotRegistry slotRegistry;
  final SurfaceRegistry surfaceRegistry;

  /// 能力市场：别的插件提供的能力登记在这，供调用方查找。
  final CapabilityRegistry capabilityRegistry;

  HostAgentState? get agentState => primitiveRegistry.services.get<HostAgentState>();

  final List<InstalledPlugin> _plugins = <InstalledPlugin>[];
  final Map<String, Future<void>> _installTails = <String, Future<void>>{};
  String? _rootDir;
  bool _initialized = false;
  final Map<String, String> installErrors = <String, String>{};

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

    // 初始化阶段串行完成自动启动，避免后续演示插件增量安装同时清理/重建 runtime。
    await startAutoStartPlugins();
  }

  /// 指定插件根目录并扫描。
  ///
  /// [initialize] 固定用应用文档目录，测试里没法改 —— 这个入口
  /// 让测试能指向一个临时目录，从而覆盖"关掉之后重启会不会自己开回来"
  /// 这类只有跨实例才暴露的问题。
  Future<void> debugScanDirectory(String root) async {
    _rootDir = root;
    await Directory(root).create(recursive: true);
    await _scan();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _scan() async {
    // 扫描会重建 InstalledPlugin 对象；先停止并注销旧状态，避免旧 WebView、
    // 工具、插槽和权限继续挂在新扫描结果之外。
    await _clearRuntimeAndDeclarations();
    _plugins.clear();
    final root = Directory(_rootDir!);
    if (!root.existsSync()) return;

    for (final entry in root.listSync().whereType<Directory>()) {
      // 原子安装会在根目录短暂保留 .staging-* / .backup-* 目录；
      // 它们不是可运行插件，不能被扫描成第二份同 id 插件。
      if (p.basename(entry.path).startsWith('.')) continue;
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
          enabled: await _readEnabled(manifest),
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

  Future<void> _clearRuntimeAndDeclarations() async {
    for (final plugin in List<InstalledPlugin>.from(_plugins)) {
      await plugin.runtime?.stop();
      toolRegistry.unregisterPlugin(plugin.id);
      slotRegistry.unregisterPlugin(plugin.id);
      surfaceRegistry.unregisterPlugin(plugin.id);
      gatekeeper.unregisterPlugin(plugin.id);
    }
  }

  void _registerDeclarations(InstalledPlugin plugin) {
    gatekeeper.registerPlugin(
      plugin.id,
      plugin.manifest.permissions.map((d) => d.name),
    );
    // 安装即授权：Demo 阶段不做逐项确认流程；已停用插件不授予权限。
    // 正式版这里应当改成"先问用户，再 grantAll"——
    // 但**声明即上限**这条约束不受影响，插件仍然调不到没声明的东西。
    if (plugin.enabled) {
      gatekeeper.grantAll(
        plugin.id,
        plugin.manifest.permissions.map((d) => d.name),
      );
    }

    final conflicts = toolRegistry.registerPlugin(plugin.manifest);
    if (conflicts.isNotEmpty) {
      debugPrint('[plugin] ${plugin.id} 有工具名冲突：'
          '${conflicts.map((c) => c.requested).join(', ')}');
    }

    // 插槽：未知插槽**不报错也不注册**（只记一条日志）。
    // 这是刻意的 —— 未知插槽静默忽略，插件往新版宿主才有的插槽放东西时，
    // 在旧宿主上只是不显示，而不是装都装不上。
    // 能力市场：把插件提供的能力登记进去，别的插件才找得到
    capabilityRegistry.registerProvider(
      plugin.id,
      providerVersion: plugin.manifest.version,
      providerName: plugin.manifest.name,
      declarations: plugin.manifest.provides.capabilities,
    );

    final unknownSlots = slotRegistry.registerPlugin(plugin.manifest);
    surfaceRegistry.registerPlugin(plugin.manifest);
    if (unknownSlots.isNotEmpty) {
      debugPrint('[plugin] ${plugin.id} 用了未知插槽：${unknownSlots.join(', ')}'
          '（已忽略，不影响其他功能）');
    }
  }

  // ─────────────────────────── 主题 ───────────────────────────

  /// 已启用插件声明的全部主题（L1 美化包）。
  ///
  /// **宿主不预设哪个生效** —— 由界面根据用户的主题选择决定。
  /// 这个入口只负责把「有哪些可选」汇总出来。
  ///
  /// 之前完全缺这一步，所以 `appTokensProvider` 永远返回宿主默认值，
  /// 美化包装了也看不出任何变化（正是用户反馈的「主题插件无效果」）。
  List<ThemeDeclaration> availableThemes() => <ThemeDeclaration>[
        for (final p in _plugins)
          if (p.enabled) ...p.manifest.provides.themes,
      ];

  /// 按 id 找主题声明。
  ThemeDeclaration? themeById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final t in availableThemes()) {
      if (t.id == id) return t;
    }
    return null;
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

  // ─────────────────────────── 启停状态的持久化 ───────────────────────────

  String _enabledKey(String pluginId) => 'plugin.enabled.$pluginId';

  /// 读持久化的启停状态；没记过就按清单里的 `autoStart`。
  Future<bool> _readEnabled(PluginManifest manifest) async {
    final raw = await settings?.get(_enabledKey(manifest.id));
    if (raw == null) return manifest.runtime?.autoStart ?? true;
    return raw == '1';
  }

  Future<void> _writeEnabled(String pluginId, bool enabled) async {
    // 写失败不该让开关卡住 —— 内存里的状态已经改了，
    // 顶多下次启动回到默认值。为这个报错反而更烦人。
    await settings?.set(_enabledKey(pluginId), enabled ? '1' : '0');
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
      plugin.startupError = null;
      // 注意：这里只创建运行时并配好 WebView。
      // **真正的加载发生在 WebView 首次挂到树上时** —— Android 平台视图
      // 需要 attach 才能跑 JS，所以 start() 由 PluginHostView 触发。
      notifyListeners();
    } catch (e) {
      // **不能只 debugPrint。** 插件起不来时用户只能看到"未启动"三个字，
      // 而原因（文件缺失 / 清单不合法 / ES module 里有 import）全被吞掉了。
      plugin.startupError = '$e';
      debugPrint('[plugin] 启动 ${plugin.id} 失败：$e');
      notifyListeners();
    }
  }

  /// 手动启动一个插件（失败后可重试）。
  Future<void> startNow(String pluginId) async {
    final plugin = _find(pluginId);
    if (plugin == null) return;
    plugin.enabled = true;
    await _writeEnabled(pluginId, true);

    // 已经有 runtime 但没起来（比如之前超时）→ 重建一个，
    // 否则会复用那个已经 failed 的状态，怎么点都不动
    if (plugin.runtime != null && !plugin.runtime!.isReady) {
      await plugin.runtime?.stop();
      plugin.runtime = null;
    }

    plugin.startupError = null;
    await _startOne(plugin);
    notifyListeners();
  }

  /// 由 [PluginHostView] 在 WebView attach 之后调用。
  ///
  /// 返回前会把状态落到 [InstalledPlugin.startupError]，
  /// 让界面能显示"为什么没起来"。
  Future<void> attachRuntime(InstalledPlugin plugin) async {
    final runtime = plugin.runtime;
    if (runtime == null || runtime.isReady) return;
    try {
      await runtime.start();
      plugin.startupError = null;
      notifyListeners();
    } catch (e) {
      plugin.startupError = '${runtime.failureReason ?? e}';
      debugPrint('[plugin] ${plugin.id} 握手失败：$e');
      notifyListeners();
    }
  }

  Future<void> setEnabled(String pluginId, bool enabled) async {
    final plugin = _find(pluginId);
    if (plugin == null) return;
    plugin.enabled = enabled;
    await _writeEnabled(pluginId, enabled);

    if (enabled) {
      // 停用时声明已被摘掉，重新启用必须完整注册权限、工具、插槽和 Surface。
      _registerDeclarations(plugin);
      await _startOne(plugin);
    } else {
      await plugin.runtime?.stop();
      plugin.runtime = null;
      // 停用时把权限、工具与插槽都摘掉 —— 否则模型还能看到它的工具、
      // 界面还占着它的位置，点了却没人接。
      toolRegistry.unregisterPlugin(pluginId);
      slotRegistry.unregisterPlugin(pluginId);
      surfaceRegistry.unregisterPlugin(pluginId);
      gatekeeper.unregisterPlugin(pluginId);
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

  /// 确保某个内置演示插件已安装；已有插件不会被覆盖。
  ///
  /// 这是增量安装入口：旧版本已经写过 demoPluginsInstalled 标记时，
  /// 新增的演示插件仍然可以被补装。
  Future<bool> ensureFromAssets(String assetDir) async {
    final bundle = await loadBundleFromAssets(assetDir);
    final id = bundle.manifest.id;
    if (_find(id) != null) return false;
    if (await settings?.get('plugin.demo.suppressed.$id') == '1') return false;
    await installFromAssets(assetDir);
    return true;
  }

  /// 从内置资源安装（首次启动装演示插件）。
  ///
  /// 正式版会从 zip 装（`plugin_core` 的 [Installer] 已经做了原子提交与
  /// Zip Slip / 符号链接 / 原生二进制检查），但那需要文件选择器，
  /// 属于后续工作。这里先把「装完之后能跑」这条路打通。
  Future<InstalledPlugin> installFromAssets(String assetDir) async {
    final bundle = await loadBundleFromAssets(assetDir);
    // 手动重装代表用户明确要求恢复演示插件。
    await settings?.set('plugin.demo.suppressed.${bundle.manifest.id}', '0');
    await settings?.set('plugin.enabled.${bundle.manifest.id}', '1');
    return _withInstallLock(bundle.manifest.id, () async {
      final id = bundle.manifest.id;
      final root = Directory(_rootDir!);
      final target = Directory(p.join(root.path, id));
      final staging = Directory(p.join(
        root.path,
        '.${id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.staging-${DateTime.now().microsecondsSinceEpoch}',
      ));
      final backup = Directory(p.join(
        root.path,
        '.${id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.backup-${DateTime.now().microsecondsSinceEpoch}',
      ));
      final runningIds = _plugins.where((plugin) => plugin.isReady).map((plugin) => plugin.id).toSet();
      var oldMoved = false;
      var newMoved = false;
      var restored = false;

      try {
        await _writeBundleToDirectory(assetDir, bundle, staging);

        // 先停止并注销旧实例，再替换目录。旧 WebView 不能继续持有旧清单，
        // 否则新扫描结果和旧 runtime 会分裂成两个版本。
        await _clearRuntimeAndDeclarations();

        if (target.existsSync()) {
          await target.rename(backup.path);
          oldMoved = true;
        }
        await staging.rename(target.path);
        newMoved = true;

        await _scan();
        final installed = _find(id);
        if (installed == null) {
          throw PluginLoadException('安装后扫描不到 $id');
        }
        await _startConfiguredPlugins(runningIds);

        if (backup.existsSync()) await backup.delete(recursive: true);
        notifyListeners();
        return installed;
      } catch (error) {
        // 新目录或注册失败时恢复旧目录；恢复后重新注册并启动原来正在运行的插件。
        try {
          if (newMoved && target.existsSync()) await target.delete(recursive: true);
          if (oldMoved && backup.existsSync()) {
            await backup.rename(target.path);
            restored = true;
          }
          await _scan();
          await _startConfiguredPlugins(runningIds);
          notifyListeners();
        } catch (restoreError) {
          debugPrint('[plugin] 恢复 $id 失败：$restoreError');
        }
        rethrow;
      } finally {
        if (staging.existsSync()) await staging.delete(recursive: true);
        // 恢复失败时保留 backup，避免新目录和旧版本都丢失。
        if (backup.existsSync() && (newMoved || restored)) {
          await backup.delete(recursive: true);
        }
      }
    });
  }

  Future<T> _withInstallLock<T>(String pluginId, Future<T> Function() action) async {
    final previous = _installTails[pluginId] ?? Future<void>.value();
    final gate = Completer<void>();
    _installTails[pluginId] = gate.future;
    try {
      await previous;
      return await action();
    } finally {
      gate.complete();
      if (identical(_installTails[pluginId], gate.future)) {
        _installTails.remove(pluginId);
      }
    }
  }

  Future<void> _writeBundleToDirectory(
    String assetDir,
    PluginBundle bundle,
    Directory target,
  ) async {
    await target.create(recursive: true);
    final manifestSource = await rootBundle.loadString('$assetDir/manifest.json');
    await File(p.join(target.path, 'manifest.json')).writeAsString(manifestSource);

    final entryMain = bundle.manifest.runtime?.main;
    if (entryMain != null && bundle.entrySource.isNotEmpty) {
      final file = File(p.join(target.path, entryMain));
      await file.parent.create(recursive: true);
      await file.writeAsString(bundle.entrySource);
    }
    for (final entry in <String, String>{
      ...bundle.handlerSources,
      ...bundle.pageSources,
    }.entries) {
      final normalized = p.normalize(entry.key);
      if (normalized.startsWith('..') || p.isAbsolute(normalized)) {
        throw PluginLoadException('插件资源路径非法：${entry.key}');
      }
      final file = File(p.join(target.path, normalized));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
  }

  Future<void> _startConfiguredPlugins(Set<String> previouslyRunning) async {
    for (final plugin in List<InstalledPlugin>.from(_plugins)) {
      if (!plugin.enabled) continue;
      if (plugin.autoStart || previouslyRunning.contains(plugin.id)) {
        await _startOne(plugin);
      }
    }
  }

  Future<void> uninstall(String pluginId) async {
    final plugin = _find(pluginId);
    if (plugin == null) return;
    await plugin.runtime?.stop();
    toolRegistry.unregisterPlugin(pluginId);
    gatekeeper.unregisterPlugin(pluginId);
    slotRegistry.unregisterPlugin(pluginId);
    surfaceRegistry.unregisterPlugin(pluginId);

    final dir = Directory(plugin.directory);
    if (dir.existsSync()) await dir.delete(recursive: true);

    _plugins.removeWhere((x) => x.id == pluginId);
    await settings?.set('plugin.demo.suppressed.$pluginId', '1');
    notifyListeners();
  }

  // ─────────────────────────── 工具路由 ───────────────────────────

  /// 给 [AgentLoop] 用的 ToolInvoker。
  ///
  /// [handler] 是清单里的 handler 路径（`handlers/get_time.js`）——
  /// 插件侧就是按这个键注册的，所以直接透传，不做映射。
  /// 调用某个提供方的一个能力 handler。
  ///
  /// **复用 [invokeTool]** —— 能力 handler 和工具 handler 在插件侧
  /// 是同一类东西（一个注册过的 JS 函数），各种失败态
  /// （未安装 / 未运行 / 未就绪 / 抛异常）的处理也完全一样。
  /// 分两条路只会让其中一条慢慢长歪。
  Future<ToolInvocationResult> invokeCapability(
    String providerId,
    String handler,
    Map<String, dynamic> args,
  ) =>
      invokeTool(providerId, handler, args);

  Future<ToolInvocationResult> invokeTool(
    String pluginId,
    String handler,
    Map<String, dynamic> args,
  ) async {
    final plugin = _find(pluginId);
    if (plugin == null) {
      return _fail(pluginId, handler, 'NO_PLUGIN', '插件 $pluginId 未安装');
    }
    final runtime = plugin.runtime;
    if (runtime == null) {
      return _fail(
        pluginId,
        handler,
        'NOT_RUNNING',
        '插件 $pluginId 未运行（${plugin.enabled ? "正在启动" : "已被停用"}）',
      );
    }
    if (!runtime.isReady) {
      return _fail(
        pluginId,
        handler,
        'NOT_READY',
        '插件 $pluginId 的运行时未就绪（state=${runtime.state.name}）',
      );
    }

    final result = await runtime.invokeTool(handler, args);
    if (!result.ok) {
      // **工具失败必须留下痕迹。**
      //
      // 以前失败只报给模型，模型转述成"我无法获取"，
      // 而用户和开发者都看不到真正的原因（未就绪？权限被拒？JS 抛错？）。
      _note(pluginId, 'error', '工具 $handler 失败：'
          '[${result.errorCode}] ${result.errorMessage}');
    }
    return result;
  }

  ToolInvocationResult _fail(
    String pluginId,
    String handler,
    String code,
    String message,
  ) {
    _note(pluginId, 'error', '工具 $handler 未执行：[$code] $message');
    return ToolInvocationResult.failure(code, message);
  }

  /// 调一个插件的钩子处理器。
  ///
  /// 走 Bridge 的 `hook.<phase>` 方法，对应插件侧的
  /// `tsukiro.defineHook(phase, handler)` 或 `hook.<phase>` 注册。
  ///
  /// **失败不抛** —— 钩子是旁路，不该让主流程崩。
  /// 返回 null 表示插件没接这个钩子（或没在跑）。
  Future<Map<String, dynamic>?> invokeHook(
    String pluginId,
    String phase,
    Map<String, dynamic> context,
  ) async {
    final plugin = _find(pluginId);
    final runtime = plugin?.runtime;
    if (runtime == null || !runtime.isReady) return null;

    return runtime.invokeHook(phase, context);
  }

  /// 往插件的日志里写一条（用户能在插件管理页看到）。
  void _note(String pluginId, String level, String message) {
    _find(pluginId)?.runtime?.addExternalLog(level, message, null);
    debugPrint('[plugin:$pluginId][$level] $message');
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
                // 平台视图 attach 之后再启动，否则 JS 不会执行
                onAttached: () => unawaited(widget.host.attachRuntime(plugin)),
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
  /// 已经为哪个运行时实例触发过启动。
  ///
  /// **按实例判断，不按插件 id。** 用户点"启动"重建运行时之后，
  /// 组件还是同一个（key 没变，`initState` 不会重跑）——
  /// 只按 id 去重的话，新的运行时永远等不到 attach。
  PluginRuntime? _attached;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAttach());
  }

  @override
  void didUpdateWidget(_AttachedRuntime oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 运行时被换掉（重试、重启）→ 对新实例再走一次 attach 后的启动
    if (!identical(widget.plugin.runtime, oldWidget.plugin.runtime)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAttach());
    }
  }

  void _maybeAttach() {
    if (!mounted) return;
    final runtime = widget.plugin.runtime;
    if (runtime == null) return;
    if (runtime.isReady) return;
    if (identical(runtime, _attached)) return;

    _attached = runtime;
    widget.onAttached();
  }

  @override
  Widget build(BuildContext context) =>
      widget.plugin.runtime?.buildView() ?? const SizedBox.shrink();
}
