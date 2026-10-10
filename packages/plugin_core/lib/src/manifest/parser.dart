/// manifest 解析与校验。
///
/// 设计要点：
///   - **收集全部问题再返回**，而不是遇到第一个错误就抛异常。安装弹窗要一次性
///     告诉插件作者所有问题，逐个试错是折磨。
///   - **未知权限名一律拒绝**。拼错权限名如果被静默忽略，插件会在运行时莫名
///     失败，这类 bug 极难排查。
///   - 解析结果带 [ManifestParseResult.manifest]，只有 [ManifestParseResult.isValid]
///     为 true 时才可用。
library;

import 'config_field.dart';
import '../capability/capability.dart';
import 'dart:convert';

import '../common/semver.dart';
import '../permission/permission.dart';
import 'manifest.dart';
import 'surface.dart';
import 'theme.dart';

/// 一条校验问题。
class ManifestIssue {
  const ManifestIssue(this.path, this.message);

  /// JSON 路径，如 `provides.tools[0].name`。
  final String path;

  final String message;

  @override
  String toString() => '$path: $message';
}

/// 解析结果。
class ManifestParseResult {
  const ManifestParseResult({this.manifest, this.issues = const <ManifestIssue>[]});

  final PluginManifest? manifest;
  final List<ManifestIssue> issues;

  bool get isValid => manifest != null && issues.isEmpty;
  bool get hasFatal => manifest == null;

  @override
  String toString() => isValid
      ? 'ManifestParseResult(ok: ${manifest!.id})'
      : 'ManifestParseResult(${issues.length} issues)';
}

/// 插件 id 规则：反向域名风格，小写字母数字与 `.` `-` `_`，至少两段。
final RegExp _pluginIdPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z0-9_][a-z0-9_-]*)+$');

/// 工具名规则：snake_case，模型侧最兼容。
final RegExp _toolNamePattern = RegExp(r'^[a-z][a-z0-9_]*$');

/// 允许的控件类型。
const Set<String> allowedUiTypes = <String>{
  'button',
  'toggle',
  'menu-item',
  'divider',
  'section',
  'text',
  'input',
  'select',
  'number',
  'slider',

  // ── 视觉节点（docs/23） ──
  //
  // 这些不是「控件」而是**画面元素**：粒子、模糊、变换、图形。
  // 它们由运行期 UI 树的渲染器负责，和上面的语义控件共用一套代码
  // （见 uiNodeFromDeclaration）。
  //
  // **加进白名单是必须的**：不在里面的话整个清单**校验失败**、
  // 插件装不上 —— 而不是「这个控件画不出来」。差别很大。
  'particle',
  'blur',
  'stack',
  'transform',
  'shape',
};

/// 允许的页面呈现方式。
const Set<String> allowedPresentations = <String>{
  'page',
  'window',
  'sheet',
  'fullscreen',
};

/// 简写参数类型 → JSON Schema 类型。
const Set<String> allowedShorthandTypes = <String>{
  'string',
  'number',
  'integer',
  'boolean',
  'object',
  'array',
};

/// 解析 manifest JSON 文本。
ManifestParseResult parseManifestJson(String source) {
  Object? decoded;
  try {
    decoded = _jsonDecode(source);
  } on FormatException catch (e) {
    return ManifestParseResult(
      issues: <ManifestIssue>[ManifestIssue('<root>', '不是合法 JSON: ${e.message}')],
    );
  }
  if (decoded is! Map<String, dynamic>) {
    return const ManifestParseResult(
      issues: <ManifestIssue>[ManifestIssue('<root>', '顶层必须是 JSON 对象')],
    );
  }
  return parseManifest(decoded);
}

