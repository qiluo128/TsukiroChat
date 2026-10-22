/// `provides.mcp` 的解析与交叉校验。
///
/// 这里最有价值的两条是**交叉校验**：
///
///   1. `tokenConfigKey` 指向一个没声明过的 config key → 安装时就报错
///   2. url 不是 http/https → 安装时就报错
///
/// 如果不做，作者写错了会变成「用户填完 token 连不上」，
/// 然后所有人都去怀疑 token。
library;

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> base() => <String, dynamic>{
      'manifestVersion': 1,
      'id': 'dev.test.mcp',
      'name': 'MCP 测试',
      'version': '1.0.0',
      'runtime': <String, dynamic>{'main': 'index.js'},
      'provides': <String, dynamic>{
        'config': <dynamic>[
          <String, dynamic>{
            'key': 'token',
            'type': 'text',
            'label': 'MCP Token',
          },
        ],
        'mcp': <String, dynamic>{
          'url': 'https://mcp.example.com',
          'tokenConfigKey': 'token',
        },
      },
    };

void main() {
  group('正常解析', () {
    test('url / tokenConfigKey 解析出来', () {
      final r = parseManifest(base());
      expect(r.isValid, isTrue, reason: r.issues.map((e) => e.message).join('; '));
      final mcp = r.manifest!.provides.mcp;
      expect(mcp, isNotNull);
      expect(mcp!.url, 'https://mcp.example.com');
      expect(mcp.tokenConfigKey, 'token');
    });

    test('默认头是 Authorization + Bearer 前缀', () {
      final mcp = parseManifest(base()).manifest!.provides.mcp!;
      expect(mcp.authHeader, 'Authorization');
      expect(mcp.authPrefix, 'Bearer ');
    });

    test('可以覆盖头名和前缀', () {
      final json = base();
      (json['provides'] as Map<String, dynamic>)['mcp'] = <String, dynamic>{
        'url': 'https://x.example.com',
        'authHeader': 'X-Api-Key',
        'authPrefix': '',
        'tokenConfigKey': 'token',
      };
      final mcp = parseManifest(json).manifest!.provides.mcp!;
      expect(mcp.authHeader, 'X-Api-Key');
      expect(mcp.authPrefix, '');
    });

    test('没有 tokenConfigKey = 免鉴权', () {
      final json = base();
      (json['provides'] as Map<String, dynamic>)['mcp'] =
          <String, dynamic>{'url': 'https://x.example.com'};
      final mcp = parseManifest(json).manifest!.provides.mcp!;
      expect(mcp.tokenConfigKey, isNull);
      expect(mcp.headersWith(null), isEmpty);
    });

    test('没有 provides.mcp 就是 null', () {
      final json = base()..remove('provides');
      expect(parseManifest(json).manifest!.provides.mcp, isNull);
    });
  });

  group('headersWith', () {
    test('有 token 时拼出完整的头', () {
      final mcp = parseManifest(base()).manifest!.provides.mcp!;
      final h = mcp.headersWith('abc123');
      expect(h['Authorization'], 'Bearer abc123');
    });

    test('token 为空不发头（而不是发一个空值的头）', () {
      final mcp = parseManifest(base()).manifest!.provides.mcp!;
      expect(mcp.headersWith(''), isEmpty);
    });

    test('前缀为空时只有 token 本身', () {
      final json = base();
      (json['provides'] as Map<String, dynamic>)['mcp'] = <String, dynamic>{
        'url': 'https://x.example.com',
        'authHeader': 'X-Api-Key',
        'authPrefix': '',
        'tokenConfigKey': 'token',
      };
      final mcp = parseManifest(json).manifest!.provides.mcp!;
      expect(mcp.headersWith('abc')['X-Api-Key'], 'abc');
    });
  });

  group('交叉校验（这两条是重点）', () {
    test('tokenConfigKey 指向没声明的 config → 拒绝', () {
      final json = base();
      (json['provides'] as Map<String, dynamic>)['mcp'] = <String, dynamic>{
        'url': 'https://x.example.com',
        'tokenConfigKey': 'nope', // config 里没有这个
      };
      final r = parseManifest(json);
      expect(r.isValid, isFalse);
      expect(r.issues.map((e) => e.path), contains('provides.mcp.tokenConfigKey'));
      expect(
        r.issues.map((e) => e.message).join('; '),
        contains('nope'),
        reason: '报错要说出是哪个 key 写错了，否则作者不知道改什么',
      );
    });

    test('url 不是 http/https → 拒绝', () {
      final json = base();
      (json['provides'] as Map<String, dynamic>)['mcp'] =
          <String, dynamic>{'url': 'mcp://x'};
      final r = parseManifest(json);
      expect(r.isValid, isFalse);
      expect(r.issues.map((e) => e.path), contains('provides.mcp.url'));
    });

    test('url 为空 → 拒绝', () {
      final json = base();
      (json['provides'] as Map<String, dynamic>)['mcp'] =
          <String, dynamic>{'url': '   '};
      expect(parseManifest(json).isValid, isFalse);
    });

    test('mcp 不是对象 → 拒绝', () {
      final json = base();
      (json['provides'] as Map<String, dynamic>)['mcp'] = 'https://x';
      expect(parseManifest(json).isValid, isFalse);
    });
  });
}
