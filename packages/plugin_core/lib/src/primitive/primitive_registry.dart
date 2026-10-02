/// 原语注册表 —— **全部原语调用的唯一入口**。
///
/// 把「权限校验 → 参数校验 → 执行 → 审计」这条流水线写一次，
/// 就不可能被某条调用路径绕过。见 `docs/16-extensibility.md` §2.2。
///
/// ```dart
/// final registry = PrimitiveRegistry(gatekeeper: gk);
/// registry.registerAll(primitiveCatalog);   // 全量注册，含未实现的
/// final t = await registry.invoke('dev.tsukiro.time', 'sys.time', {'tz': 'Asia/Shanghai'});
/// ```
library;

import 'dart:async';

import '../audit/audit.dart';
import '../common/cancellation.dart';
import '../common/errors.dart';
import '../permission/gatekeeper.dart';
import 'primitive_spec.dart';
import 'schema_validator.dart';
import 'service_registry.dart';

/// 一次调用的结果（含耗时，便于宿主做限流与背压判断）。
class PrimitiveInvocation {
  const PrimitiveInvocation({
    required this.name,
    required this.result,
    required this.durationMs,
  });

  final String name;
  final Object? result;
  final int durationMs;

  @override
  String toString() => 'PrimitiveInvocation($name, ${durationMs}ms)';
}

/// 原语注册表。
class PrimitiveRegistry {
  PrimitiveRegistry({
    required this.gatekeeper,
    AuditSink? audit,
    AuditRedactor? redactor,
    ServiceRegistry? services,
  })  : audit = audit ?? const NullAuditSink(),
        redactor = redactor ?? const AuditRedactor(),
        services = services ?? ServiceRegistry();

  final Gatekeeper gatekeeper;
  final AuditSink audit;
  final AuditRedactor redactor;

  /// 宿主注入给原语实现的服务集合。
  final ServiceRegistry services;

  final Map<String, PrimitiveSpec> _specs = <String, PrimitiveSpec>{};

  /// 已注册的原语总数（含未实现的）。
  int get length => _specs.length;

  int get implementedCount => _specs.values.where((s) => s.implemented).length;

  Iterable<PrimitiveSpec> get all => _specs.values;

  /// 按名查找。
  PrimitiveSpec? lookup(String name) => _specs[name];

  /// 该原语是否存在（不区分是否实现）。
  bool contains(String name) => _specs.containsKey(name);

  /// 该原语是否可用（存在且有实现）。
  bool isImplemented(String name) => _specs[name]?.implemented ?? false;

  /// 某个域下的全部原语。
  Iterable<PrimitiveSpec> byDomain(String domain) =>
      _specs.values.where((s) => s.domain == domain);

  /// 域名列表。
  Set<String> get domains =>
      _specs.values.map((s) => s.domain).toSet();

  /// 注册一条原语。
  ///
  /// 重复注册**直接抛异常**：这是编程错误（两处代码注册了同一个名字），
  /// 应该在启动时就炸掉，而不是留到运行期让调用行为取决于注册顺序。
  void register(PrimitiveSpec spec) {
    if (!PrimitiveSpec.isValidName(spec.name)) {
      throw ArgumentError.value(
        spec.name,
        'spec.name',
        '原语名非法。要求小写、至少两段（domain.action），如 sys.time',
      );
    }
    if (_specs.containsKey(spec.name)) {
      throw StateError(
        '原语 "${spec.name}" 已注册（已有：${_specs[spec.name]}）。'
        '若要显式覆盖，请用 registerOrReplace。',
      );
    }
    _specs[spec.name] = spec;
  }

  void registerAll(Iterable<PrimitiveSpec> specs) {
    for (final s in specs) {
      register(s);
    }
  }

  /// 显式覆盖注册。仅用于宿主内部替换实现（如从占位换成真实实现）。
  void registerOrReplace(PrimitiveSpec spec) {
    _specs[spec.name] = spec;
  }

  /// 批量替换实现。用于「Demo 之后把占位换成真实现」。
  void replaceImplementations(Map<String, PrimitiveHandler> handlers) {
    handlers.forEach((name, handler) {
      final existing = _specs[name];
      if (existing == null) {
        throw StateError('无法替换未注册的原语 "$name"');
      }
      _specs[name] = PrimitiveSpec(
        name: existing.name,
        description: existing.description,
        permission: existing.permission,
        kind: existing.kind,
        paramsSchema: existing.paramsSchema,
        handler: handler,
        defaultTimeoutMs: existing.defaultTimeoutMs,
        maxTimeoutMs: existing.maxTimeoutMs,
        since: existing.since,
        platforms: existing.platforms,
      );
    });
  }