/// 解析 manifest 映射。
ManifestParseResult parseManifest(Map<String, dynamic> json) {
  final errors = <ManifestIssue>[];

  // ── manifestVersion ──
  final rawVersion = json['manifestVersion'];
  var manifestVersion = 0;
  if (rawVersion is! num) {
    errors.add(ManifestIssue(
      'manifestVersion',
      '缺少或类型错误：必须是数字'
      '（当前宿主支持 ${PluginManifest.supportedManifestVersion}）',
    ));
  } else {
    manifestVersion = rawVersion.toInt();
    if (manifestVersion <= 0) {
      errors.add(const ManifestIssue('manifestVersion', '必须为正整数'));
    } else if (manifestVersion > PluginManifest.supportedManifestVersion) {
      errors.add(ManifestIssue(
        'manifestVersion',
        '版本 $manifestVersion 高于宿主支持的 ${PluginManifest.supportedManifestVersion}，请升级宿主',
      ));
    }
  }

  // ── id ──
  final id = _requireString(json, 'id', errors);
  if (id != null && !_pluginIdPattern.hasMatch(id)) {
    errors.add(ManifestIssue(
      'id',
      '格式非法："$id"。要求反向域名风格、全小写，如 dev.tsukiro.time',
    ));
  }

  // ── name ──
  final name = _requireString(json, 'name', errors);

  // ── version ──
  final version = _requireString(json, 'version', errors);
  SemVer? semver;
  if (version != null) {
    semver = SemVer.tryParse(version);
    if (semver == null) {
      errors.add(ManifestIssue('version', '不是合法语义化版本："$version"'));
    }
  }

  // ── minHostVersion / hostApi ──
  final minHostVersionRaw = json['minHostVersion'];
  SemVer? minHostVersion;
  if (minHostVersionRaw != null) {
    minHostVersion = SemVer.tryParse('$minHostVersionRaw');
    if (minHostVersion == null) {
      errors.add(ManifestIssue('minHostVersion', '不是合法语义化版本："$minHostVersionRaw"'));
    }
  }
  final hostApi = json['hostApi']?.toString();

  // ── runtime ──
  final runtime = _parseRuntime(json['runtime'], errors);

  // ── permissions ──
  final permissions = _parsePermissions(json['permissions'], errors);

  // ── network ──
  final network = _parseNetwork(json['network'], errors);

  // ── config ──
  final config = _parseConfig(json['config'], errors);

  // ── provides ──
  final provides = _parseProvides(json['provides'], errors);

  // ── harness（L7 预留：放行但不解析为强类型） ──
  final harness = json['harness'];
  if (harness != null && harness is! Map<String, dynamic>) {
    errors.add(const ManifestIssue('harness', '必须是对象（L7 预留字段）'));
  }

  // ── icon ──
  final icon = json['icon']?.toString();
  if (icon != null && (icon.startsWith('/') || icon.contains('..'))) {
    errors.add(const ManifestIssue('icon', '必须是包内相对路径，且不含 ".."'));
  }

  // ── keywords ──
  final keywords = <String>[];
  final rawKeywords = json['keywords'];
  if (rawKeywords != null) {
    if (rawKeywords is! List) {
      errors.add(const ManifestIssue('keywords', '必须是字符串数组'));
    } else {
      for (var i = 0; i < rawKeywords.length; i++) {
        final k = rawKeywords[i];
        if (k is! String) {
          errors.add(ManifestIssue('keywords[$i]', '必须是字符串'));
        } else {
          keywords.add(k);
        }
      }
    }
  }

  // ── runtime 缺省的合法性 ──
  //
  // 省略 runtime 只在"零代码插件"时合法。声明了需要代码的能力却没有入口，
  // 那不是"配置"，是"漏了东西" —— 必须在安装时拦下，而不是等运行期发现
  // 按钮点了没反应。
  if (runtime == null) {
    // ── 什么样的 ui 才真的需要 runtime ──
    //
    // 原来的规则是「声明了 ui 就必须有 runtime」，理由是
    // 「控件的 onClick 要有人接」。那个理由对**控件**成立，
    // 但对**画面元素**不成立：
    //
    //   飘落的花瓣 / 一个图形 / 一层模糊 —— 它们只是被画出来，
    //   没有回调、不需要谁来接。樱花主题本来就是零代码插件，
    //   加了花瓣之后却被要求提供一个 runtime，
    //   而那个 runtime 里一行有用的代码都不会有。
    //
    // 所以判据从「有没有声明 ui」收紧到「有没有**需要代码**的部分」。
    final codeProvides = <String>[
      if (provides.tools.isNotEmpty) 'tools',
      if (provides.ui.any(_uiDeclNeedsCode)) 'ui',
      if (provides.pages.isNotEmpty) 'pages',
      if (provides.layout != null) 'layout',
      if (provides.replaces != null) 'replaces',
      if (harness != null) 'harness',
    ];
    if (codeProvides.isNotEmpty) {
      errors.add(ManifestIssue(
        'runtime',
        '声明了 ${codeProvides.join(" / ")} 却没有 runtime。'
        '这些能力需要代码实现（比如控件的 onClick 要有人接）。'
        '只有纯声明式插件（美化包 / 人设包 / Skills）才可以省略 runtime。',
      ));
    }
  }

  if (errors.isNotEmpty || id == null || name == null || version == null || semver == null) {
    return ManifestParseResult(issues: errors);
  }

  return ManifestParseResult(
    manifest: PluginManifest(
      manifestVersion: manifestVersion,
      id: id,
      name: name,
      version: version,
      semver: semver,
      runtime: runtime,
      description: json['description']?.toString(),
      author: json['author'] is Map<String, dynamic>
          ? ManifestAuthor.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      license: json['license']?.toString(),
      homepage: json['homepage']?.toString(),
      repository: json['repository']?.toString(),
      icon: icon,
      keywords: keywords,
      minHostVersion: minHostVersion,
      hostApi: hostApi,
      permissions: permissions,
      network: network,
      config: config,
      provides: provides,
      harness: harness is Map<String, dynamic> ? harness : null,
      raw: json,
    ),
  );
}

/// 检查宿主版本是否满足插件要求。
///
/// 返回 null 表示满足；否则返回给用户看的错误说明。
String? checkHostCompatibility(PluginManifest manifest, String hostVersion) {
  final host = SemVer.tryParse(hostVersion);
  if (host == null) return '宿主版本号非法："$hostVersion"';

  final min = manifest.minHostVersion;
  if (min != null && host < min) {
    return '该插件需要宿主 ≥ $min，当前 $host';
  }

  final api = manifest.hostApi;
  if (api != null && !satisfiesHostApi(api, hostVersion)) {
    return '该插件要求宿主 API $api，当前 $host';
  }
  return null;
}

