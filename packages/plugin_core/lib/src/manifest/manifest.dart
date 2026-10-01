/// 插件 manifest 的数据模型。
///
/// 字段定义与 `docs/04-plugin-spec.md` §2 严格对应。
///
/// **实现进度**：`tools` / `ui` / `pages` 已完整建模；`overlays` / `skills` /
/// `themes` / `personas` / `mcp` / `memory` / `harness` 先保留原始 JSON 结构
/// （[ProvidesSpec.rawReserved]），保证 manifest 一次留全、未来解析不破坏兼容。
library;

import '../common/semver.dart';
import '../permission/permission.dart';

/// 作者信息。
class ManifestAuthor {
  const ManifestAuthor({this.name, this.url, this.email});

  final String? name;
  final String? url;
  final String? email;

  static ManifestAuthor? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final url = json['url'];
    final email = json['email'];
    if (name == null && url == null && email == null) return null;
    return ManifestAuthor(
      name: name?.toString(),
      url: url?.toString(),
      email: email?.toString(),
    );
  }

  @override
  String toString() => name ?? url ?? email ?? '<anonymous>';
}

/// 运行时入口配置。
class RuntimeSpec {
  const RuntimeSpec({
    this.main = 'index.js',
    this.type = 'module',
    this.autoStart = true,
  });

  final String main;

  /// `module` 或 `classic`。
  final String type;

  final bool autoStart;

  static const RuntimeSpec defaults = RuntimeSpec();
}

/// 插件声明的一条权限。
///
/// manifest 里既接受 `"sys.time"` 简写，也接受
/// `{"name": "sys.time", "reason": "..."}` 完整写法，
/// 解析后统一为本类型。
class DeclaredPermission {
  const DeclaredPermission(this.name, {this.reason});

  final String name;

  /// 面向用户的用途说明。为空时安装弹窗显示「未说明用途」，商店审核会降级。
  final String? reason;

  @override
  String toString() => reason == null ? name : '$name（$reason）';
}

/// 网络白名单。
///
/// 不声明此字段 = **完全禁止网络**。`net` 权限与白名单是**双重检查**：
/// 两者缺一，`net.request` 都失败。
class NetworkSpec {
  const NetworkSpec({
    this.allow = const <String>[],
    this.maxRequestsPerMinute = 60,
  });

  final List<String> allow;
  final int maxRequestsPerMinute;

  bool get isDisabled => allow.isEmpty;
}

/// 用户可配置项（JSON Schema 子集）。
class ConfigSpec {
  const ConfigSpec({required this.schema, this.section});

  final Map<String, dynamic> schema;
  final ConfigSection? section;
}

/// 配置在设置页的展示位置。
class ConfigSection {
  const ConfigSection({required this.slot, this.title});

  final String slot;
  final String? title;
}

/// 工具声明（L2）。
class ToolDeclaration {
  const ToolDeclaration({
    required this.name,
    required this.description,
    required this.parameters,
    required this.handler,
    this.permissions = const <String>[],
    this.timeoutMs = 10000,
    this.dangerous = false,
    this.exposed = true,
    this.returns,
  });

  /// 暴露给模型的名字（snake_case）。
  final String name;

  /// 写给模型看的说明。**这是工具能否被正确调用的关键**。
  final String description;

  /// 已展开为完整 JSON Schema。
  final Map<String, dynamic> parameters;

  /// 包内相对路径。
  final String handler;

  /// 工具级权限。校验时与插件级声明取并集基线。
  final List<String> permissions;

  final int timeoutMs;

  /// 为 true 时每次调用都需用户确认。
  final bool dangerous;

  /// 是否允许其他插件通过 `tool.call` 调用。
  final bool exposed;

  /// 返回值类型提示。
  final String? returns;

  @override
  String toString() => 'ToolDeclaration($name → $handler)';
}

/// UI 插槽控件声明（L3）。由**宿主渲染**，插件只给语义。
class UiDeclaration {
  const UiDeclaration({
    required this.slot,
    required this.id,
    required this.type,
    this.label,
    this.icon,
    this.tooltip,
    this.order = 100,
    this.when,
    this.onClickEvent,
    this.permissions = const <String>[],
    this.children = const <UiDeclaration>[],
    this.config,
  });

  final String slot;
  final String id;

  /// `button` / `toggle` / `menu-item` / `divider` / `section` / `text` /
  /// `input` / `select` / `number` / `slider`。
  final String type;

