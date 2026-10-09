/// 插件提供的能力（「能力市场」）。
///
/// ## 这一步要解决什么
///
/// 在此之前，只有**宿主**能注册原语。于是每个垂直场景都要宿主写一套：
/// 想接向量库？宿主写。想接日历同步？宿主写。
/// 宿主成了瓶颈，而且它永远追不上生态的想象力。
///
/// 有了能力市场：**插件 A 可以提供一个能力，插件 B 来调用。**
/// 一个做向量库的插件，能被做记忆的插件用，再被做角色扮演的插件用 ——
/// 而宿主一行原语都不用加。
///
/// ```text
/// 调用方 dev.acme.memory
///        ↓ capability.invoke
///   CapabilityRegistry      ← 权限、超时、审计都在这
///        ↓ 路由到提供方
/// 提供方 dev.acme.vector 的 handler
/// ```
///
/// ## 权限怎么判：一分为二
///
/// 门禁是**按原语名静态判定**的，而「能不能调这个能力」取决于
/// **调用参数**（调哪个提供方）。所以拆成两层：
///
/// | 层 | 判什么 | 在哪判 |
/// |---|---|---|
/// | `capability.invoke` | 这个插件**允不允许调能力** | 门禁（静态，按原语名） |
/// | `capability:<提供方>:<名字>` | 这个插件**允不允许调这一个** | 宿主实现（动态，按参数） |
///
/// **不把动态判断塞进门禁**：门禁的价值就在于它只看静态声明的名字，
/// 一眼能看出"这个插件能做什么"。让它去解析参数会把这件事变糊。
///
/// 而且这样也更安全：`capability.invoke` 是个**窄口**，
/// 具体谁能用哪个能力由宿主按 (调用方, 提供方, 名字) 三元组判。
library;

import '../common/errors.dart';

/// 提供方在清单里声明的一个能力。
class CapabilityDeclaration {
  const CapabilityDeclaration({
    required this.name,
    required this.description,
    required this.handler,
    this.schema = const <String, dynamic>{},
    this.timeoutMs = 5000,
  });

  /// 能力名，形如 `vector.search`。**在提供方内唯一。**
  final String name;

  /// 给调用方和用户看的说明。
  final String description;

  /// 提供方包内的 handler 文件路径。
  final String handler;

  /// 参数的 JSON Schema（给调用方看，不强制校验 —— 校验是 handler 的事）。
  final Map<String, dynamic> schema;

  /// 建议超时。宿主会夹取。
  final int timeoutMs;

  static CapabilityDeclaration? parse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString().trim() ?? '';
    final handler = raw['handler']?.toString().trim() ?? '';
    if (name.isEmpty || handler.isEmpty) return null;
    if (name.length > 128) return null;
    final schema = raw['schema'];
    return CapabilityDeclaration(
      name: name,
      description: raw['description']?.toString() ?? '',
      handler: handler,
      schema: schema is Map ? schema.map((k, v) => MapEntry('$k', v)) : const <String, dynamic>{},
      timeoutMs: (raw['timeoutMs'] as num?)?.toInt() ?? 5000,
    );
  }

  /// 宿主侧的全名，也是权限名的一部分。
  static String qualified(String providerId, String name) => '$providerId:$name';
}

/// 注册表里的一条能力。
class RegisteredCapability {
  const RegisteredCapability({
    required this.declaration,
    required this.providerId,
    required this.providerVersion,
    required this.providerName,
  });

  final CapabilityDeclaration declaration;
  final String providerId;
  final String providerVersion;

  /// 提供方的显示名 —— 用户授权时要看到「谁提供的能力」。
  final String providerName;

  String get name => declaration.name;

  /// 全名：`<providerId>:<name>`。
  String get qualified => CapabilityDeclaration.qualified(providerId, name);

  /// 用户看到的权限名。
  ///
  /// 用 `:` 分隔而不是 `.` —— 能力名自己就带点（`vector.search`），
  /// 用点会让"哪部分是提供方"变得要靠猜。
  String get permission => 'capability:$qualified';

  @override
  String toString() => 'RegisteredCapability($qualified)';
}

/// 能力注册表。
///
/// **不做全局唯一名**：两个插件都提供 `text.summarize`（一个本地、一个云端）
/// 是合理的，硬要唯一反而逼提供方起怪名字。
/// 所以按 (提供方, 名字) 寻址，由调用方指明要哪个。
class CapabilityRegistry {
  final Map<String, List<RegisteredCapability>> _byProvider =
      <String, List<RegisteredCapability>>{};