// ─────────────────────────── 内部解析 ───────────────────────────

Map<String, dynamic> _jsonDecode(String source) {
  final value = jsonDecode(source);
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('顶层不是对象');
}

String? _requireString(Map<String, dynamic> json, String key, List<ManifestIssue> errors) {
  final value = json[key];
  if (value == null) {
    errors.add(ManifestIssue(key, '缺少必填字段'));
    return null;
  }
  if (value is! String || value.trim().isEmpty) {
    errors.add(ManifestIssue(key, '必须是非空字符串'));
    return null;
  }
  return value.trim();
}

RuntimeSpec? _parseRuntime(Object? raw, List<ManifestIssue> errors) {
  // 允许缺失 —— 纯声明式插件（美化包 / 人设包）没有代码。
  // 是否合法由 parseManifest 在拿到 provides 之后统一判断（见下）。
  if (raw == null) return null;

  if (raw is! Map<String, dynamic>) {
    errors.add(const ManifestIssue('runtime', '必须是对象（或整体省略，表示纯声明式插件）'));
    return RuntimeSpec.defaults;
  }

  final main = raw['main'];
  var mainPath = 'index.js';
  if (main == null) {
    errors.add(const ManifestIssue('runtime.main', '缺少必填字段'));
  } else if (main is! String || main.trim().isEmpty) {
    errors.add(const ManifestIssue('runtime.main', '必须是非空字符串'));
  } else {
    mainPath = main.trim();
    if (mainPath.startsWith('/') || mainPath.contains('..')) {
      errors.add(const ManifestIssue('runtime.main', '必须是包内相对路径，且不含 ".."'));
    }
  }

  final type = raw['type']?.toString() ?? 'module';
  if (type != 'module' && type != 'classic') {
    errors.add(const ManifestIssue('runtime.type', '只支持 "module" 或 "classic"'));
  }

  final autoStart = raw['autoStart'];
  if (autoStart != null && autoStart is! bool) {
    errors.add(const ManifestIssue('runtime.autoStart', '必须是布尔值'));
  }

  return RuntimeSpec(
    main: mainPath,
    type: type,
    autoStart: autoStart is bool ? autoStart : true,
  );
}

List<DeclaredPermission> _parsePermissions(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const <DeclaredPermission>[];
  if (raw is! List) {
    errors.add(const ManifestIssue('permissions', '必须是数组'));
    return const <DeclaredPermission>[];
  }

  final result = <DeclaredPermission>[];
  final seen = <String>{};

  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final path = 'permissions[$i]';

    String? permissionName;
    String? reason;

    if (item is String) {
      permissionName = item.trim();
    } else if (item is Map<String, dynamic>) {
      final n = item['name'];
      if (n is! String || n.trim().isEmpty) {
        errors.add(ManifestIssue('$path.name', '缺少或类型错误：必须是非空字符串'));
        continue;
      }
      permissionName = n.trim();
      reason = item['reason']?.toString();
    } else {
      errors.add(ManifestIssue(path, '必须是字符串，或 {"name": "...", "reason": "..."} 对象'));
      continue;
    }

    if (!isKnownPermission(permissionName)) {
      errors.add(ManifestIssue(
        path,
        '未知权限 "$permissionName"。拼错的权限名会导致运行时莫名失败，因此一律拒绝。'
        '可用权限见 docs/06-permissions.md',
      ));
      continue;
    }
    if (!seen.add(permissionName)) {
      errors.add(ManifestIssue(path, '重复声明权限 "$permissionName"'));
      continue;
    }
    result.add(DeclaredPermission(permissionName, reason: reason));
  }
  return result;
}

NetworkSpec? _parseNetwork(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return null;
  if (raw is! Map<String, dynamic>) {
    errors.add(const ManifestIssue('network', '必须是对象'));
    return null;
  }

  final allow = <String>[];
  final rawAllow = raw['allow'];
  if (rawAllow != null) {
    if (rawAllow is! List) {
      errors.add(const ManifestIssue('network.allow', '必须是字符串数组'));
    } else {
      for (var i = 0; i < rawAllow.length; i++) {
        final entry = rawAllow[i];
        if (entry is! String) {
          errors.add(ManifestIssue('network.allow[$i]', '必须是字符串'));
          continue;
        }
        final uri = Uri.tryParse(entry);
        if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
          errors.add(ManifestIssue(
            'network.allow[$i]',
            '"$entry" 不是合法来源。必须带 scheme 与主机名，如 https://api.example.com',
          ));
          continue;
        }
        if (uri.scheme != 'https' && uri.scheme != 'wss' && uri.scheme != 'http') {
          errors.add(ManifestIssue('network.allow[$i]', '只支持 http / https / wss'));
          continue;
        }
        allow.add(entry);
      }
    }
  }

  final rawRate = raw['maxRequestsPerMinute'];
  var rate = 60;
  if (rawRate != null) {
    if (rawRate is! num || rawRate <= 0) {
      errors.add(const ManifestIssue('network.maxRequestsPerMinute', '必须是正数'));
    } else {
      // 只能调低，不能调高（宿主上限），防止插件绕过限流
      rate = rawRate.toInt().clamp(1, 600);
    }
  }

  return NetworkSpec(allow: allow, maxRequestsPerMinute: rate);
}

