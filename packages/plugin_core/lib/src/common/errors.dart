/// Tsukiro Chat 统一错误模型。
///
/// 每个错误码都在 [05-primitives](../../../docs/05-primitives.md) 里有明确定义，
/// 插件作者依赖它来写降级逻辑，因此**新增错误码必须同步更新文档**。
library;

/// 与文档 `docs/05-primitives.md` §1.4 的错误码表一一对应。
enum TsukiroErrorCode {
  /// 参数不符合 schema。插件应改代码，不要重试。
  invalidArgs,

  /// 未授权（未申请或从未授予）。
  permissionDenied,

  /// 曾授权后被用户撤销。
  permissionRevoked,

  /// 用户在选择器/授权框中取消。不算错误。
  userCancelled,

  /// 文件/联系人/会话不存在。
  notFound,

  /// 磁盘或系统 IO 失败。
  ioError,

  /// 网络失败。
  networkError,

  /// 超时。
  timeout,

  /// 触发限流。
  rateLimited,

  /// 试图越出沙箱（路径穿越等）。**不可重试**，已记安全审计。
  sandboxViolation,

  /// 当前平台不支持该原语。
  unsupported,

  /// 该操作属「每次确认」级别，用户尚未确认。
  confirmRequired,

  /// 插件自身 handler 抛错。
  pluginError,

  /// 宿主内部错误。
  internal,

  /// manifest 非法或插件包不合法（安装期使用）。
  invalidManifest,

  /// 插件包内容违规（Zip Slip、二进制等，安装期使用）。
  invalidPackage,
}

/// Bridge 协议中传输的 `error.code` 字符串。
String errorCodeToString(TsukiroErrorCode code) {
  switch (code) {
    case TsukiroErrorCode.invalidArgs:
      return 'INVALID_ARGS';
    case TsukiroErrorCode.permissionDenied:
      return 'PERMISSION_DENIED';
    case TsukiroErrorCode.permissionRevoked:
      return 'PERMISSION_REVOKED';
    case TsukiroErrorCode.userCancelled:
      return 'USER_CANCELLED';
    case TsukiroErrorCode.notFound:
      return 'NOT_FOUND';
    case TsukiroErrorCode.ioError:
      return 'IO_ERROR';
    case TsukiroErrorCode.networkError:
      return 'NETWORK_ERROR';
    case TsukiroErrorCode.timeout:
      return 'TIMEOUT';
    case TsukiroErrorCode.rateLimited:
      return 'RATE_LIMITED';
    case TsukiroErrorCode.sandboxViolation:
      return 'SANDBOX_VIOLATION';
    case TsukiroErrorCode.unsupported:
      return 'UNSUPPORTED';
    case TsukiroErrorCode.confirmRequired:
      return 'CONFIRM_REQUIRED';
    case TsukiroErrorCode.pluginError:
      return 'PLUGIN_ERROR';
    case TsukiroErrorCode.internal:
      return 'INTERNAL';
    case TsukiroErrorCode.invalidManifest:
      return 'INVALID_MANIFEST';
    case TsukiroErrorCode.invalidPackage:
      return 'INVALID_PACKAGE';
  }
}

/// 解析失败时返回 null（用于兼容未来新增的错误码）。
TsukiroErrorCode? errorCodeFromString(String value) {
  for (final code in TsukiroErrorCode.values) {
    if (errorCodeToString(code) == value) return code;
  }
  return null;
}

/// 插件内核的统一异常。
///
/// 宿主内部与插件侧都用它，保证错误语义一致。
class TsukiroException implements Exception {
  TsukiroException(
    this.code,
    this.message, {
    Map<String, dynamic>? details,
    bool? retryable,
  })  : details = details ?? const <String, dynamic>{},
        retryable = retryable ?? _defaultRetryable(code);

  /// 便捷构造：权限被拒。
  factory TsukiroException.permissionDenied(String permission, {String? reason}) {
    return TsukiroException(
      TsukiroErrorCode.permissionDenied,
      reason ?? '插件未获得 $permission 权限',
      details: <String, dynamic>{'permission': permission},
    );
  }

  /// 便捷构造：权限被撤销。
  factory TsukiroException.permissionRevoked(String permission) {
    return TsukiroException(
      TsukiroErrorCode.permissionRevoked,
      '插件对 $permission 的授权已被用户撤销',
      details: <String, dynamic>{'permission': permission},
    );
  }

  /// 便捷构造：沙箱越界。永远是安全事件，不可重试。
  factory TsukiroException.sandboxViolation(String path, {String? reason}) {
    return TsukiroException(
      TsukiroErrorCode.sandboxViolation,
      reason ?? '路径越出插件沙箱: $path',
      details: <String, dynamic>{'path': path},
    );
  }

  final TsukiroErrorCode code;
  final String message;
  final Map<String, dynamic> details;
  final bool retryable;

  static bool _defaultRetryable(TsukiroErrorCode code) {
    switch (code) {
      case TsukiroErrorCode.ioError:
      case TsukiroErrorCode.networkError:
      case TsukiroErrorCode.timeout:
      case TsukiroErrorCode.rateLimited:
        return true;
      default:
        return false;
    }
  }

  /// 序列化为 Bridge 协议的 `error` 字段。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': errorCodeToString(code),
        'message': message,
        'details': details,
        'retryable': retryable,
      };

  @override
  String toString() => 'TsukiroException(${errorCodeToString(code)}): $message';
}
