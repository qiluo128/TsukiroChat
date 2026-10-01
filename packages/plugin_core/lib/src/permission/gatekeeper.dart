/// 权限守门人 —— **宿主侧唯一的权限校验点**。
///
/// ## 为什么必须在这里校验
///
/// 直觉做法是「没授权的原语就不注入到插件的 `tsukiro` 对象上」。但 JS 层过滤
/// 可被轻易绕过：
///
/// ```js
/// const chat = tsukiro.model.chat;   // 授权时保存引用
/// // …用户撤销授权后…
/// await chat({ ... });               // 仍然能调
///
/// const fn = Object.getPrototypeOf(tsukiro.model).chat;   // 绕过注入
/// ```
///
/// 因此接口注入只做「便利层」，**权威判定在这里**。
/// 见 `docs/06-permissions.md` §1.1 与 ADR-003。
///
/// ## 声明即上限
///
/// 插件只能调用自己在 manifest 里声明过的权限，**即使该权限已授予其他插件**。
library;

import '../common/errors.dart';
import 'permission.dart';

/// 校验结论。
enum GateDecision {
  /// 通过，可以执行。
  allow,

  /// 插件未注册（未安装 / 已停用）。
  unknownPlugin,

  /// 权限名不在目录中（拼错或版本不匹配）。
  unknownPermission,

  /// 该权限为宿主保留的 `denied` 级。
  deniedLevel,

  /// 插件 manifest 未声明该权限。**声明即上限。**
  notDeclared,

  /// 插件声明了但用户未授予。
  notGranted,

  /// 属「每次确认」级别，需要弹原生确认框后再执行。
  confirmRequired,
}

/// 校验结果。
class GateResult {
  const GateResult(this.decision, {this.permission, this.message});

  const GateResult.allow(this.permission)
      : decision = GateDecision.allow,
        message = null;

  final GateDecision decision;
  final String? permission;
  final String? message;

  /// 是否可以直接执行（`confirmRequired` 不算通过）。
  bool get isAllowed => decision == GateDecision.allow;

  /// 是否应当弹出确认框后重试。
  bool get needsConfirmation => decision == GateDecision.confirmRequired;

  /// 转成给插件的异常；[isAllowed] 为 true 时抛 [StateError]（调用方用错了）。
  TsukiroException toException() {
    final perm = permission ?? '<unknown>';
    switch (decision) {
      case GateDecision.allow:
        throw StateError('GateResult.isAllowed 为 true，不应转成异常');
      case GateDecision.unknownPlugin:
        return TsukiroException(
          TsukiroErrorCode.permissionDenied,
          '插件未安装或已停用: ${message ?? ""}'.trim(),
          details: <String, dynamic>{'permission': perm},
        );
      case GateDecision.unknownPermission:
        return TsukiroException(
          TsukiroErrorCode.permissionDenied,
          '未知权限: $perm',
          details: <String, dynamic>{'permission': perm},
        );
      case GateDecision.deniedLevel:
        return TsukiroException(
          TsukiroErrorCode.permissionDenied,
          '权限 $perm 不允许插件使用',
          details: <String, dynamic>{'permission': perm},
        );
      case GateDecision.notDeclared:
        return TsukiroException(
          TsukiroErrorCode.permissionDenied,
          '插件未在 manifest 中声明权限 $perm（声明即上限）',
          details: <String, dynamic>{'permission': perm},
        );
      case GateDecision.notGranted:
        return TsukiroException.permissionDenied(perm);
      case GateDecision.confirmRequired:
        return TsukiroException(
          TsukiroErrorCode.confirmRequired,
          '权限 $perm 需要用户每次确认',
          details: <String, dynamic>{'permission': perm},
        );
    }
  }

  @override
  String toString() =>
      'GateResult(${decision.name}${permission == null ? '' : ', $permission'})';
}

/// 权限守门人。
///
/// 全部状态在内存中，[check] 是热路径（每次原语调用都会走），
/// 因此**不做任何 IO**。生产实现需在授权/撤销时双写持久层。
class Gatekeeper {
  Gatekeeper();

  /// pluginId → 该插件在 manifest 中声明的权限集合。
  final Map<String, Set<String>> _declared = <String, Set<String>>{};

  /// pluginId → 用户已授予的权限集合。
  final Map<String, Set<String>> _granted = <String, Set<String>>{};

  /// 插件注册（安装时调用）。
  ///
  /// 会过滤掉未知权限名并返回它们，供安装流程报错 —— 拼错权限名如果静默忽略，
  /// 插件会在运行时莫名失败，极难排查。
  List<String> registerPlugin(String pluginId, Iterable<String> declaredPermissions) {
    final unknown = <String>[];
    final accepted = <String>{};
    for (final p in declaredPermissions) {
      if (isKnownPermission(p)) {
        accepted.add(p);
      } else {
        unknown.add(p);
      }
    }
    _declared[pluginId] = accepted;
    _granted.putIfAbsent(pluginId, () => <String>{});
    return unknown;
  }

  /// 插件卸载 / 停用。
  void unregisterPlugin(String pluginId) {
    _declared.remove(pluginId);
    _granted.remove(pluginId);
  }