ConfigSpec? _parseConfig(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return null;
  if (raw is! Map<String, dynamic>) {
    errors.add(const ManifestIssue('config', '必须是对象'));
    return null;
  }

  final schema = raw['schema'];
  if (schema == null) {
    errors.add(const ManifestIssue('config.schema', '缺少必填字段'));
    return null;
  }
  if (schema is! Map<String, dynamic>) {
    errors.add(const ManifestIssue('config.schema', '必须是 JSON Schema 对象'));
    return null;
  }

  ConfigSection? section;
  final rawSection = raw['section'];
  if (rawSection != null) {
    if (rawSection is! Map<String, dynamic>) {
      errors.add(const ManifestIssue('config.section', '必须是对象'));
    } else {
      final slot = rawSection['slot'];
      if (slot is! String || slot.isEmpty) {
        errors.add(const ManifestIssue('config.section.slot', '缺少或类型错误'));
      } else if (slot != 'settings.sections') {
        errors.add(const ManifestIssue(
          'config.section.slot',
          '配置分区目前只支持挂在 settings.sections',
        ));
      } else {
        section = ConfigSection(slot: slot, title: rawSection['title']?.toString());
      }
    }
  }

  return ConfigSpec(schema: schema, section: section);
}

ProvidesSpec _parseProvides(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const ProvidesSpec();
  if (raw is! Map<String, dynamic>) {
    errors.add(const ManifestIssue('provides', '必须是对象'));
    return const ProvidesSpec();
  }

  final tools = _parseTools(raw['tools'], errors);
  final ui = _parseUi(raw['ui'], errors);
  final pages = _parsePages(raw['pages'], errors);
  final surfaces = _parseSurfaces(raw['surfaces'], errors);
  final capabilities = _parseCapabilities(raw['capabilities'], errors);
  final themes = _parseThemes(raw['theme'] ?? raw['themes'], errors);
  // 插件声明的配置项。宿主据此画设置界面（没声明就不显示配置入口）。
  final configFields = _parseConfigFields(raw['config'], errors);
  final reserved = <String, dynamic>{};

  // 预留段：**只解析不执行**。字段一次留全，这样插件今天写的 manifest
  // 在未来宿主升级后不用改一个字（NFR-COMP-01）。
  for (final key in const <String>[
    'overlays',
    'skills',
    'personas',
    'mcp',
    'memory',
    'layout', // L2 布局级
    'replaces', // L3 接管级
    'data', // L3 数据访问
  ]) {
    final value = raw[key];
    if (value == null) continue;
    if (value is! List && value is! Map) {
      errors.add(ManifestIssue('provides.$key', '必须是数组或对象'));
      continue;
    }
    reserved[key] = value;
  }

  // 布局/接管段虽然不执行，但结构要基本合理 —— 否则插件作者会以为写对了
  _checkReservedShape(reserved, errors);

  return ProvidesSpec(
    tools: tools,
    ui: ui,
    pages: pages,
    surfaces: surfaces,
    capabilities: capabilities,
    config: configFields,
    themes: themes,
    rawReserved: reserved,
  );
}

/// 解析 provides.config（插件的配置项）。
///
/// 坏条目只丢自己：一个插件声明了三个开关、其中一个写错了，
/// 不该让另外两个也画不出来。
List<ConfigField> _parseConfigFields(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const <ConfigField>[];
  if (raw is! List) {
    errors.add(const ManifestIssue('provides.config', '必须是数组'));
    return const <ConfigField>[];
  }

  final out = <ConfigField>[];
  final seen = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final parsed = ConfigField.parse(raw[i]);
    if (parsed == null) {
      // 这里**只丢自己不整单失败**（和 capabilities 不同）：
      // 配置项是纯界面描述，少画一个开关不会让插件功能坏掉，
      // 而整单失败会让插件装不上 —— 代价不对等。
      continue;
    }
    if (!seen.add(parsed.key)) {
      errors.add(ManifestIssue(
        'provides.config[$i].key',
        '配置键「${parsed.key}」重复',
      ));
      continue;
    }
    out.add(parsed);
  }
  return out;
}