  /// 注册一个插件提供的全部能力。重复注册同一插件会先清掉旧的（升级场景）。
  void registerProvider(
    String providerId, {
    required String providerVersion,
    required String providerName,
    required List<CapabilityDeclaration> declarations,
  }) {
    unregisterProvider(providerId);
    if (declarations.isEmpty) return;
    _byProvider[providerId] = declarations
        .map((d) => RegisteredCapability(
              declaration: d,
              providerId: providerId,
              providerVersion: providerVersion,
              providerName: providerName,
            ))
        .toList(growable: false);
  }

  int unregisterProvider(String providerId) =>
      _byProvider.remove(providerId)?.length ?? 0;

  /// 按 (提供方, 名字) 找。
  RegisteredCapability? find(String providerId, String name) {
    for (final c in _byProvider[providerId] ?? const <RegisteredCapability>[]) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// 全部能力，按全名排序。
  List<RegisteredCapability> get all {
    final list = _byProvider.values.expand((l) => l).toList(growable: false)
      ..sort((a, b) => a.qualified.compareTo(b.qualified));
    return list;
  }

  /// 某个提供方提供了什么。
  List<RegisteredCapability> providedBy(String providerId) =>
      List<RegisteredCapability>.unmodifiable(
          _byProvider[providerId] ?? const <RegisteredCapability>[]);

  /// 有几个提供方。
  int get providerCount => _byProvider.length;

  void clear() => _byProvider.clear();

  /// **按名字模糊找**：给「我不管谁提供，能搜就行」的调用方用。
  ///
  /// 返回所有提供这个名字的提供方。多于一个时**由调用方决定**，
  /// 宿主不替它挑 —— 挑错了（云端还是本地）是调用方的事。
  List<RegisteredCapability> findByName(String name) => all
      .where((c) => c.name == name)
      .toList(growable: false);

  @override
  String toString() =>
      'CapabilityRegistry(${_byProvider.length} 个提供方, ${all.length} 个能力)';
}

/// 一次能力调用的请求。
class CapabilityRequest {
  const CapabilityRequest({
    required this.providerId,
    required this.name,
    this.args = const <String, dynamic>{},
  });

  final String providerId;
  final String name;
  final Map<String, dynamic> args;

  String get qualified => CapabilityDeclaration.qualified(providerId, name);

  /// 从原语参数解析。
  ///
  /// 支持两种写法：
  ///   - 明确指定：`{provider: 'a.b', name: 'vector.search'}`
  ///   - 只给能力名：`{name: 'vector.search'}` —— 由宿主在所有提供方里找，
  ///     **多于一个时报错并列出来**，不替调用方猜
  static CapabilityRequest parse(Map<String, dynamic> raw) {
    final name = raw['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'capability.invoke 需要 name（能力名，如 vector.search）',
      );
    }
    final args = raw['args'];
    return CapabilityRequest(
      providerId: raw['provider']?.toString().trim() ?? '',
      name: name,
      args: args is Map ? args.map((k, v) => MapEntry('$k', v)) : const <String, dynamic>{},
    );
  }
}

/// 能力调用的结果。
///
/// **把「失败」做成数据而不是异常**：一次能力调用失败是可预期的
/// （提供方没在跑、超时、权限不够），调用方需要能分辨是哪种，
/// 而不是拿到一个光秃秃的异常。
class CapabilityResult {
  const CapabilityResult({
    required this.ok,
    this.value,
    this.errorCode,
    this.errorMessage,
  });

  final bool ok;
  final Object? value;
  final String? errorCode;
  final String? errorMessage;

  factory CapabilityResult.success(Object? value) =>
      CapabilityResult(ok: true, value: value);

  factory CapabilityResult.failure(String code, String message) =>
      CapabilityResult(ok: false, errorCode: code, errorMessage: message);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        if (ok) 'value': value,
        if (!ok) 'error': <String, dynamic>{'code': errorCode, 'message': errorMessage},
      };

  @override
  String toString() => ok ? 'CapabilityResult(ok)' : 'CapabilityResult($errorCode)';
}

/// 调用深度上限。
///
/// **防止 A→B→A→B 互相递归。** 没有它，两个互相调用的插件
/// 会一直转到爆栈 —— 而且是跨进程/跨 WebView 的递归，很难看出来。
const int maxCapabilityDepth = 4;
