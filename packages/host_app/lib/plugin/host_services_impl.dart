/// 宿主对内核 [HostClock] / [HostUi] / [HostFiles] 等接口的实现。
///
/// ## 为什么这个文件之前不存在（真因）
///
/// 内核把"宿主能力"设计成**按类型注入的服务**（`call.require<HostClock>()`），
/// 这是好的解耦 —— 内核不认识任何具体的宿主实现。
///
/// 但我在 `plugin_providers.dart` 里只写了：
///
/// ```dart
/// final registry = PrimitiveRegistry(gatekeeper: ...);
/// registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
/// ```
///
/// **一个服务都没注入。** 于是所有需要宿主服务的原语（`sys.time`、`ui.toast`、
/// `fs.read`、`model.chat` …）必然抛「宿主未注入服务 …」——
/// 而链路的其他部分（Bridge、权限、工具调用）全都是通的，
/// 表现就是"插件跑起来了、工具调到了、但一执行就报错"。
library;

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

/// 全局 messenger key。
///
/// [HostUi.toast] 是在 widget 树之外被调用的（可能来自 WebView 的回调），
/// 拿不到 `BuildContext`，只能靠这个全局入口弹提示。
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

// ═══════════════════════════ 时钟 ═══════════════════════════

/// 设备时钟。
class AppHostClock implements HostClock {
  const AppHostClock();

  @override
  DateTime now() => DateTime.now();

  @override
  String get timezoneName => _localZoneName();

  @override
  DateTime? nowIn(String timezoneName) {
    final offset = _offsets[timezoneName];
    if (offset == null) return null;
    // DateTime.now() 是本地时间；先转到 UTC 再按目标偏移换算。
    // 用 `isUtc: false` + 手动偏移，因为 Dart 没有"任意时区"的原生支持
    // （那要 timezone 包 + 时区数据库，约 1 MB）。
    // 对"现在几点"这个用途，一张常见时区表就够了。
    final utc = DateTime.now().toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
      utc.millisecond,
    ).add(Duration(minutes: offset));
  }

  /// 设备本地时区名。
  ///
  /// Dart 拿不到 IANA 名（`DateTime.now().timeZoneName` 返回的是缩写如 "CST"，
  /// 而且各平台不一致）。所以从系统时区偏移反推一个最接近的常见时区名 ——
  /// **对用户来说"Asia/Shanghai"比"CST"有用得多**，后者还有歧义
  /// （CST 也可能是美国中部时间）。
  String _localZoneName() {
    final offset = DateTime.now().timeZoneOffset.inMinutes;
    for (final entry in _offsets.entries) {
      if (entry.value == offset) return entry.key;
    }
    return 'UTC${offset >= 0 ? '+' : '-'}'
        '${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:'
        '${(offset.abs() % 60).toString().padLeft(2, '0')}';
  }

  /// 常见 IANA 时区 → UTC 偏移（分钟）。
  ///
  /// **不含夏令时** —— 有夏令时的地区在夏令时期间会差一小时。
  /// 这是刻意的取舍：完整时区库要 1 MB 和一份会过期的数据，
  /// 而"现在几点"的场景里错一小时是可接受的，
  /// 装不上（体积翻倍）才是不可接受的。真有需要时再引 `timezone` 包。
  static const Map<String, int> _offsets = <String, int>{
    'Pacific/Honolulu': -600,
    'America/Anchorage': -540,
    'America/Los_Angeles': -480,
    'America/Denver': -420,
    'America/Chicago': -360,
    'America/New_York': -300,
    'America/Sao_Paulo': -180,
    'Atlantic/Azores': -60,
    'UTC': 0,
    'Europe/London': 0,
    'Europe/Paris': 60,
    'Europe/Berlin': 60,
    'Europe/Moscow': 180,
    'Asia/Dubai': 240,
    'Asia/Karachi': 300,
    'Asia/Kolkata': 330,
    'Asia/Dhaka': 360,
    'Asia/Bangkok': 420,
    'Asia/Shanghai': 480,
    'Asia/Hong_Kong': 480,
    'Asia/Taipei': 480,
    'Asia/Singapore': 480,
    'Asia/Kuala_Lumpur': 480,
    'Australia/Perth': 480,
    'Asia/Seoul': 540,
    'Asia/Tokyo': 540,
    'Australia/Adelaide': 570,
    'Australia/Sydney': 600,
    'Pacific/Auckland': 720,
  };
}

// ═══════════════════════════ 界面 ═══════════════════════════

/// 把插件的 UI 请求接到宿主的界面上。
class AppHostUi implements HostUi {
  const AppHostUi();

  @override
  void toast(String text, {Duration duration = const Duration(seconds: 3), String kind = 'info'}) {
    final messenger = appMessengerKey.currentState;
    if (messenger == null) {
      // 宿主界面还没准备好（比如插件在启动阶段就弹提示）。
      // **不抛异常** —— 一条提示弹不出来，不该让插件的整个操作失败。
      debugPrint('[plugin:ui] toast 丢弃（messenger 未就绪）：$text');
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: duration,
    ));
  }

  @override
  Future<String?> dialog({
    required String title,
    String? content,
    List<UiButton> buttons = const <UiButton>[],
  }) async {
    final context = appMessengerKey.currentContext;
    if (context == null) return null;

    // 插件没给按钮时给一个"知道了"，否则对话框关不掉
    final effective = buttons.isEmpty
        ? const <UiButton>[UiButton('ok', '知道了')]
        : buttons;

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: content == null ? null : Text(content),
        actions: <Widget>[
          for (final b in effective)
            TextButton(
              onPressed: () => Navigator.pop(ctx, b.id),
              child: Text(b.label),
            ),
        ],
      ),
    );
  }

  @override
  Future<bool> navigate(String pageId, {Map<String, dynamic>? params}) async {
    // 插件独立页面（`provides.pages`）需要 WebView 弹层，
    // 属于后续工作。**明确返回 false**，而不是假装成功 ——
    // 插件据此可以降级，而不是卡在"以为打开了"的状态。
    debugPrint('[plugin:ui] 插件页面 $pageId 尚未支持');
    return false;
  }

  @override
  Future<void> close() async {
    final context = appMessengerKey.currentContext;
    if (context != null && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Future<void> setTitle(String title) async {
    // 宿主只有插件页面才有"容器标题"的概念，而插件页面还没做
    debugPrint('[plugin:ui] setTitle("$title") 暂不支持');
  }
}

// ═══════════════════════════ 装配 ═══════════════════════════

/// 组装宿主服务注册表。
///
/// [primitiveRegistry] 与 [hookBus] 也注册进去了 —— 因为
/// `primitive.list` / `host.capabilities` / `hook.phases` 这三个原语
/// 要向宿主**自省**，它们需要的就是这两个对象本身。
///
/// 没注册的服务（`HostFiles` / `SandboxProvider` / `ModelGateway`）
/// 会让对应原语抛出明确的「宿主未注入服务 X」——
/// 这是**如实报错**，比返回假数据好：插件能据此知道宿主还不支持，
/// 而不是拿到一个看起来成功的空结果。
ServiceRegistry buildHostServices({
  required PrimitiveRegistry primitiveRegistry,
  required HookBus hookBus,
  ModelGateway? modelGateway,
}) {
  final services = ServiceRegistry();
  services
    ..put<HostClock>(const AppHostClock())
    ..put<HostUi>(const AppHostUi())
    ..put<PrimitiveRegistry>(primitiveRegistry)
    ..put<HookBus>(hookBus);
  if (modelGateway != null) services.put<ModelGateway>(modelGateway);
  return services;
}
