/// 安装状态机 —— 从 zip 字节到「已装好且已注册」。
///
/// 见 `docs/03-architecture.md` §4.3 与 `docs/04-plugin-spec.md` §3。
///
/// **核心要求是原子性**：任何一步失败，磁盘上不得留下任何残留。
/// 实现方式：先解压到**临时目录**，全部校验与授权通过后再原子 rename 到最终目录。
/// 如果先落地再删，"删"这一步本身也可能失败（进程被杀、磁盘满），就留下半成品了。
///
/// 顺序也是安全策略：
/// ```
/// 包检查 → manifest → 宿主兼容 → 权限声明 → 【用户授权】 → 落盘 → 注册
///                                    ↑
///                          必须在落盘之前
/// ```
/// 用户拒绝时磁盘上什么都没有，也就不存在"先写再删"的竞态。
library;

import 'dart:typed_data';

import '../audit/audit.dart';
import '../common/errors.dart';
import '../common/semver.dart';
import '../manifest/manifest.dart';
import '../manifest/parser.dart';
import '../packaging/zip_reader.dart';
import '../permission/gatekeeper.dart';
import '../registry/slot_registry.dart';
import '../registry/tool_registry.dart';

/// 安装流程所处的状态。
enum InstallState {
  idle,

  /// 正在做包检查与 manifest 解析。
  validating,

  /// 等用户对权限弹窗做决定。
  awaitingConsent,

  /// 已解压到临时目录，准备提交。
  staging,

  /// 临时目录 → 最终目录。
  committing,

  /// 装好了。
  installed,

  /// 被拒绝（包非法 / manifest 非法 / 不兼容 / 用户拒绝）。
  rejected,

  /// 提交阶段出错（磁盘问题），已回滚。
  failed,
}

/// 用户的授权决定。
enum ConsentDecision {
  /// 全部同意。
  grantAll,

  /// 只授予这些权限（插件需能降级运行）。
  grantPartial,

  /// 拒绝安装。
  deny,
}

/// 授权结果。
class ConsentResult {
  const ConsentResult(this.decision, {this.granted = const <String>[]});

  const ConsentResult.grantAll()
      : decision = ConsentDecision.grantAll,
        granted = const <String>[];

  const ConsentResult.deny()
      : decision = ConsentDecision.deny,
        granted = const <String>[];

  final ConsentDecision decision;

  /// [ConsentDecision.grantPartial] 时生效。
  final List<String> granted;
}

/// 宿主向用户征求授权的回调（真实环境里弹原生弹窗）。
typedef ConsentCallback = Future<ConsentResult> Function(
  PluginManifest manifest,
  List<DeclaredPermission> permissions,
);

/// 插件在磁盘上的落点。抽成接口，让安装流程可以脱离真实文件系统单测。
abstract class PluginStore {
  /// 建一个临时目录，返回其句柄。
  Future<String> createStaging(String pluginId, String version);

  /// 往临时目录写文件。
  Future<void> writeStagingFile(String staging, String relativePath, List<int> bytes);

  /// 原子提交：临时目录 → 最终目录。**必须是一次 rename**，不能是复制。
  Future<void> commitStaging(String staging, String pluginId, String version);

  /// 丢弃临时目录。
  Future<void> discardStaging(String staging);

  /// 删除某个插件的全部版本目录。
  Future<void> removePlugin(String pluginId);

  /// 已安装的版本；未装返回 null。
  Future<String?> installedVersion(String pluginId);

  /// 设置「当前启用版本」指针。
  Future<void> setCurrentVersion(String pluginId, String version);
}

/// 安装结果。
class InstallResult {
  const InstallResult({
    required this.ok,
    required this.state,
    this.manifest,
    this.grantedPermissions = const <String>[],
    this.issues = const <String>[],
    this.warnings = const <String>[],
    this.failedAt,
  });

  final bool ok;
  final InstallState state;
  final PluginManifest? manifest;
  final List<String> grantedPermissions;

  /// 导致失败的问题。
  final List<String> issues;

  /// 不阻止安装但需要告知的（如用了宿主不认识的插槽）。
  final List<String> warnings;

  /// 哪一步失败：`package` / `manifest` / `compatibility` / `permissions` /
  /// `consent` / `commit`。
  final String? failedAt;

  @override
  String toString() => ok
      ? 'InstallResult(ok: ${manifest?.id}@${manifest?.version}, 授权 ${grantedPermissions.length} 项)'
      : 'InstallResult(REJECTED@$failedAt: ${issues.join("; ")})';
}

/// 安装器。
class Installer {
  Installer({
    required this.store,
    required this.gatekeeper,
    required this.tools,
    this.slots,
    AuditSink? audit,
    this.hostVersion = '1.0.0',
    this.zipReader = const ZipReader(),
  }) : audit = audit ?? const NullAuditSink();