  final String? label;
  final String? icon;
  final String? tooltip;
  final int order;

  /// 显示条件（键值比较，无表达式语言）。
  final Map<String, dynamic>? when;

  /// 点击时发给插件的事件名。为空则发默认的 `ui.click`。
  final String? onClickEvent;

  final List<String> permissions;

  /// 仅 `section` 类型使用。
  final List<UiDeclaration> children;

  /// 绑定到 `config.schema` 的字段信息。
  final Map<String, dynamic>? config;

  @override
  String toString() => 'UiDeclaration($slot/$id:$type)';
}

/// 独立页面声明（L3）。唯一允许插件自定义外观的形态。
class PageDeclaration {
  const PageDeclaration({
    required this.id,
    required this.title,
    required this.entry,
    this.presentation = 'page',
    this.icon,
    this.width,
    this.height,
    this.resizable = true,
    this.bridge = true,
    this.permissions = const <String>[],
    this.openFrom = const <String>[],
  });

  final String id;
  final String title;
  final String entry;

  /// `page` / `window` / `sheet` / `fullscreen`。
  final String presentation;

  final String? icon;
  final int? width;
  final int? height;
  final bool resizable;
  final bool bridge;
  final List<String> permissions;
  final List<String> openFrom;

  @override
  String toString() => 'PageDeclaration($id → $entry)';
}

/// `provides` 段。
class ProvidesSpec {
  const ProvidesSpec({
    this.tools = const <ToolDeclaration>[],
    this.ui = const <UiDeclaration>[],
    this.pages = const <PageDeclaration>[],
    this.rawReserved = const <String, dynamic>{},
  });

  final List<ToolDeclaration> tools;
  final List<UiDeclaration> ui;
  final List<PageDeclaration> pages;

  /// 尚未建模但需原样保留的段：`overlays` / `skills` / `themes` /
  /// `personas` / `mcp` / `memory`。
  final Map<String, dynamic> rawReserved;
}

/// 一个插件的完整 manifest。
class PluginManifest {
  const PluginManifest({
    required this.manifestVersion,
    required this.id,
    required this.name,
    required this.version,
    required this.semver,
    required this.runtime,
    this.description,
    this.author,
    this.license,
    this.homepage,
    this.repository,
    this.icon,
    this.keywords = const <String>[],
    this.minHostVersion,
    this.hostApi,
    this.permissions = const <DeclaredPermission>[],
    this.network,
    this.config,
    this.provides = const ProvidesSpec(),
    this.harness,
    this.raw = const <String, dynamic>{},
  });

  /// 当前宿主支持的最高 manifest 版本。
  static const int supportedManifestVersion = 1;

  final int manifestVersion;
  final String id;
  final String name;
  final String version;
  final SemVer semver;
  final RuntimeSpec runtime;
  final String? description;
  final ManifestAuthor? author;
  final String? license;
  final String? homepage;
  final String? repository;
  final String? icon;
  final List<String> keywords;
  final SemVer? minHostVersion;
  final String? hostApi;
  final List<DeclaredPermission> permissions;
  final NetworkSpec? network;
  final ConfigSpec? config;
  final ProvidesSpec provides;

  /// L7 预留。本阶段宿主**解析但不执行**，仅记录日志以便验证 schema 是否留够。
  final Map<String, dynamic>? harness;

  /// 原始 JSON，用于审计留档与未来字段兼容。
  final Map<String, dynamic> raw;

  /// 声明所需权限名列表。
  List<String> get permissionNames =>
      permissions.map((e) => e.name).toList(growable: false);

  /// 需要「每次确认」的权限（安装弹窗必须高亮，且**永不提供「不再询问」**）。
  Iterable<DeclaredPermission> get confirmLevelPermissions =>
      permissions.where((e) => levelOf(e.name) == PermissionLevel.confirm);

  /// 该插件申请的、宿主保留不允许的权限。非空则安装必须失败。
  Iterable<DeclaredPermission> get forbiddenPermissions =>
      permissions.where((e) => levelOf(e.name) == PermissionLevel.denied);

  List<ToolDeclaration> get tools => provides.tools;
  List<UiDeclaration> get ui => provides.ui;
  List<PageDeclaration> get pages => provides.pages;

  @override
  String toString() => 'PluginManifest($id@$version, ${tools.length} tools)';
}
