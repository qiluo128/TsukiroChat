/// 定位读取 + 权限询问弹窗。
///
/// ## 两件事放在一个文件的原因
///
/// 它们都是「系统工具在调用前需要用户同意」这条链路上的一环：
/// 定位要先问应用内权限（我们的体系），再问系统权限（Android 弹窗）。
/// 拆开写会让人漏掉第二层。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
/// 混成一句「获取位置失败」，模型会反复重试，而用户看到的是「AI 很笨」。
Future<Map<String, dynamic>> readCurrentLocation({
  Future<void> Function(String)? trace,
}) async {
  Future<void> mark(String s) async => trace == null ? null : trace(s);

  await SchedulerBinding.instance.endOfFrame;
  await mark('2. endOfFrame 完成');

  // ══════════════════════════════════════════════════════════════
  // **不预检，直接读。**
  //
  // 原来的顺序是「查定位开关 → 查权限 → 读坐标」，但鸿蒙的兼容层上
  // 这两个查询本身就不可信：可能返回 denied / 未开启，而实际上
  // 系统里是允许的。于是我们会在**真正读之前**就放弃，用户看到的是
  // "没有权限"，去设置里却又明明有。
  //
  // 改成直接尝试读取，用异常区分原因 —— 三种情况本来就应该说不同的话：
  //   没有权限       → 引导去系统设置
  //   超时           → 室内/信号弱，靠近窗户重试
  //   其它           → 原文透出
  // ══════════════════════════════════════════════════════════════

  try {
    await mark('3. 调用 getCurrentPosition');
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.medium,
        // **绕开 Google Play 服务。** geolocator 默认走
        // FusedLocationProviderClient —— 那是 GMS 的一部分。
        // 鸿蒙和所有没有 GMS 的国行机都没有它，这条路径会崩在原生层。
        forceLocationManager: true,
        timeLimit: const Duration(seconds: 20),
      ),
    );
    await mark('4. 成功');
    return <String, dynamic>{
      'latitude': pos.latitude,
      'longitude': pos.longitude,
      'accuracyMeters': pos.accuracy,
      'altitude': pos.altitude,
      'timestamp': pos.timestamp.toIso8601String(),
    };
  } on TimeoutException {
    await mark('X. 超时');
    throw LocationUnavailable(
        '定位超时（20 秒）。室内的 GPS 经常收不到信号 —— 靠近窗户或到户外再试。');
  } catch (e) {
    await mark('X. 失败: $e');
    final text = '$e';
    // 权限类失败才引导去设置
    if (text.contains('PERMISSION_DENIED') ||
        text.contains('permission') ||
        text.contains('Permission')) {
      throw LocationUnavailable(
        '定位权限被拒绝。请到 系统设置 → 应用 → Tsukiro Chat → 权限 → 位置 '
        '里选「使用期间允许」，然后回来再试。\n（原始错误：$text）');
    }
    throw LocationUnavailable('读取位置失败：$text');
  }
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

    // **用 showDialog，不自己 push DialogRoute。**
    //
    // showDialog 会做 InheritedTheme.capture() —— 手写的话对话框拿不到
    // Theme / MaterialLocalizations，AlertDialog 内部会抛。
    final result = await showDialog<ConfirmDecision>(
      context: nav.context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('允许「$pluginName」$label？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label),
            if ((reason ?? '').isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text('申请理由：$reason', style: const TextStyle(fontSize: 12)),
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
    );

    final decision = result ?? ConfirmDecision.deny;
    if (decision == ConfirmDecision.allowAlways) {
      _gatekeeper.setAlwaysAllowed(pluginId, permission);
    }
    return decision;
  }
}