  final PluginStore store;
  final Gatekeeper gatekeeper;
  final ToolRegistry tools;
  final SlotRegistry? slots;
  final AuditSink audit;
  final String hostVersion;
  final ZipReader zipReader;

  /// 走完整安装流程。
  ///
  /// [consent] 在**落盘之前**调用。若为 null，视为"不征求、全部同意"
  /// （只用于测试；真实宿主必须传）。
  Future<InstallResult> install(
    Uint8List zipBytes, {
    ConsentCallback? consent,
    bool replaceExisting = false,
  }) async {
    // ── ① 包检查 ──
    final PluginArchive archive;
    try {
      archive = zipReader.read(zipBytes);
    } on TsukiroException catch (e) {
      return _reject('package', <String>[e.message]);
    }

    if (!archive.inspection.isSafe) {
      return _reject(
        'package',
        archive.inspection.fatalIssues.map((i) => i.toString()).toList(growable: false),
      );
    }

    // ── ② manifest ──
    final json = archive.readJson('manifest.json');
    if (json == null) {
      return _reject('manifest', <String>['包内没有 manifest.json']);
    }
    final parsed = parseManifest(json);
    if (!parsed.isValid) {
      return _reject(
        'manifest',
        parsed.issues.map((i) => i.toString()).toList(growable: false),
      );
    }
    final manifest = parsed.manifest!;
    final warnings = <String>[];

    // ── ③ 宿主兼容 ──
    final incompat = checkHostCompatibility(manifest, hostVersion);
    if (incompat != null) {
      return _reject('compatibility', <String>[incompat], manifest: manifest);
    }

    // ── ④ 权限声明合法性 ──
    final rejectedPerms = gatekeeper.validateForInstall(manifest.permissionNames);
    if (rejectedPerms.isNotEmpty) {
      return _reject(
        'permissions',
        <String>['宿主不接受的权限：${rejectedPerms.join(", ")}'],
        manifest: manifest,
      );
    }

    // ── ⑤ 已装版本处理 ──
    final existing = await store.installedVersion(manifest.id);
    if (existing != null && !replaceExisting) {
      final existingSemver = SemVer.tryParse(existing);
      if (existingSemver != null && existingSemver > manifest.semver) {
        return _reject(
          'commit',
          <String>['已安装更新的版本 $existing，不能降级到 ${manifest.version}（除非显式允许）'],
          manifest: manifest,
        );
      }
    }

    // ── ⑥ 用户授权（**必须在落盘之前**） ──
    final requested = <DeclaredPermission>[...manifest.permissions];

    ConsentResult consentResult;
    if (consent == null) {
      consentResult = const ConsentResult.grantAll();
    } else {
      consentResult = await consent(manifest, requested);
    }

    if (consentResult.decision == ConsentDecision.deny) {
      _audit(manifest, 'plugin.install', 'denied', <String, dynamic>{'reason': '用户拒绝'});
      return InstallResult(
        ok: false,
        state: InstallState.rejected,
        manifest: manifest,
        issues: const <String>['用户取消了安装'],
        failedAt: 'consent',
      );
    }

    // ── ⑦ 落盘（临时目录 → 原子提交） ──
    String? staging;
    try {
      staging = await store.createStaging(manifest.id, manifest.version);

      for (final path in archive.paths) {
        final bytes = archive.readBytes(path);
        if (bytes == null) continue;
        await store.writeStagingFile(staging, path, bytes);
      }

      await store.commitStaging(staging, manifest.id, manifest.version);
      await store.setCurrentVersion(manifest.id, manifest.version);
      staging = null; // 已提交，不需要清理
    } catch (e) {
      if (staging != null) {
        // 尽力清理；清理失败也不能掩盖真实错误
        try {
          await store.discardStaging(staging);
        } catch (_) {}
      }
      _audit(manifest, 'plugin.install', 'error', <String, dynamic>{'error': '$e'});
      return InstallResult(
        ok: false,
        state: InstallState.failed,
        manifest: manifest,
        issues: <String>['写入磁盘失败：$e'],
        failedAt: 'commit',
      );
    }

    // ── ⑧ 注册 ──
    final unknownPerms = gatekeeper.registerPlugin(manifest.id, manifest.permissionNames);
    if (unknownPerms.isNotEmpty) {
      // 到这一步才出问题说明前面的校验漏了 —— 回滚磁盘，不留下半成品
      await store.removePlugin(manifest.id);
      return _reject(
        'permissions',
        <String>['未知权限：${unknownPerms.join(", ")}'],
        manifest: manifest,
      );
    }

    tools.registerPlugin(manifest);
    final unknownSlots = slots?.registerPlugin(manifest) ?? const <String>[];
    if (unknownSlots.isNotEmpty) {
      warnings.add(
        '该插件使用了本版本不支持的插槽：${unknownSlots.toSet().join(", ")}（相关控件不会显示）',
      );
    }

    // ── ⑨ 授权 ──
    final toGrant = switch (consentResult.decision) {
      ConsentDecision.grantAll => manifest.permissionNames,
      ConsentDecision.grantPartial => consentResult.granted,
      ConsentDecision.deny => const <String>[],
    };
    final granted = gatekeeper.grantAll(manifest.id, toGrant);

    _audit(manifest, 'plugin.install', 'ok', <String, dynamic>{
      'declared': manifest.permissionNames,
      'granted': granted,
    });

    return InstallResult(
      ok: true,
      state: InstallState.installed,
      manifest: manifest,
      grantedPermissions: granted,
      warnings: warnings,
    );
  }