/// 解析 provides.capabilities（能力市场）。
///
/// 畸形的声明是**打包错误**，会让整个清单校验失败（与其它 provides 段一致）。
/// 不静默少提供一个：那会让调用方拿到「找不到能力」，
/// 而真正的原因在几层之外。作者该在安装时就被告知。
List<CapabilityDeclaration> _parseCapabilities(
  Object? raw,
  List<ManifestIssue> errors,
) {
  if (raw == null) return const <CapabilityDeclaration>[];
  if (raw is! List) {
    errors.add(const ManifestIssue('provides.capabilities', '必须是数组'));
    return const <CapabilityDeclaration>[];
  }

  final out = <CapabilityDeclaration>[];
  final seen = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final parsed = CapabilityDeclaration.parse(raw[i]);
    if (parsed == null) {
      errors.add(ManifestIssue(
        'provides.capabilities[$i]',
        '需要 name 与 handler',
      ));
      continue;
    }
    if (!seen.add(parsed.name)) {
      errors.add(ManifestIssue(
        'provides.capabilities[$i].name',
        '能力名「${parsed.name}」重复',
      ));
      continue;
    }
    out.add(parsed);
  }
  return out;
}

List<SurfaceDeclaration> _parseSurfaces(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const <SurfaceDeclaration>[];
  if (raw is! List) {
    errors.add(const ManifestIssue('provides.surfaces', '必须是数组'));
    return const <SurfaceDeclaration>[];
  }
  final result = <SurfaceDeclaration>[];
  final seen = <String>{};
  for (var i = 0; i < raw.length; i++) {
    final path = 'provides.surfaces[$i]';
    final item = raw[i];
    if (item is! Map<String, dynamic>) {
      errors.add(ManifestIssue(path, '必须是对象'));
      continue;
    }
    final id = item['id']?.toString().trim() ?? '';
    final kind = SurfaceKind.parse(item['kind']?.toString());
    final slot = item['slot']?.toString().trim() ?? '';
    if (id.isEmpty || !seen.add(id)) {
      errors.add(ManifestIssue('$path.id', 'id 缺失或重复'));
      continue;
    }
    if (kind == null) {
      errors.add(ManifestIssue('$path.kind', '必须是 web 或 flame'));
      continue;
    }
    if (slot.isEmpty) {
      errors.add(ManifestIssue('$path.slot', '不能为空'));
      continue;
    }
    final entry = item['entry']?.toString();
    final gameType = item['gameType']?.toString();
    if (kind == SurfaceKind.web && (entry == null || entry.isEmpty)) {
      errors.add(ManifestIssue('$path.entry', 'web Surface 必须声明 entry'));
      continue;
    }
    if (kind == SurfaceKind.flame && (gameType == null || gameType.isEmpty)) {
      errors.add(ManifestIssue('$path.gameType', 'flame Surface 必须声明 gameType'));
      continue;
    }
    final rawCapabilities = item['capabilities'];
    final capabilities = <String>[];
    if (rawCapabilities is List) {
      for (final capability in rawCapabilities) {
        final name = '$capability';
        if (!surfaceCapabilities.contains(name)) {
          errors.add(ManifestIssue('$path.capabilities', '未知 capability "$name"'));
        } else {
          capabilities.add(name);
        }
      }
    }
    final rawPermissions = item['permissions'];
    final permissions = rawPermissions is List
        ? rawPermissions.map((value) => '$value').toList(growable: false)
        : const <String>[];
    num? number(Object? value) => value is num ? value : null;
    result.add(SurfaceDeclaration(
      id: id,
      kind: kind,
      slot: slot,
      entry: entry,
      gameType: gameType,
      presentation: item['presentation']?.toString() ?? 'page',
      minWidth: number(item['minWidth'])?.toDouble(),
      minHeight: number(item['minHeight'])?.toDouble(),
      maxWidth: number(item['maxWidth'])?.toDouble(),
      maxHeight: number(item['maxHeight'])?.toDouble(),
      capabilities: capabilities,
      permissions: permissions,
    ));
  }
  return result;
}

/// 校验预留段的形状。
///
/// 不执行不等于不检查：如果插件写了个 `layout.mode` 拼错的键，宿主静默接受，
/// 插件作者会以为布局生效了，等未来 L2 放开才发现写错。现在报出来成本最低。
void _checkReservedShape(Map<String, dynamic> reserved, List<ManifestIssue> errors) {
  final layout = reserved['layout'];
  if (layout != null) {
    if (layout is! Map) {
      errors.add(const ManifestIssue('provides.layout', '必须是对象'));
    } else {
      const allowed = <String>{
        'mode', 'slots', 'stack', 'grid', 'absolute', 'scroll', 'tabs',
      };
      for (final key in layout.keys) {
        if (!allowed.contains('$key')) {
          errors.add(ManifestIssue(
            'provides.layout.$key',
            '未知的布局字段。当前预留字段：${allowed.join(" / ")}',
          ));
        }
      }
      final slots = layout['slots'];
      if (slots != null && slots is! Map) {
        errors.add(const ManifestIssue('provides.layout.slots', '必须是对象'));
      }
    }
  }

  final replaces = reserved['replaces'];
  if (replaces != null && replaces is! Map) {
    errors.add(const ManifestIssue('provides.replaces', '必须是对象'));
  }
}

