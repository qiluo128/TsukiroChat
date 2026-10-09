/// 能力市场的宿主实现。
///
/// **插件之间不能直连**，必须经过这里。权限、超时、审计、
/// 递归深度、失败隔离全在这一层 —— 绕过它这些都保不住。
///
/// 见 `packages/plugin_core/lib/src/capability/capability.dart`。
library;

import 'package:plugin_core/plugin_core.dart';

import '../plugin/plugin_host.dart';

class AppCapability implements HostCapability {
  AppCapability({
    required this.registry,
    required this.gatekeeper,
    required this.hostResolver,
    AuditSink? audit,
  }) : audit = audit ?? const NullAuditSink();

  final CapabilityRegistry registry;
  final Gatekeeper gatekeeper;

  /// 拿 PluginHost。**用回调而不是直接持有** ——
  /// 宿主与能力服务互相依赖，直接持有会形成构造循环。
  final PluginHost? Function() hostResolver;

  final AuditSink audit;

  /// **在途的提供方** —— 用来检测环路。
  ///
  /// 深度计数在这里是没用的：A 调 B 时，B 再调 A 是一次**全新的原语调用**，
  /// depth 又从 0 开始。所以「maxCapabilityDepth」那个数字在真实链路里
  /// 永远不会触发 —— 它是个摆设。
  ///
  /// 而「A 还在执行中，却又被调到」是**能直接测出来的**，
  /// 不需要跨 Bridge 传深度。环路的本质就是这个。
  final Set<String> _inFlight = <String>{};

  @override
  Future<CapabilityResult> invoke(
    String callerPluginId,
    CapabilityRequest request, {
    int depth = 0,
  }) async {
    // ── 递归深度 ──
    //
    // 两个互相调用的插件会一直转下去，而且是跨 WebView 的递归，
    // 从堆栈上看不出来。所以显式设限。
    if (depth >= maxCapabilityDepth) {
      return CapabilityResult.failure(
        'recursionLimit',
        '能力调用超过 $maxCapabilityDepth 层。'
        '插件之间可能互相递归了（${request.qualified}）。',
      );
    }

    // ── 找到提供方 ──
    final RegisteredCapability? cap;
    if (request.providerId.isNotEmpty) {
      cap = registry.find(request.providerId, request.name);
      if (cap == null) {
        return CapabilityResult.failure(
          'capabilityNotFound',
          '插件「${request.providerId}」没有提供能力「${request.name}」',
        );
      }
    } else {
      final matches = registry.findByName(request.name);
      if (matches.isEmpty) {
        return CapabilityResult.failure(
          'capabilityNotFound',
          '没有任何插件提供能力「${request.name}」',
        );
      }
      if (matches.length > 1) {
        // **不替调用方猜。** "用本地还是云端"是它的决定，
        // 宿主挑错了是静默的错误行为。
        final providers = matches.map((m) => m.providerId).join('、');
        return CapabilityResult.failure(
          'ambiguousCapability',
          '有 ${matches.length} 个插件提供「${request.name}」：$providers。'
          '请用 provider 指明要哪个。',
        );
      }
      cap = matches.single;
    }

    // ── 权限（动态：按调用方 + 提供方 + 名字） ──
    //
    // 门禁那层只判了"这个插件允不允许调能力"（capability.invoke）。
    // 具体能不能调**这一个**，在这里判。
    final check = gatekeeper.check(callerPluginId, cap.permission);
    if (!check.isAllowed) {
      return CapabilityResult.failure(
        'permissionDenied',
        '「${cap.providerName}」提供的能力「${cap.name}」需要权限 '
        '${cap.permission}，而这个插件没有被授予它。',
      );
    }

    // ── 路由 ──
    final host = hostResolver();
    if (host == null) {
      return CapabilityResult.failure('noRuntime', '插件系统还没就绪');
    }

    // ── 环路检测 ──
    //
    // 提供方已经在执行中，说明这次的调用链回到了它身上
    // （A→B→A，或更长的环）。继续下去会无限递归，
    // 而且是跨 WebView 的递归，从堆栈上看不出来。
    if (_inFlight.contains(cap.providerId)) {
      return CapabilityResult.failure(
        'recursionLimit',
        '检测到循环调用：「${cap.providerName}」已经在执行中，'
        '却又被调到了（${cap.name}）。请检查两个插件是不是互相调用。',
      );
    }

    _inFlight.add(cap.providerId);
    final ToolInvocationResult result;
    try {
      result = await host.invokeCapability(
        cap.providerId,
        cap.declaration.handler,
        request.args,
      );
    } finally {
      // **必须在 finally 里清** —— 抛异常时不清的话，
      // 这个提供方就永远卡在"在途"里，之后谁都调不动它。
      _inFlight.remove(cap.providerId);
    }

    if (!result.ok) {
      // **把提供方的失败原样传下去**，但标明是"提供方失败"——
      // 调用方需要能分清"我调错了"和"对面坏了"。
      return CapabilityResult.failure(
        'providerFailed',
        '提供方「${cap.providerName}」执行失败：'
        '${result.errorCode ?? ''} ${result.errorMessage ?? ''}'.trim(),
      );
    }

    return CapabilityResult.success(result.result);
  }

  @override
  List<Map<String, dynamic>> availableTo(String callerPluginId) {
    // **只列它有权调的。** 让插件看见自己用不了的能力，
    // 只会诱使它去猜权限名。
    return registry.all
        .where((c) => gatekeeper.check(callerPluginId, c.permission).isAllowed)
        .map((c) => <String, dynamic>{
              'provider': c.providerId,
              'providerName': c.providerName,
              'name': c.name,
              'qualified': c.qualified,
              'description': c.declaration.description,
              'schema': c.declaration.schema,
              'timeoutMs': c.declaration.timeoutMs,
            })
        .toList(growable: false);
  }
}