  /// **权威调用入口。**
  ///
  /// 流水线顺序（顺序本身是安全策略，不要调整）：
  ///   ① 查表 → ② 是否已实现 → ③ **权限** → ④ 参数 → ⑤ 执行 → ⑥ 审计
  ///
  /// ③ 在 ④ 之前是刻意的：未授权的插件不应该通过参数报错信息探测宿主的能力细节。
  ///
  /// 失败时抛 [TsukiroException]，不返回 null —— 让调用方能区分
  /// 「结果是 null」和「调用失败」。
  Future<Object?> invoke(
    String pluginId,
    String name, [
    Map<String, dynamic>? args,
    CancellationToken? cancel,
  ]) async {
    final safeArgs = args ?? const <String, dynamic>{};
    final token = cancel ?? NeverCancelled();

    // ① 查表
    final spec = _specs[name];
    if (spec == null) {
      _record(
        pluginId: pluginId,
        spec: null,
        name: name,
        permission: null,
        args: safeArgs,
        result: 'error',
        errorCode: TsukiroErrorCode.unsupported,
        durationMs: 0,
      );
      throw TsukiroException(
        TsukiroErrorCode.unsupported,
        '未知原语 "$name"。宿主支持的原语可用 primitive.list 查询',
        details: <String, dynamic>{'primitive': name},
      );
    }

    // ② 是否已实现
    if (!spec.implemented) {
      _record(
        pluginId: pluginId,
        spec: spec,
        name: name,
        permission: spec.permission,
        args: safeArgs,
        result: 'error',
        errorCode: TsukiroErrorCode.unsupported,
        durationMs: 0,
      );
      throw TsukiroException(
        TsukiroErrorCode.unsupported,
        '原语 "$name" 在当前宿主版本尚未实现（计划于 ${spec.since}）',
        details: <String, dynamic>{
          'primitive': name,
          'since': spec.since,
          'implemented': false,
        },
      );
    }

    // ③ 权限（宿主侧，唯一权威判定）
    final gate = gatekeeper.check(pluginId, spec.permission);
    if (!gate.isAllowed) {
      _record(
        pluginId: pluginId,
        spec: spec,
        name: name,
        permission: spec.permission,
        args: safeArgs,
        result: 'denied',
        errorCode: gate.decision == GateDecision.confirmRequired
            ? TsukiroErrorCode.confirmRequired
            : TsukiroErrorCode.permissionDenied,
        durationMs: 0,
      );
      throw gate.toException();
    }

    // ④ 参数
    if (spec.paramsSchema.isNotEmpty) {
      final issues = validateAgainstSchema(safeArgs, spec.paramsSchema);
      if (issues.isNotEmpty) {
        _record(
          pluginId: pluginId,
          spec: spec,
          name: name,
          permission: spec.permission,
          args: safeArgs,
          result: 'error',
          errorCode: TsukiroErrorCode.invalidArgs,
          durationMs: 0,
        );
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          '原语 $name 的参数不合法：${issues.map((e) => e.toString()).join("；")}',
          details: <String, dynamic>{
            'primitive': name,
            'issues': issues.map((e) => e.toString()).toList(),
          },
        );
      }
    }

    // ⑤ 执行
    final sw = Stopwatch()..start();
    final call = PrimitiveCall(
      pluginId: pluginId,
      name: name,
      args: safeArgs,
      timeout: spec.resolveTimeout(safeArgs['timeoutMs'] as int?),
      cancel: token,
      services: services,
    );

    Object? result;
    try {
      result = await spec.handler!(call).timeout(call.timeout);
      sw.stop();
      _record(
        pluginId: pluginId,
        spec: spec,
        name: name,
        permission: spec.permission,
        args: safeArgs,
        result: 'ok',
        durationMs: sw.elapsedMilliseconds,
      );
      return result;
    } on TimeoutException {
      sw.stop();
      _record(
        pluginId: pluginId,
        spec: spec,
        name: name,
        permission: spec.permission,
        args: safeArgs,
        result: 'error',
        errorCode: TsukiroErrorCode.timeout,
        durationMs: sw.elapsedMilliseconds,
      );
      throw TsukiroException(
        TsukiroErrorCode.timeout,
        '原语 $name 超时（${call.timeout.inMilliseconds}ms）',
        details: <String, dynamic>{'primitive': name},
      );
    } on TsukiroException catch (e) {
      // 原语实现自己抛的（如 SANDBOX_VIOLATION）原样透传
      sw.stop();
      _record(
        pluginId: pluginId,
        spec: spec,
        name: name,
        permission: spec.permission,
        args: safeArgs,
        result: 'error',
        errorCode: e.code,
        durationMs: sw.elapsedMilliseconds,
      );
      rethrow;
    } catch (e) {
      sw.stop();
      _record(
        pluginId: pluginId,
        spec: spec,
        name: name,
        permission: spec.permission,
        args: safeArgs,
        result: 'error',
        errorCode: TsukiroErrorCode.internal,
        durationMs: sw.elapsedMilliseconds,
      );
      throw TsukiroException(
        TsukiroErrorCode.internal,
        '原语 $name 执行失败：$e',
        details: <String, dynamic>{'primitive': name},
      );
    }
  }

  /// 自省输出：插件在运行期问「宿主支持什么」。
  ///
  /// 这也是文档生成的数据源 —— `docs/05-primitives.md` 的表格应与它一致。
  Map<String, dynamic> describe() => <String, dynamic>{
        'total': _specs.length,
        'implemented': implementedCount,
        'domains': domains.toList()..sort(),
        'primitives': _specs.values.map((s) => s.describe()).toList(growable: false),
      };

  void _record({
    required String pluginId,
    required PrimitiveSpec? spec,
    required String name,
    required String? permission,
    required Map<String, dynamic> args,
    required String result,
    required int durationMs,
    TsukiroErrorCode? errorCode,
  }) {
    audit.write(AuditEntry(
      pluginId: pluginId,
      kind: 'primitive',
      primitive: name,
      permission: permission,
      argsDigest: redactor.digest(name, args),
      result: result,
      errorCode: errorCode == null ? null : errorCodeToString(errorCode),
      durationMs: durationMs,
    ));
  }
}