List<ThemeDeclaration> _parseThemes(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const <ThemeDeclaration>[];

  // 接受单个对象或数组 —— 两种写法都常见，没必要强迫作者二选一
  final items = raw is List ? raw : <Object?>[raw];
  final result = <ThemeDeclaration>[];
  final seenIds = <String>{};
  const validator = TokenValidator();

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final path = items.length == 1 ? 'provides.theme' : 'provides.theme[$i]';
    if (item is! Map<String, dynamic>) {
      errors.add(ManifestIssue(path, '必须是对象'));
      continue;
    }

    final id = item['id']?.toString();
    final name = item['name']?.toString();
    if (id == null || id.isEmpty) {
      errors.add(ManifestIssue('$path.id', '缺少主题 id'));
      continue;
    }
    if (!seenIds.add(id)) {
      errors.add(ManifestIssue('$path.id', '主题 id 重复："$id"'));
      continue;
    }
    if (name == null || name.isEmpty) {
      errors.add(ManifestIssue('$path.name', '缺少主题名（给用户看的）'));
      continue;
    }

    final rawTokens = item['tokens'];
    if (rawTokens is! Map) {
      errors.add(ManifestIssue('$path.tokens', '必须是对象，键为令牌名'));
      continue;
    }

    // 令牌校验：未知令牌名、类型不符、藏 CSS 全部在这里拦下
    final tokenIssues = validator.validate(rawTokens.cast<String, dynamic>());
    for (final issue in tokenIssues) {
      errors.add(ManifestIssue('$path.tokens.${issue.token}', issue.message));
    }
    if (tokenIssues.isNotEmpty) continue;

    result.add(ThemeDeclaration(
      id: id,
      name: name,
      tokens: rawTokens.map((k, v) => MapEntry('$k', v as Object)),
      base: item['base']?.toString(),
      isDark: item['isDark'] == true,
    ));
  }

  return result;
}

List<ToolDeclaration> _parseTools(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const <ToolDeclaration>[];
  if (raw is! List) {
    errors.add(const ManifestIssue('provides.tools', '必须是数组'));
    return const <ToolDeclaration>[];
  }

  final result = <ToolDeclaration>[];
  final seen = <String>{};

  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final path = 'provides.tools[$i]';
    if (item is! Map<String, dynamic>) {
      errors.add(ManifestIssue(path, '必须是对象'));
      continue;
    }

    final name = item['name'];
    if (name is! String || name.trim().isEmpty) {
      errors.add(ManifestIssue('$path.name', '缺少或类型错误：必须是非空字符串'));
      continue;
    }
    final toolName = name.trim();
    if (!_toolNamePattern.hasMatch(toolName)) {
      errors.add(ManifestIssue(
        '$path.name',
        '"$toolName" 非法。必须是 snake_case（小写字母、数字、下划线），'
        '因为部分模型 Provider 的 function name 不接受其他字符',
      ));
      continue;
    }
    if (!seen.add(toolName)) {
      errors.add(ManifestIssue('$path.name', '同一插件内工具名重复："$toolName"'));
      continue;
    }

    final description = item['description'];
    if (description is! String || description.trim().isEmpty) {
      errors.add(ManifestIssue(
        '$path.description',
        '缺少或为空。description 是模型能否正确调用该工具的关键，必须有实质内容',
      ));
      continue;
    }

    final handler = item['handler'];
    if (handler is! String || handler.trim().isEmpty) {
      errors.add(ManifestIssue('$path.handler', '缺少或类型错误：必须是非空相对路径'));
      continue;
    }
    final handlerPath = handler.trim();
    if (handlerPath.startsWith('/') || handlerPath.contains('..')) {
      errors.add(ManifestIssue('$path.handler', '必须是包内相对路径，且不含 ".."'));
      continue;
    }

    final parameters = expandParameterShorthand(item['parameters'], errors, '$path.parameters');
    if (parameters == null) continue;

    final toolPermissions = <String>[];
    final rawPerms = item['permissions'];
    if (rawPerms != null) {
      if (rawPerms is! List) {
        errors.add(ManifestIssue('$path.permissions', '必须是字符串数组'));
      } else {
        for (var j = 0; j < rawPerms.length; j++) {
          final perm = rawPerms[j];
          if (perm is! String || !isKnownPermission(perm)) {
            errors.add(ManifestIssue('$path.permissions[$j]', '未知权限 "$perm"'));
            continue;
          }
          toolPermissions.add(perm);
        }
      }
    }

    var timeoutMs = 10000;
    final rawTimeout = item['timeoutMs'];
    if (rawTimeout != null) {
      if (rawTimeout is! num || rawTimeout <= 0) {
        errors.add(ManifestIssue('$path.timeoutMs', '必须是正数'));
      } else {
        // 上限 60s，防止插件占住工具循环
        timeoutMs = rawTimeout.toInt().clamp(1, 60000);
      }
    }

    result.add(ToolDeclaration(
      name: toolName,
      description: description.trim(),
      parameters: parameters,
      handler: handlerPath,
      permissions: toolPermissions,
      timeoutMs: timeoutMs,
      dangerous: item['dangerous'] == true,
      exposed: item['exposed'] != false,
      returns: item['returns']?.toString(),
    ));
  }
  return result;
}

