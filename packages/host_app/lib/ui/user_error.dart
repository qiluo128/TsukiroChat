/// 将内部异常转换为可以直接展示给用户的稳定文案。
///
/// 上游响应可能包含 URL、代理诊断或其他敏感内容，不能直接进入 UI。
library;

import 'package:plugin_core/plugin_core.dart';

String userFacingError(Object error) {
  if (error is TsukiroException) {
    switch (error.code) {
      case TsukiroErrorCode.permissionDenied:
      case TsukiroErrorCode.permissionRevoked:
        return '模型鉴权失败，请检查 API Key 或权限。';
      case TsukiroErrorCode.networkError:
        return '网络连接失败，请检查网络后重试。';
      case TsukiroErrorCode.timeout:
        return '请求超时，请稍后重试。';
      case TsukiroErrorCode.rateLimited:
        return '请求过于频繁，请稍后重试。';
      case TsukiroErrorCode.invalidArgs:
        return '请求参数无效，请检查模型配置。';
      case TsukiroErrorCode.notFound:
        return '请求的模型或资源不存在。';
      default:
        return '操作失败，请稍后重试。';
    }
  }

  final text = error.toString();
  if (text.contains('还没有配置模型')) return '还没有配置模型，去设置里填写。';
  if (text.contains('数据库尚未就绪')) return '应用还在启动，请稍后重试。';
  if (text.contains('已有一轮对话正在发送')) return '已有一轮对话正在发送，请先等待或取消。';
  return '操作失败，请稍后重试。';
}

String userFacingConnectionError(String? error) {
  final text = error?.toLowerCase() ?? '';
  if (text.contains('鉴权') || text.contains('401') || text.contains('403')) {
    return '模型鉴权失败，请检查 API Key 或权限。';
  }
  if (text.contains('超时') || text.contains('timeout')) return '请求超时，请稍后重试。';
  if (text.contains('连接') || text.contains('network') || text.contains('tls')) {
    return '网络连接失败，请检查网络后重试。';
  }
  if (text.contains('模型') && (text.contains('不存在') || text.contains('404'))) {
    return '请求的模型或资源不存在。';
  }
  return '连接失败，请检查配置后重试。';
}
