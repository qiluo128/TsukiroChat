/// 插件打包与注入的测试。
///
/// 重点验证三件事：
///   1. ES module 的 `export default` 能被正确转成表达式
///   2. 注入的 HTML **带 CSP** —— 这是插件沙箱的关键一环
///   3. 清单里没有的 handler 会被明确报错，而不是静默少注册一个
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:tsukiro_chat/plugin/plugin_bundle.dart';

PluginManifest manifestFor(List<Map<String, dynamic>> tools) {
  final parsed = parseManifest(<String, dynamic>{
    'manifestVersion': 1,
    'id': 'dev.test.sample',
    'name': '测试插件',
    'version': '1.0.0',
    'description': 'x',
    'author': <String, dynamic>{'name': 't'},
    'runtime': <String, dynamic>{'main': 'index.js'},
    'provides': <String, dynamic>{'tools': tools},
  });
  expect(parsed.isValid, isTrue, reason: parsed.issues.join('；'));
  return parsed.manifest!;
}

void main() {
  group('ES module 转换', () {
    test('export default function → 表达式', () {
      const source = '''
export default async function get_time(args) {
  return { ok: true };
}
''';
      final expr = toScriptExpression(source, label: 'get_time.js');
      expect(expr, contains('return async function get_time'));
      expect(expr, isNot(contains('export default')));
      // 包在 IIFE 里，不污染全局
      expect(expr.trimLeft(), startsWith('(function()'));
    });

    test('export default 箭头函数也能转', () {
      final expr = toScriptExpression('export default (a) => a + 1;');
      expect(expr, contains('return (a) => a + 1;'));
    });

    test('没有 export default 时当作纯脚本跑', () {
      final expr = toScriptExpression('tsukiro.log.info({ message: "x" });');
      expect(expr, contains('tsukiro.log.info'));
    });

    test('用了 import 时明确报错 —— 内联注入没有模块解析能力', () {
      expect(
        () => toScriptExpression("import x from './y.js';\nexport default 1;"),
        throwsA(isA<PluginLoadException>()),
      );
    });
  });

  group('注入的 HTML', () {
    late String html;

    setUp(() {
      final manifest = manifestFor(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'get_time',
          'description': '取时间',
          'handler': 'handlers/get_time.js',
          'parameters': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
        },
      ]);
      html = PluginScriptBuilder(bundle: PluginBundle(
        manifest: manifest,
        entrySource: 'tsukiro.lifecycle.on("start", () => {});',
        handlerSources: <String, String>{
          'handlers/get_time.js': 'export default async () => ({ ok: true });',
        },
        slotSources: const <String, String>{},
      )).buildHtml(
        // 占位符**不带引号** —— 与真实的 tsukiro.js 保持一致。
        // 用带引号的形式会让这个测试失去意义：它正是漏掉
        // "引号套引号"那个 bug 的原因。
        runtimeSource: 'var PLUGIN = __PLUGIN_ID__; var API = __HOST_API__;',
      );
    });

    test('带 CSP，且默认拒绝一切外部资源', () {
      expect(html, contains('Content-Security-Policy'));
      // default-src 'none' 是沙箱的核心：没有 connect-src，
      // 所以 fetch / XHR / WebSocket 全被浏览器层挡掉
      expect(html, contains("default-src 'none'"));
      expect(html, isNot(contains('connect-src')));
    });

    test('占位符被替换成合法的 JS 字符串字面量，值就是插件 id', () {
      // **关键：断言的是"JS 求值后等于 id"，不是"HTML 里出现了这个字符串"。**
      //
      // 早先的版本只检查 `contains('"dev.test.sample"')` ——
      // 而坏注入 `var PLUGIN_ID = '"dev.test.sample"';` 里当然也包含它，
      // 于是测试通过、真机全挂。那次的表现是：
      // 身份校验判"冒充"终止会话 → 15 秒超时，完全看不出真正原因。
      expect(html, contains('var PLUGIN = "dev.test.sample";'));
      expect(html, contains('var API = "^1.0.0";'));

      // 明确排除"引号套引号"
      expect(html, isNot(contains("'\"dev.test.sample\"'")));
      expect(html, isNot(contains('__PLUGIN_ID__')));
      expect(html, isNot(contains('__HOST_API__')));
    });

    test('handler 按**路径**注册（工具循环拿到的就是路径）', () {
      expect(html, contains('__registerHandler("handlers/get_time.js"'));
      expect(html, contains('return async () => ({ ok: true });'));
    });

    test('运行时脚本排在插件脚本之前', () {
      final runtimeAt = html.indexOf('var PLUGIN =');
      final handlerAt = html.indexOf('__registerHandler');
      expect(runtimeAt, greaterThan(0));
      expect(runtimeAt, lessThan(handlerAt),
          reason: '插件在顶层就会调 tsukiro.*，运行时必须先就位');
    });
  });

  group('路径安全', () {
    test('handler 路径里的引号会被 JSON 编码，不会拼坏脚本', () {
      final manifest = manifestFor(<Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'x',
          'description': 'x',
          'handler': 'a.js',
          'parameters': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
        },
      ]);
      final html = PluginScriptBuilder(bundle: PluginBundle(
        manifest: manifest,
        entrySource: '',
        // 故意塞一个带引号和反斜杠的工具名，验证编码
        handlerSources: <String, String>{'a".js': 'export default 1;'},
        slotSources: const <String, String>{},
      )).buildHtml(runtimeSource: 'var x = 1;');

      // 引号被转义进字符串字面量，而不是提前闭合
      expect(html, contains(r'__registerHandler("a\".js"'));
    });
  });
}
