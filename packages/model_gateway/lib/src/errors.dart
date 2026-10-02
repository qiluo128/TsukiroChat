/// 模型接入层的错误类型。
///
/// 继承 [TsukiroException]，让错误模型从网关一路到插件保持一致 ——
/// `model.chat` 原语失败时，插件收到的就是这一族错误码。
library;

import 'package:plugin_core/plugin_core.dart';

/// 出错的环节。
enum ModelErrorKind {
  /// 请求本身不合法（缺模型名、messages 为空）。
  invalidRequest,

  /// 鉴权失败（401/403）。key 错了或没权限。
  auth,

  /// 模型不存在（404）。
  modelNotFound,

  /// 限流或余额不足（429）。
  rateLimited,

  /// 上游 5xx。
  upstream,

  /// 网络层失败（连不上、DNS、TLS）。
  network,

  /// 超时。
  timeout,

  /// 响应体结构不符合协议（解析不了）。
  badResponse,
}

/// 模型接入层异常。
///
/// 刻意不做成 `const`：错误码由 [kind] 推导，而函数调用不能出现在常量表达式里。
class ModelGatewayException extends TsukiroException {
  ModelGatewayException(
    String message, {
    required this.kind,
    this.statusCode,
    this.requestId,
  }) : super(
          _codeFor(kind),
          message,
          details: <String, dynamic>{
            'kind': kind.name,
            if (statusCode != null) 'statusCode': statusCode,
            if (requestId != null) 'requestId': requestId,
          },
          retryable: _retryableFor(kind),
        );

  /// 从 HTTP 状态码推断错误性质。
  factory ModelGatewayException.fromHttp(
    String message, {
    required int statusCode,
    String? requestId,
  }) =>
      ModelGatewayException(
        message,
        kind: kindForStatus(statusCode),
        statusCode: statusCode,
        requestId: requestId,
      );

  final ModelErrorKind kind;
  final int? statusCode;
  final String? requestId;

  static TsukiroErrorCode _codeFor(ModelErrorKind kind) {
    switch (kind) {
      case ModelErrorKind.invalidRequest:
        return TsukiroErrorCode.invalidArgs;
      case ModelErrorKind.auth:
        return TsukiroErrorCode.permissionDenied;
      case ModelErrorKind.modelNotFound:
        return TsukiroErrorCode.notFound;
      case ModelErrorKind.rateLimited:
        return TsukiroErrorCode.rateLimited;
      case ModelErrorKind.upstream:
        return TsukiroErrorCode.internal;
      case ModelErrorKind.network:
        return TsukiroErrorCode.networkError;
      case ModelErrorKind.timeout:
        return TsukiroErrorCode.timeout;
      case ModelErrorKind.badResponse:
        return TsukiroErrorCode.internal;
    }
  }

  static bool _retryableFor(ModelErrorKind kind) {
    switch (kind) {
      case ModelErrorKind.rateLimited:
      case ModelErrorKind.upstream:
      case ModelErrorKind.network:
      case ModelErrorKind.timeout:
        return true;
      default:
        return false;
    }
  }

  /// HTTP 状态码 → 错误性质。
  static ModelErrorKind kindForStatus(int status) {
    if (status == 401 || status == 403) return ModelErrorKind.auth;
    if (status == 404) return ModelErrorKind.modelNotFound;
    if (status == 429) return ModelErrorKind.rateLimited;
    if (status >= 500) return ModelErrorKind.upstream;
    if (status == 400 || status == 422) return ModelErrorKind.invalidRequest;
    return ModelErrorKind.badResponse;
  }

  @override
  String toString() =>
      'ModelGatewayException(${kind.name}${statusCode == null ? '' : ' $statusCode'}): $message';
}
