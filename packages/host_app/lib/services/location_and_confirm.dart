/// 定位读取 + 权限询问弹窗。
///
/// ## 两件事放在一个文件的原因
///
/// 它们都是"系统工具在调用前需要用户同意"这条链路上的一环：
/// 定位要先问应用内权限（我们的体系），再问系统权限（Android 弹窗）。
/// 拆开写会让人漏掉第二层。
library;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:plugin_core/plugin_core.dart';

import '../plugin/app_keys.dart';

// ═══════════════════════ 定位 ═══════════════════════

class LocationUnavailable implements Exception {
  LocationUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 读当前位置。
///
/// **三种失败要分开说**，因为它们对用户的意义完全不同：
///
/// | 情况 | 用户要做什么 |
/// |---|---|
/// | 定位服务没开 | 去下拉快捷菜单打开 |
/// | 系统权限被拒（还能再问） | 再点一次会重新弹窗 |
/// | 系统权限永久拒绝 | 只能去设置里手动开 |
///
/// 混成一句"获取位置失败"，模型会反复重试，而用户看到的是"AI 很笨"。
Future<Map<String, dynamic>> readCurrentLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw LocationUnavailable('设备的定位服务没有开启 —— 请打开系统定位开关');
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    throw LocationUnavailable('你拒绝了系统定位权限 —— 再试一次会重新弹窗');
  }
  if (permission == LocationPermission.deniedForever) {
    throw LocationUnavailable(
        '系统定位权限被永久拒绝 —— 需要去系统设置里手动为本应用开启');
  }

  final pos = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.medium,
      timeLimit: Duration(seconds: 15),
    ),
  );

  return <String, dynamic>{
    'latitude': pos.latitude,
    'longitude': pos.longitude,
    'accuracyMeters': pos.accuracy,
    'altitude': pos.altitude,
    'timestamp': pos.timestamp.toIso8601String(),
  };
}

/// 给插件原语用的 `HostLocation` 实现。
class AppHostLocation implements HostLocation {
  const AppHostLocation();

  @override
  Future<Map<String, dynamic>> current() async {
    try {
      return await readCurrentLocation();
    } on LocationUnavailable catch (e) {
      throw TsukiroException(TsukiroErrorCode.permissionDenied, e.message);
    }
  }
}

// ═══════════════════════ 权限询问 ═══════════════════════

// appNavigatorKey 来自 plugin/app_keys.dart —— 那里已经有一个，
// 而且 MaterialApp 已经接上了它。重复定义会让 app.dart 出现二义导入。

enum ConfirmDecision {
  /// 只允许这一次。
  allowOnce,

  /// 以后不再问这个插件的这个权限。
  ///
  /// **记忆的粒度是「插件」，不是「智能体」** —— 信任是对代码的判断，
  /// 换智能体跑的是同一份代码（见 docs/27 §5）。
  allowAlways,

  deny,
}

class ConfirmationBroker {
  ConfirmationBroker(this._gatekeeper);

  final Gatekeeper _gatekeeper;

  /// 弹框并等用户决定。
  ///
  /// 拿不到 Navigator（比如应用还没起来）就直接拒绝 —— **fail-closed**。
  Future<ConfirmDecision> ask({
    required String pluginId,
    required String permission,
    required String pluginName,
    String? reason,
  }) async {
    final nav = appNavigatorKey.currentState;
    if (nav == null) return ConfirmDecision.deny;

    // 权限目录里的 PermissionSpec 没有简短的显示名，
    // 直接用权限 id —— 它本身就是可读的（location / media.read…）
    final label = permission;

    final result = await nav.push<ConfirmDecision>(
      DialogRoute<ConfirmDecision>(
        context: nav.context,
        builder: (ctx) => AlertDialog(
          title: Text('允许「$pluginName」$label？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label),
              if ((reason ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text('申请理由：$reason',
                    style: const TextStyle(fontSize: 12)),
              ],
              const SizedBox(height: 12),
              const Text(
                '「始终允许」会记住这个决定，以后这个插件不再询问。\n'
                '它只针对这个插件，不区分智能体。',
                style: TextStyle(fontSize: 11.5),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, ConfirmDecision.deny),
              child: const Text('拒绝'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ConfirmDecision.allowOnce),
              child: const Text('允许一次'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ConfirmDecision.allowAlways),
              child: const Text('始终允许此权限'),
            ),
          ],
        ),
      ),
    );

    final decision = result ?? ConfirmDecision.deny;
    if (decision == ConfirmDecision.allowAlways) {
      _gatekeeper.setAlwaysAllowed(pluginId, permission);
    }
    return decision;
  }
}
