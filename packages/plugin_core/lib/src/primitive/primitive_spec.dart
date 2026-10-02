/// 原语声明模型。
///
/// 核心设计：**原语是数据，不是代码分支。**
/// 加一个原语 = 构造一个 [PrimitiveSpec] 并 `registry.register(spec)`，
/// 不需要改宿主核心的任何一行。
///
/// 见 `docs/16-extensibility.md` §2。
library;

import '../common/cancellation.dart';
import 'service_registry.dart';

/// 原语的调用形态。
enum PrimitiveKind {
  /// 一问一答，返回单个结果。绝大多数原语。
  request,

  /// 返回 AsyncIterable 的分片流（如 `model.chat` 的 stream 模式）。
  stream,

  /// 立即返回 `{ jobId }`，进度走事件（如 `net.download`）。
  task,

  /// 注册一个事件监听（如 `sms.listen`）。
  event,
}

/// 一次原语调用的上下文。
///
/// 各原语实现从这里取它需要的东西；不需要的不必关心。
class PrimitiveCall {
  const PrimitiveCall({
    required this.pluginId,
    required this.name,
    required this.args,
    required this.timeout,
    required this.cancel,
    required this.services,
  });

  /// 发起调用的插件。原语实现可以据此做插件级隔离（如沙箱路径）。
  final String pluginId;

  final String name;
  final Map<String, dynamic> args;

  /// 本次调用的超时预算（已按 spec 的 maxTimeoutMs 夹取）。
  final Duration timeout;

  final CancellationToken cancel;

  /// 宿主注入的服务集合。按**类型**查找，见 [ServiceRegistry]。
  ///
  /// 内核不依赖任何具体的宿主实现 —— 各原语实现通过
  /// `call.require<HostClock>()` 这样的方式取用自己需要的服务。
  final ServiceRegistry services;

  /// 取服务；缺失时抛出可诊断的错误。
  T require<T>() => services.require<T>();

  /// 取服务；缺失时返回 null。
  T? service<T>() => services.get<T>();
}

/// 原语处理器。
typedef PrimitiveHandler = Future<Object?> Function(PrimitiveCall call);

/// 一条原语的完整声明。
class PrimitiveSpec {
  const PrimitiveSpec({
    required this.name,
    required this.description,
    this.permission,
    this.kind = PrimitiveKind.request,
    this.paramsSchema = const <String, dynamic>{},
    this.handler,
    this.defaultTimeoutMs = 10000,
    this.maxTimeoutMs = 60000,
    this.since = '0.1.0',
    this.platforms,
  });

  /// 注册但**未实现**的原语。
  ///
  /// Demo 阶段用它把全部 23 个域都注册上，只给 4 个真 handler。
  /// 这样插件运行期就能自省"宿主支持什么"，而不是靠版本号猜。
  const PrimitiveSpec.placeholder({
    required this.name,
    required this.description,
    this.permission,
    this.kind = PrimitiveKind.request,
    this.paramsSchema = const <String, dynamic>{},
    this.since = '0.1.0',
    this.platforms,
  })  : handler = null,
        defaultTimeoutMs = 10000,
        maxTimeoutMs = 60000;

  /// 形如 `sys.time`。必须至少两段。
  final String name;

  /// 面向插件作者与自省接口的说明。
  final String description;

  /// 所需权限名；`null` 表示无需权限。
  final String? permission;

  final PrimitiveKind kind;

  /// JSON Schema 子集，见 `schema_validator.dart`。
  final Map<String, dynamic> paramsSchema;

  /// `null` = 未实现。**由 handler 是否为空推导 `implemented`**，
  /// 这样不可能出现「implemented 为 true 但没有 handler」的自相矛盾状态。
  final PrimitiveHandler? handler;

  final int defaultTimeoutMs;
  final int maxTimeoutMs;
  final String since;

  /// 该原语支持哪些平台；null = 全部。
  final List<String>? platforms;

  /// 是否已实现。
  bool get implemented => handler != null;

  /// 是否需要权限。
  bool get needsPermission => permission != null;

  /// 一级域名，如 `sys`。
  String get domain {
    final dot = name.indexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  /// 把超时申请夹到 [maxTimeoutMs] 之内。
  Duration resolveTimeout(int? requestedMs) {
    final ms = requestedMs ?? defaultTimeoutMs;
    return Duration(milliseconds: ms.clamp(1, maxTimeoutMs));
  }

  /// 自省输出（供 `primitive.list` / 文档生成）。
  Map<String, dynamic> describe() => <String, dynamic>{
        'name': name,
        'domain': domain,
        'description': description,
        'permission': permission,
        'kind': kind.name,
        'implemented': implemented,
        'since': since,
        if (platforms != null) 'platforms': platforms,
        if (paramsSchema.isNotEmpty) 'paramsSchema': paramsSchema,
      };

  /// 校验原语名是否合法（至少两段，小写）。
  static bool isValidName(String name) =>
      RegExp(r'^[a-z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*)+$').hasMatch(name);

  @override
  String toString() =>
      'PrimitiveSpec($name${implemented ? '' : ', 未实现'})';
}
