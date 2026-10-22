/// 密钥脱敏。
///
/// 这个文件的理由很简单：我们的原则是「错误原文照显示」，
/// 而原文里可能带着鉴权头。**不美化错误 ≠ 泄漏密钥。**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiro_chat/services/mcp_client.dart';

void main() {
  group('Bearer token', () {
    test('头部值被替换', () {
      final out = redactSecrets('HTTP 401: Authorization: Bearer abcdefghijklmnop');
      expect(out, isNot(contains('abcdefghijklmnop')));
      expect(out, contains('***'));
    });

    test('只留 Bearer 前缀，值全掉', () {
      expect(redactSecrets('Bearer sk-1234567890abcdef'),
          isNot(contains('1234567890abcdef')));
    });

    test('太短的不误伤（不是 token 的样子）', () {
      // `Bearer x` 这种不像是真 token，不该被改写成 `Bearer ***`
      // —— 误伤会让错误信息失去诊断价值
      final out = redactSecrets('Bearer a');
      expect(out, contains('Bearer a'));
    });
  });

  group('sk- 形态的 key', () {
    test('被替换，但保留前几位便于辨认是哪个 key', () {
      final out = redactSecrets('key: sk-abcd1234567890');
      expect(out, contains('sk-abcd***'));
      expect(out, isNot(contains('1234567890')));
    });
  });

  group('JSON 里的字段', () {
    test('"authorization": "xxx"', () {
      final out = redactSecrets('{"authorization":"secret-value-here"}');
      expect(out, isNot(contains('secret-value-here')));
    });

    test('"token": "xxx"', () {
      final out = redactSecrets('{"token":"abcdefghijklmn"}');
      expect(out, isNot(contains('abcdefghijklmn')));
    });

    test('"api_key": "xxx"', () {
      final out = redactSecrets('{"api_key":"zzzzzzzzzzzzzzzz"}');
      expect(out, isNot(contains('zzzzzzzzzzzzzzzz')));
    });

    test('"password": "xxx"', () {
      final out = redactSecrets('{"password":"hunter2hunter2"}');
      expect(out, isNot(contains('hunter2hunter2')));
    });
  });

  group('不该被误伤的内容', () {
    test('普通错误信息原样保留', () {
      const msg = '连接不上 MCP server：Connection refused';
      expect(redactSecrets(msg), msg);
    });

    test('中文和路径不变', () {
      const msg = '打开 /data/user/0/app/files/a.txt 失败';
      expect(redactSecrets(msg), msg);
    });

    test('短词 token 不被当成密钥', () {
      // "token: 3" 这种是说明文字，不是密钥
      final out = redactSecrets('剩余 token: 3');
      expect(out, contains('3'));
    });
  });

  group('McpException 一律脱敏', () {
    test('构造时就擦掉', () {
      final e = McpException('Authorization: Bearer abcdefghijklmnop');
      expect(e.message, isNot(contains('abcdefghijklmnop')));
    });

    test('toString 也只有脱敏后的内容', () {
      final e = McpException('token=abcdefghijklmnop', code: 401);
      expect('$e', isNot(contains('abcdefghijklmnop')));
    });
  });
}
