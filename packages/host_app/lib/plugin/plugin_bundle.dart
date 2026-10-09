/// 插件代码的加载与打包。
///
/// 插件的 handler 文件是 ES module（`export default async function`），
/// 但 WebView 里我们只能注入普通 `<script>`。所以这里做一次转换。
///
/// **为什么不给 WebView 开 `type="module"`**：模块需要 URL 加载，
/// 而插件代码是内联注入的（为了沙箱 —— 不走 file:// 就没有文件访问面）。
/// 转换比开文件访问安全得多。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';

/// 一个加载好的插件：清单 + 全部 JS 源码。
class PluginBundle {
  const PluginBundle({
    required this.manifest,
    required this.entrySource,
    required this.handlerSources,
    required this.slotSources,
    this.assets = const <String, String>{},
    this.pageSources = const <String, String>{},
  });

  final PluginManifest manifest;

  /// `runtime.main` 的源码。
  final String entrySource;

  /// 工具名 → handler 文件源码。
  final Map<String, String> handlerSources;

  /// 插槽名 → 渲染函数文件源码。
  final Map<String, String> slotSources;

  /// 插件目录下的静态资源（路径 → 文本内容）。目前只用于图标。
  final Map<String, String> assets;

  /// 页面/Surface entry 文件的源码，路径相对于插件根目录。
  final Map<String, String> pageSources;
}

/// 加载失败。
class PluginLoadException implements Exception {
  PluginLoadException(this.message);
  final String message;
  @override
  String toString() => 'PluginLoadException: $message';
}

/// 从磁盘目录加载插件。
///
/// [directory] 是插件的根目录（里面应当有 manifest.json）。
Future<PluginBundle> loadBundleFromDirectory(String directory) async {
  final manifestFile = File(p.join(directory, 'manifest.json'));
  if (!manifestFile.existsSync()) {
    throw PluginLoadException('找不到 manifest.json（$directory）');
  }

  final parsed = parseManifestJson(await manifestFile.readAsString());
  if (!parsed.isValid) {
    throw PluginLoadException('清单不合法：${parsed.issues.join('；')}');
  }
  final manifest = parsed.manifest!;

  final runtime = manifest.runtime;
  if (runtime == null) {
    // 零代码插件：只有声明式内容（主题/人设/技能），没有 JS 可跑。
    // 这是**合法状态**，不是错误 —— 见 docs/18 与零代码插件设计。
    return PluginBundle(
      manifest: manifest,
      entrySource: '',
      handlerSources: const <String, String>{},
      slotSources: const <String, String>{},
      pageSources: const <String, String>{},
    );
  }

  Future<String> read(String relative) async {
    final file = File(p.join(directory, relative));
    if (!file.existsSync()) {
      throw PluginLoadException('清单里声明了 $relative，但文件不存在');
    }
    return file.readAsString();
  }

  final pageSources = <String, String>{};
  final pageEntries = <String>{
    ...manifest.provides.pages.map((page) => page.entry),
    ...manifest.provides.surfaces.map((surface) => surface.entry).whereType<String>(),
  };
  for (final entry in pageEntries) {
    pageSources[entry] = await read(entry);
  }

  final handlers = <String, String>{};
  for (final tool in manifest.provides.tools) {
    // **按 handler 路径注册**，不是工具名。
    // 工具循环拿到的是 [RegisteredTool.handler]（清单里的文件路径），
    // 它不知道工具名 —— 用路径当键可以原样透传，不做一层映射。
    handlers[tool.handler] = await read(tool.handler);
    for (final cap in manifest.provides.capabilities) {
      if (handlers.containsKey(cap.handler)) continue;
      handlers[cap.handler] = await read(cap.handler);
    }
  }

  // 注意：**不**从 manifest 读插槽脚本。
  //
  // `provides.ui` 里的 UiDeclaration 是**声明式**的（button / toggle /
  // section / text…），由宿主直接渲染，没有对应的 JS 文件。
  // 程序式渲染的插槽才走 `tsukiro.defineSlot`，那是插件在入口脚本里自己调的。
  return PluginBundle(
    manifest: manifest,
    entrySource: await read(runtime.main),
    handlerSources: handlers,
    slotSources: const <String, String>{},
    pageSources: pageSources,
  );
}

/// 从内置资源加载（首次启动装演示插件用）。
Future<PluginBundle> loadBundleFromAssets(String assetDir) async {
  final manifestText = await rootBundle.loadString('$assetDir/manifest.json');
  final parsed = parseManifestJson(manifestText);
  if (!parsed.isValid) {
    throw PluginLoadException('清单不合法：${parsed.issues.join('；')}');
  }
  final manifest = parsed.manifest!;

  final runtime = manifest.runtime;
  if (runtime == null) {
    return PluginBundle(
      manifest: manifest,
      entrySource: '',
      handlerSources: const <String, String>{},
      slotSources: const <String, String>{},
      pageSources: const <String, String>{},
    );
  }

  final pageSources = <String, String>{};
  final pageEntries = <String>{
    ...manifest.provides.pages.map((page) => page.entry),
    ...manifest.provides.surfaces.map((surface) => surface.entry).whereType<String>(),
  };
  for (final entry in pageEntries) {
    pageSources[entry] = await rootBundle.loadString('$assetDir/$entry');
  }

  final handlers = <String, String>{};
  for (final tool in manifest.provides.tools) {
    handlers[tool.handler] = await rootBundle.loadString('$assetDir/${tool.handler}');

    // 能力 handler 走同一套加载 —— 它和工具 handler 在插件侧
    // 是同一类东西（一个注册过的 JS 函数）。
    for (final cap in manifest.provides.capabilities) {
      if (handlers.containsKey(cap.handler)) continue;
      handlers[cap.handler] = await rootBundle.loadString('$assetDir/${cap.handler}');
    }
  }

  return PluginBundle(
    manifest: manifest,
    entrySource: await rootBundle.loadString('$assetDir/${runtime.main}'),
    handlerSources: handlers,
    slotSources: const <String, String>{},
    pageSources: pageSources,
  );
}

