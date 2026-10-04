import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:tsukiro_chat/ui/user_error.dart';

void main() {
  test('does not expose internal model error details', () {
    final error = TsukiroException(
      TsukiroErrorCode.networkError,
      'GET http://internal.example/token?key=secret',
    );

    final message = userFacingError(error);
    expect(message, '网络连接失败，请检查网络后重试。');
    expect(message, isNot(contains('internal.example')));
    expect(message, isNot(contains('secret')));
  });

  test('maps common local failures to stable copy', () {
    expect(userFacingError(StateError('数据库尚未就绪')), '应用还在启动，请稍后重试。');
    expect(userFacingError(StateError('已有一轮对话正在发送')), '已有一轮对话正在发送，请先等待或取消。');
    expect(userFacingError(StateError('anything else')), '操作失败，请稍后重试。');
  });
}