  /// 该插件是否已注册。
  bool isRegistered(String pluginId) => _declared.containsKey(pluginId);

  /// 该插件声明的权限（只读快照）。
  Set<String> declaredOf(String pluginId) =>
      Set<String>.unmodifiable(_declared[pluginId] ?? const <String>{});

  /// 该插件已被授予的权限（只读快照）。
  Set<String> grantedOf(String pluginId) =>
      Set<String>.unmodifiable(_granted[pluginId] ?? const <String>{});

  /// 授权。只能授予插件**已声明**的权限。
  ///
  /// 返回 false 表示插件未注册或未声明该权限。
  bool grant(String pluginId, String permission) {
    final declared = _declared[pluginId];
    if (declared == null || !declared.contains(permission)) return false;
    if (levelOf(permission) == PermissionLevel.denied) return false;
    _granted.putIfAbsent(pluginId, () => <String>{}).add(permission);
    return true;
  }

  /// 批量授权，返回实际授予成功的权限列表。
  List<String> grantAll(String pluginId, Iterable<String> permissions) {
    final done = <String>[];
    for (final p in permissions) {
      if (grant(pluginId, p)) done.add(p);
    }
    return done;
  }

  /// 撤销授权。撤销后**下一次调用立即失败**（无需重启）。
  bool revoke(String pluginId, String permission) {
    final g = _granted[pluginId];
    if (g == null) return false;
    return g.remove(permission);
  }

  /// 撤销该插件的全部权限。返回被撤销的权限列表。
  List<String> revokeAll(String pluginId) {
    final g = _granted[pluginId];
    if (g == null || g.isEmpty) return const <String>[];
    final revoked = g.toList(growable: false);
    g.clear();
    return revoked;
  }

  /// 安装期检查：manifest 申请的权限是否可接受。
  ///
  /// 返回不可接受的权限名列表（`denied` 级或未知）。空列表表示可以安装。
  List<String> validateForInstall(Iterable<String> requestedPermissions) {
    final rejected = <String>[];
    for (final p in requestedPermissions) {
      final spec = lookupPermission(p);
      if (spec == null || spec.level == PermissionLevel.denied) {
        rejected.add(p);
      }
    }
    return rejected;
  }

  /// **核心校验**。每次原语调用都必须走这里。
  ///
  /// 判定顺序（顺序本身就是安全策略，不要调整）：
  ///   1. 插件是否已注册
  ///   2. 权限名是否存在于目录
  ///   3. 是否为 `denied` 级
  ///   4. 插件是否声明（声明即上限）
  ///   5. 用户是否已授予
  ///   6. 是否为 `confirm` 级 → 需弹确认框
  GateResult check(String pluginId, String? permission) {
    // 无需权限的原语
    if (permission == null) {
      if (!isRegistered(pluginId)) {
        return GateResult(GateDecision.unknownPlugin,
            message: pluginId);
      }
      return const GateResult.allow(null);
    }

    final declared = _declared[pluginId];
    if (declared == null) {
      return GateResult(GateDecision.unknownPlugin, permission: permission, message: pluginId);
    }

    final spec = lookupPermission(permission);
    if (spec == null) {
      return GateResult(GateDecision.unknownPermission, permission: permission);
    }

    if (spec.level == PermissionLevel.denied) {
      return GateResult(GateDecision.deniedLevel, permission: permission);
    }

    if (!declared.contains(permission)) {
      return GateResult(GateDecision.notDeclared, permission: permission);
    }

    if (!(_granted[pluginId]?.contains(permission) ?? false)) {
      return GateResult(GateDecision.notGranted, permission: permission);
    }

    if (spec.level == PermissionLevel.confirm) {
      return GateResult(GateDecision.confirmRequired, permission: permission);
    }

    return GateResult.allow(permission);
  }

  /// 便捷方式：按原语名校验（内部查 [requiredPermissionFor]）。
  GateResult checkPrimitive(String pluginId, String primitive) =>
      check(pluginId, requiredPermissionFor(primitive));

  /// 该插件当前可用的权限 = 已声明 ∩ 已授予（用于过滤工具与插槽）。
  Set<String> effectivePermissions(String pluginId) {
    final declared = _declared[pluginId];
    final granted = _granted[pluginId];
    if (declared == null || granted == null) return const <String>{};
    return declared.intersection(granted);
  }

  /// 测试与持久化用：导出全部状态。
  Map<String, dynamic> exportState() => <String, dynamic>{
        'declared': _declared.map((k, v) => MapEntry(k, v.toList())),
        'granted': _granted.map((k, v) => MapEntry(k, v.toList())),
      };

  /// 测试与持久化用：从导出状态恢复。
  void importState(Map<String, dynamic> state) {
    _declared.clear();
    _granted.clear();
    final declared = state['declared'];
    if (declared is Map) {
      declared.forEach((key, value) {
        _declared['$key'] = (value as List).map((e) => '$e').toSet();
      });
    }
    final granted = state['granted'];
    if (granted is Map) {
      granted.forEach((key, value) {
        _granted['$key'] = (value as List).map((e) => '$e').toSet();
      });
    }
  }
}