  /// 卸载：**磁盘、权限、工具、插槽四处都要清**。
  ///
  /// 漏掉任何一处都会留下"已卸载但仍在生效"的幽灵。
  Future<void> uninstall(String pluginId) async {
    tools.unregisterPlugin(pluginId);
    slots?.unregisterPlugin(pluginId);
    gatekeeper.unregisterPlugin(pluginId);
    await store.removePlugin(pluginId);

    audit.write(AuditEntry(
      pluginId: pluginId,
      kind: 'plugin',
      primitive: 'plugin.uninstall',
      result: 'ok',
    ));
  }

  InstallResult _reject(
    String failedAt,
    List<String> issues, {
    PluginManifest? manifest,
  }) {
    if (manifest != null) {
      _audit(manifest, 'plugin.install', 'error', <String, dynamic>{
        'failedAt': failedAt,
        'issues': issues,
      });
    }
    return InstallResult(
      ok: false,
      state: InstallState.rejected,
      manifest: manifest,
      issues: issues,
      failedAt: failedAt,
    );
  }

  void _audit(
    PluginManifest manifest,
    String primitive,
    String result,
    Map<String, dynamic> digest,
  ) {
    audit.write(AuditEntry(
      pluginId: manifest.id,
      pluginVersion: manifest.version,
      kind: 'plugin',
      primitive: primitive,
      argsDigest: digest,
      result: result,
    ));
  }
}

/// 内存版插件存储 —— 测试用，也让"无头 demo"不必碰真实磁盘。
class InMemoryPluginStore implements PluginStore {
  final Map<String, Map<String, Uint8List>> _tree = <String, Map<String, Uint8List>>{};
  final Map<String, String> _current = <String, String>{};
  final Map<String, int> _stagingCounter = <String, int>{};

  /// 记录调用顺序，便于断言"先 staging 后 commit"。
  final List<String> trace = <String>[];

  /// 置为非 null 时，commitStaging 会抛这个错误（测回滚路径）。
  Object? failCommitWith;

  @override
  Future<String> createStaging(String pluginId, String version) async {
    final n = (_stagingCounter[pluginId] ?? 0) + 1;
    _stagingCounter[pluginId] = n;
    final path = '__staging__/$pluginId/$version/$n';
    _tree[path] = <String, Uint8List>{};
    trace.add('createStaging:$pluginId@$version');
    return path;
  }

  @override
  Future<void> writeStagingFile(String staging, String relativePath, List<int> bytes) async {
    final dir = _tree[staging];
    if (dir == null) throw StateError('staging 不存在: $staging');
    dir[relativePath] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> commitStaging(String staging, String pluginId, String version) async {
    trace.add('commitStaging:$pluginId@$version');
    final failure = failCommitWith;
    if (failure != null) {
      throw failure is String ? StateError(failure) : failure;
    }
    final dir = _tree.remove(staging);
    if (dir == null) throw StateError('staging 不存在: $staging');
    _tree['$pluginId/$version'] = dir;
  }

  @override
  Future<void> discardStaging(String staging) async {
    trace.add('discardStaging:$staging');
    _tree.remove(staging);
  }

  @override
  Future<void> removePlugin(String pluginId) async {
    trace.add('removePlugin:$pluginId');
    _tree.removeWhere((k, _) => k.startsWith('$pluginId/'));
    _current.remove(pluginId);
  }

  @override
  Future<String?> installedVersion(String pluginId) async => _current[pluginId];

  @override
  Future<void> setCurrentVersion(String pluginId, String version) async {
    _current[pluginId] = version;
  }

  // ── 测试辅助 ──

  /// 是否还有临时目录残留。
  bool get hasStagingLeftover => _tree.keys.any((k) => k.startsWith('__staging__/'));

  List<String> filesOf(String pluginId, String version) =>
      (_tree['$pluginId/$version'] ?? const <String, Uint8List>{}).keys.toList()..sort();

  void clear() {
    _tree.clear();
    _current.clear();
    _stagingCounter.clear();
    trace.clear();
    failCommitWith = null;
  }
}