/// 把插件打包成一段可在 WebView 里直接跑的 JS。
///
/// 顺序很重要：**运行时先、插件后**，因为插件在顶层就会调 `tsukiro.*`
/// （比如 `tsukiro.lifecycle.on(...)`）。
class PluginScriptBuilder {
  const PluginScriptBuilder({required this.bundle});

  final PluginBundle bundle;

  /// 生成注入用的 HTML。
  ///
  /// ## 沙箱
  ///
  /// CSP `default-src 'none'` 是这里最关键的一行：
  ///   - 禁止 fetch / XMLHttpRequest / WebSocket（没有 connect-src）
  ///   - 禁止加载外部图片、字体、iframe、媒体
  ///   - 只允许内联脚本和内联样式
  ///
  /// 也就是说，**插件代码即使想往外发数据也发不出去** ——
  /// 想联网必须走 `tsukiro.net.*` 原语，那条路要过权限门禁。
  ///
  /// 这是第二道防线：第一道是 `NavigationDelegate` 挡住一切导航。
  String buildHtml({required String runtimeSource}) {
    final pluginId = bundle.manifest.id;
    final hostApi = bundle.manifest.hostApi ?? '^1.0.0';

    // **占位符本身不带引号**（见 tsukiro.js 顶部的说明）。
    //
    // `jsonEncode` 生成的字面量自带引号，直接替换裸名字即可。
    // 早先占位符写成 `'__PLUGIN_ID__'`，替换出来是 `'"dev.x"'` ——
    // JS 求值得到带引号字符的字符串，握手时身份校验判"冒充"终止会话，
    // 而表现只是"15 秒没完成握手"。
    final runtime = runtimeSource
        .replaceAll('__PLUGIN_ID__', _jsStringLiteral(pluginId))
        .replaceAll('__HOST_API__', _jsStringLiteral(hostApi));

    final scripts = StringBuffer()
      ..writeln('<script>$runtime</script>');

    // handler 注册：把每个 handler 文件包成函数并登记到工具名上
    bundle.handlerSources.forEach((toolName, source) {
      scripts.writeln(
        '<script>window.tsukiro.__registerHandler('
        '${_jsStringLiteral(toolName)}, ${toScriptExpression(source, label: toolName)});'
        '</script>',
      );
    });

    // 插槽渲染函数
    bundle.slotSources.forEach((slot, source) {
      final expr = toScriptExpression(source, label: slot);
      scripts.writeln(
        '<script>window.tsukiro.defineSlot('
        '${_jsStringLiteral(slot)}, $expr);'
        '</script>',
      );
    });

    // 入口最后跑 —— 它可能用到上面注册的东西
    if (bundle.entrySource.trim().isNotEmpty) {
      scripts.writeln('<script>${toScriptExpression(bundle.entrySource, label: 'entry')};</script>');
    }

    return '''
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
<title>$pluginId</title>
<style>
  html,body{margin:0;padding:0;background:transparent;
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    font-size:14px;color:#1F2430;}
  *{box-sizing:border-box;}
</style>
</head>
<body>
$scripts
</body>
</html>
''';
  }
}

/// 把一段 ES module 源码转成**表达式**（求值得到它的 default 导出）。
///
/// 只处理 `export default`，遇到 `import` 明确报错 ——
/// 内联注入没有模块解析能力，静默失败会让插件作者以为代码写错了别的地方。
String toScriptExpression(String source, {String label = '?'}) {
  if (RegExp(r'^\s*import\s', multiLine: true).hasMatch(source)) {
    throw PluginLoadException(
      '$label 用了 import 语句，但插件是内联注入的，没有模块解析能力。'
      '请把依赖内联进同一个文件。',
    );
  }

  final match = RegExp(r'^\s*export\s+default\s+', multiLine: true).firstMatch(source);
  if (match == null) {
    // 没有 export default：把整个文件当一个脚本跑，值取 window 上的约定名。
    // 比直接报错好 —— 有些 handler 就是纯副作用代码。
    return '(function(){"use strict";\n$source\n})()';
  }

  final body = source.replaceRange(match.start, match.end, 'return ');
  return '(function(){"use strict";\n$body\n})()';
}

/// 转成安全的 JS 字符串字面量。
///
/// 用 `jsonEncode` 而不是手写转义：它已经处理好了引号、反斜杠、
/// 控制字符和 Unicode，自己写一定会漏。
String _jsStringLiteral(String value) => jsonEncode(value);
