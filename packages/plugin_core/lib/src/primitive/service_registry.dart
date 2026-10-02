/// 宿主服务注册表 —— 按**类型**查找，而不是按固定字段。
///
/// 与 `PrimitiveRegistry` 同一个思路：加一个新的宿主能力（如"记忆存储"）
/// = `services.put<MemoryStore>(impl)`，不需要改内核里的任何容器类。
///
/// 反面模式（不要这样）：
/// ```dart
/// // ❌ 每加一个能力都要改这个类，内核跟着宿主膨胀
/// class HostServices {
///   final Clock? clock;
///   final Ui? ui;
///   final Files? files;
///   final MemoryStore? memory;   // ← 又加一行
/// }
/// ```
library;

/// 按类型存放宿主服务。
class ServiceRegistry {
  ServiceRegistry([Map<Type, Object>? initial])
      : _byType = <Type, Object>{...?initial};

  final Map<Type, Object> _byType;

  /// 注册（或覆盖）一个服务。
  ///
  /// 同一类型重复注册会覆盖并返回被覆盖的实例 —— 覆盖是刻意的能力：
  /// 测试时用假实现替换真实现就靠它。
  Object? put<T>(T service) {
    final previous = _byType[T];
    _byType[T] = service as Object;
    return previous;
  }

  /// 取服务；不存在或类型不符时返回 null。
  T? get<T>() {
    final s = _byType[T];
    return s is T ? s : null;
  }

  /// 取服务；不存在时抛 [StateError]（宿主装配错误，应当响）。
  T require<T>() {
    final s = get<T>();
    if (s == null) {
      throw StateError(
        '宿主未注入服务 ${T.toString()}。'
        '已注入的类型：${_byType.keys.map((t) => t.toString()).join(", ")}',
      );
    }
    return s;
  }

  bool has<T>() => _byType[T] is T;

  Iterable<Type> get registeredTypes => _byType.keys;

  /// 派生一个子集，用于给某类原语做更窄的注入面。
  ServiceRegistry subset(Iterable<Type> types) {
    final sub = <Type, Object>{};
    for (final t in types) {
      final s = _byType[t];
      if (s != null) sub[t] = s;
    }
    return ServiceRegistry(sub);
  }
}
