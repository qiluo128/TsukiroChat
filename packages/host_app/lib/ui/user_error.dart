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
  // 明文被系统拦掉：以前会被归成笼统的"网络连接失败"，
  // 而用户改什么都没用 —— 这是配置问题，不是网络问题
  if (text.contains('cleartext')) {
    return '系统拦截了明文 HTTP，请改用 HTTPS。';
  }
  if (text.contains('failed host lookup') || text.contains('no address associated')) {
    return '域名解析失败，请检查 Base URL 是否正确。';
  }
  if (text.contains('connection refused')) {
    return '服务器拒绝连接，请检查端口与路径。';
  }
  if (text.contains('certificate') || text.contains('handshake')) {
    return 'HTTPS 证书校验失败。';
  }
  if (text.contains('超时') || text.contains('timeout')) return '请求超时，请稍后重试。';
  // 放在 host lookup 之后：那两种更具体，先匹配
  if (text.contains('连接') || text.contains('network') || text.contains('tls')) {
    return '网络连接失败，请检查网络后重试。';
  }
  if (text.contains('模型') && (text.contains('不存在') || text.contains('404'))) {
    return '请求的模型或资源不存在。';
  }
  // 没见过的错误**不要伪造一个"网络问题"** ——
  // 上面那个"检查网络后重试"会把人引到完全错误的方向。
  // 原样带出来，配合界面上的原始报文，才排得了障。
  final raw = error?.trim() ?? '';
  if (raw.isEmpty) return '连接失败，请检查配置后重试。';
  return raw.length > 80 ? '${raw.substring(0, 80)}…' : raw;
}
