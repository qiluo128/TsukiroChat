/// Tsukiro Chat 插件内核。
///
/// **纯 Dart，无 Flutter 依赖** —— 这是刻意的约束（见 ADR-002）：
/// 插件系统的技术风险（manifest 校验、权限守门、Bridge 编解码、Zip Slip 防护、
/// 工具循环）全部是纯逻辑，能在桌面用 `dart test` 测透，就不必在
/// 「Flutter + Android + WebView + JS + Dart」五层里混合调试。
///
/// 用法概览：
///
/// ```dart
/// import 'package:plugin_core/plugin_core.dart';
///
/// final result = parseManifestJson(manifestSource);
/// if (!result.isValid) {
///   for (final issue in result.issues) {
///     print('${issue.path}: ${issue.message}');
///   }
///   return;
/// }
/// final manifest = result.manifest!;
///
/// final gatekeeper = Gatekeeper();
/// gatekeeper.registerPlugin(manifest.id, manifest.permissionNames);
/// gatekeeper.grant(manifest.id, 'sys.time');
///
/// final tools = ToolRegistry();
/// tools.registerPlugin(manifest);
///
/// final guard = SandboxPathGuard('/data/app/sandbox/${manifest.id}/data');
/// final abs = guard.resolve('notes/a.txt');    // 越界会抛 TsukiroException
/// ```
library;

export 'src/bridge/envelope.dart';
export 'src/common/errors.dart';
export 'src/common/semver.dart';
export 'src/manifest/manifest.dart';
export 'src/manifest/parser.dart';
export 'src/packaging/package_inspector.dart';
export 'src/packaging/zip_reader.dart';
export 'src/permission/gatekeeper.dart';
export 'src/permission/permission.dart';
export 'src/registry/tool_registry.dart';
export 'src/sandbox/path_guard.dart';