/// 把简写参数展开为完整 JSON Schema。
///
/// ```json
/// { "limit": "number", "keyword": "string" }
/// ```
/// 展开为
/// ```json
/// { "type": "object",
///   "properties": { "limit": {"type":"number"}, "keyword": {"type":"string"} },
///   "required": ["limit","keyword"] }
/// ```
///
/// 如果传入的已经是完整 JSON Schema（含 `type` 键），原样返回。
Map<String, dynamic>? expandParameterShorthand(
  Object? raw,
  List<ManifestIssue> errors,
  String path,
) {
  if (raw == null) {
    // 无参数工具是合法的
    return <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
      'required': <String>[],
      'additionalProperties': false,
    };
  }
  if (raw is! Map) {
    errors.add(ManifestIssue(path, '必须是对象'));
    return null;
  }

  // 已经是完整 JSON Schema —— 原样返回同一个对象（不复制，保持引用一致）
  if (raw is Map<String, dynamic> &&
      raw['type'] == 'object' &&
      raw.containsKey('properties')) {
    return raw;
  }

  final map = raw.map((k, v) => MapEntry('$k', v));

  final properties = <String, dynamic>{};
  final required = <String>[];

  map.forEach((key, value) {
    if (value is String) {
      if (!allowedShorthandTypes.contains(value)) {
        errors.add(ManifestIssue(
          '$path.$key',
          '简写类型 "$value" 不被支持。可用：${allowedShorthandTypes.join(" / ")}',
        ));
        return;
      }
      properties[key] = <String, dynamic>{'type': value};
      required.add(key);
    } else if (value is Map) {
      // 允许 {"limit": {"type":"number","description":"..."}} 混合写法
      properties[key] = value.map((k, v) => MapEntry('$k', v));
      required.add(key);
    } else {
      errors.add(ManifestIssue('$path.$key', '必须是类型字符串或 JSON Schema 片段'));
    }
  });

  return <String, dynamic>{
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
}

List<UiDeclaration> _parseUi(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const <UiDeclaration>[];
  if (raw is! List) {
    errors.add(const ManifestIssue('provides.ui', '必须是数组'));
    return const <UiDeclaration>[];
  }

  final result = <UiDeclaration>[];
  final seenKeys = <String>{};

  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final path = 'provides.ui[$i]';
    if (item is! Map<String, dynamic>) {
      errors.add(ManifestIssue(path, '必须是对象'));
      continue;
    }

    final slot = item['slot'];
    if (slot is! String || slot.trim().isEmpty) {
      errors.add(ManifestIssue('$path.slot', '缺少或类型错误'));
      continue;
    }

    final id = item['id'];
    if (id is! String || id.trim().isEmpty) {
      errors.add(ManifestIssue('$path.id', '缺少或类型错误'));
      continue;
    }

    final type = item['type'];
    if (type is! String || !allowedUiTypes.contains(type)) {
      errors.add(ManifestIssue(
        '$path.type',
        '未知控件类型 "$type"。可用：${allowedUiTypes.join(" / ")}',
      ));
      continue;
    }

    // divider 不需要 label，其余需要。
    //
    // **视觉节点也豁免**（particle / blur / stack / transform / shape）：
    // 它们不是「能点、能读的控件」，而是画面元素 ——「飘落的花瓣」
    // 没有标签可写。硬要一个的话作者只会填个占位字符串，
    // 而那个字符串永远不会被显示出来。
    const labelOptional = <String>{
      'divider',
      'particle',
      'blur',
      'stack',
      'transform',
      'shape',
    };
    final label = item['label']?.toString();
    if (!labelOptional.contains(type) && (label == null || label.isEmpty)) {
      errors.add(ManifestIssue('$path.label', '控件类型 "$type" 必须有 label'));
      continue;
    }

    // 同一插槽内的 (slot, id) 必须唯一
    final key = '$slot::$id';
    if (!seenKeys.add(key)) {
      errors.add(ManifestIssue(path, '插槽 $slot 下的 id "$id" 重复'));
      continue;
    }

    final order = item['order'];
    var orderValue = 100;
    if (order != null) {
      if (order is! num) {
        errors.add(ManifestIssue('$path.order', '必须是数字'));
        continue;
      }
      orderValue = order.toInt();
    }

    final when = item['when'];
    if (when != null && when is! Map<String, dynamic>) {
      errors.add(ManifestIssue('$path.when', '必须是对象'));
      continue;
    }

    final permissions = <String>[];
    final rawPerms = item['permissions'];
    if (rawPerms != null) {
      if (rawPerms is! List) {
        errors.add(ManifestIssue('$path.permissions', '必须是字符串数组'));
      } else {
        for (var j = 0; j < rawPerms.length; j++) {
          final perm = rawPerms[j];
          if (perm is! String || !isKnownPermission(perm)) {
            errors.add(ManifestIssue('$path.permissions[$j]', '未知权限 "$perm"'));
            continue;
          }
          permissions.add(perm);
        }
      }
    }

    // section 的 children 递归
    var children = const <UiDeclaration>[];
    if (type == 'section') {
      final rawChildren = item['children'];
      if (rawChildren == null) {
        errors.add(ManifestIssue('$path.children', 'section 类型必须有 children'));
        continue;
      }
      final childErrors = <ManifestIssue>[];
      children = _parseUi(rawChildren, childErrors)
          .map((c) => c)
          .toList(growable: false);
      errors.addAll(childErrors);
    }

    final onClick = item['onClick'];
    String? onClickEvent;
    if (onClick != null) {
      if (onClick is! Map<String, dynamic>) {
        errors.add(ManifestIssue('$path.onClick', '必须是对象'));
        continue;
      }
      onClickEvent = onClick['event']?.toString();
    }

    result.add(UiDeclaration(
      slot: slot.trim(),
      id: id.trim(),
      type: type,
      label: label,
      icon: item['icon']?.toString(),
      tooltip: item['tooltip']?.toString(),
      order: orderValue,
      when: when is Map<String, dynamic> ? when : null,
      onClickEvent: onClickEvent,
      permissions: permissions,
      children: children,
      config: item['config'] is Map<String, dynamic>
          ? item['config'] as Map<String, dynamic>
          : null,
      binding: item['binding']?.toString(),
    ));
  }
  return result;
}

