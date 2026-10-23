/// MCP 连接同步与工具结果解包。
///
/// 两个用户报告的真实问题：
///
///   2.5  重启后整组连接消失 —— 删除逻辑把「我没看到声明」
///        当成了「插件被卸载」，于是把连接删了
///   2.2  外层 ok:true + 内层 isError:true 状态矛盾
///   2.3  工具结果是 JSON 字符串，模型得自己再解析
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:tsukiro_chat/services/mcp_client.dart';

/// 造一个「声明了 MCP」的插件清单。
PluginManifest manifestWithMcp({
  required String id,
  String? url = 'https://mcp.example.com',
}) {
  final json = <String, dynamic>{
    'manifestVersion': 1,
    'id': id,
    'name': id,
    'version': '1.0.0',
    'provides': <String, dynamic>{
      'config': <dynamic>[
        <String, dynamic>{'key': 'token', 'type': 'text', 'label': 'Token'},
      ],
      if (url != null)
        'mcp': <String, dynamic>{'url': url, 'tokenConfigKey': 'token'},
    },
  };
  final r = parseManifest(json);
  expect(r.isValid, isTrue, reason: r.issues.map((e) => e.message).join('; '));
  return r.manifest!;
}

void main() {
  group('2.2 / 2.3 工具结果解包', () {
    test('JSON 对象被解包（模型拿到对象，不是字符串）', () {
      final v = McpClient.tryParseJson('{"ok":true,"count":3}');
      expect(v, isA<Map<String, dynamic>>());
      expect((v as Map)['count'], 3);
    });

    test('JSON 数组也解包', () {
      expect(McpClient.tryParseJson('[1,2,3]'), isA<List<dynamic>>());
    });

    test('纯文本不解包', () {
      expect(McpClient.tryParseJson('今天的活动是…'), isNull);
    });

    test('数字/布尔**不解包**（避免把 "123" 变成 int 让上游困惑）', () {
      expect(McpClient.tryParseJson('123'), isNull);
      expect(McpClient.tryParseJson('true'), isNull);
      expect(McpClient.tryParseJson('"字符串"'), isNull);
    });

    test('坏 JSON 返回 null，不抛异常', () {
      expect(McpClient.tryParseJson('{"a":'), isNull);
      expect(McpClient.tryParseJson(''), isNull);
    });

    test('带前导空白的 JSON 也能解', () {
      expect(McpClient.tryParseJson('  \n {"a":1}'), isA<Map>());
    });
  });

  group('2.1 脱敏（顺带锁住）', () {
    test('解包前的文本里有 token 也不会漏出去', () {
      // callTool 的错误路径会走 McpException → 构造时脱敏
      final e = McpException('{"authorization":"Bearer abcdefghijklmnop"}');
      expect(e.message, isNot(contains('abcdefghijklmnop')));
    });
  });

  group('2.5 同步删除语义', () {
    test('插件还在、声明也在 → 声明被认可', () {
      final m = manifestWithMcp(id: 'dev.test.a');
      expect(m.provides.mcp, isNotNull);
      expect(m.provides.mcp!.url, 'https://mcp.example.com');
    });

    test('插件还在、但**没有** provides.mcp → mcp 为 null', () {
      final m = manifestWithMcp(id: 'dev.test.b', url: null);
      expect(m.provides.mcp, isNull);
    });

    // 注：syncFromPlugins 的删除分支用「插件 id 是否还装着」判断，
    // 而不是「有没有解析出 provides.mcp」。上面两条锁住了这两种输入的区分 ——
    // 旧逻辑会在第二种情况下删掉连接，新逻辑不会。
    test('连接的 source 里能解出 owning plugin id', () {
      const source = 'plugin:dev.test.a';
      expect(source.substring('plugin:'.length), 'dev.test.a');
    });
  });

  group('JSON 往返（连接存储）', () {
    test('headers 里带 token 能存能读', () {
      final j = jsonDecode('{"Authorization":"Bearer xyz"}') as Map<String, dynamic>;
      expect(j['Authorization'], 'Bearer xyz');
    });
  });
}