List<PageDeclaration> _parsePages(Object? raw, List<ManifestIssue> errors) {
  if (raw == null) return const <PageDeclaration>[];
  if (raw is! List) {
    errors.add(const ManifestIssue('provides.pages', '必须是数组'));
    return const <PageDeclaration>[];
  }

  final result = <PageDeclaration>[];
  final seen = <String>{};

  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final path = 'provides.pages[$i]';
    if (item is! Map<String, dynamic>) {
      errors.add(ManifestIssue(path, '必须是对象'));
      continue;
    }

    final id = item['id'];
    if (id is! String || id.trim().isEmpty) {
      errors.add(ManifestIssue('$path.id', '缺少或类型错误'));
      continue;
    }
    if (!seen.add(id)) {
      errors.add(ManifestIssue('$path.id', '页面 id 重复："$id"'));
      continue;
    }

    final title = item['title'];
    if (title is! String || title.trim().isEmpty) {
      errors.add(ManifestIssue('$path.title', '缺少或类型错误'));
      continue;
    }

    final entry = item['entry'];
    if (entry is! String || entry.trim().isEmpty) {
      errors.add(ManifestIssue('$path.entry', '缺少或类型错误'));
      continue;
    }
    final entryPath = entry.trim();
    if (entryPath.startsWith('/') || entryPath.contains('..')) {
      errors.add(ManifestIssue('$path.entry', '必须是包内相对路径，且不含 ".."'));
      continue;
    }
    if (!entryPath.toLowerCase().endsWith('.html')) {
      errors.add(ManifestIssue('$path.entry', '页面入口必须是 .html 文件'));
      continue;
    }

    final presentation = item['presentation']?.toString() ?? 'page';
    if (!allowedPresentations.contains(presentation)) {
      errors.add(ManifestIssue(
        '$path.presentation',
        '未知呈现方式 "$presentation"。可用：${allowedPresentations.join(" / ")}',
      ));
      continue;
    }

    final size = item['size'];
    int? width;
    int? height;
    if (size != null) {
      if (size is! Map) {
        errors.add(ManifestIssue('$path.size', '必须是对象'));
        continue;
      }
      final w = size['width'];
      final h = size['height'];
      if (w is num) width = w.toInt();
      if (h is num) height = h.toInt();
    }

    final permissions = <String>[];
    final rawPerms = item['permissions'];
    if (rawPerms is List) {
      for (var j = 0; j < rawPerms.length; j++) {
        final perm = rawPerms[j];
        if (perm is! String || !isKnownPermission(perm)) {
          errors.add(ManifestIssue('$path.permissions[$j]', '未知权限 "$perm"'));
          continue;
        }
        permissions.add(perm);
      }
    }

    final openFrom = <String>[];
    final rawOpenFrom = item['openFrom'];
    if (rawOpenFrom is List) {
      for (final e in rawOpenFrom) {
        if (e is String) openFrom.add(e);
      }
    }

    result.add(PageDeclaration(
      id: id.trim(),
      title: title.trim(),
      entry: entryPath,
      presentation: presentation,
      icon: item['icon']?.toString(),
      width: width,
      height: height,
      resizable: item['resizable'] != false,
      bridge: item['bridge'] != false,
      permissions: permissions,
      openFrom: openFrom,
    ));
  }
  return result;
}

/// 这个 ui 声明需不需要代码实现。
///
/// 判据只有一个：**有没有 onClick**。有回调就得有人接，
/// 那就必须有 runtime；只是"画出来"的话不需要。
///
/// 递归看子节点 —— 一个 section 自身没回调，但它的按钮可能有。
bool _uiDeclNeedsCode(UiDeclaration decl) {
  if ((decl.onClickEvent ?? '').isNotEmpty) return true;
  return decl.children.any(_uiDeclNeedsCode);
}