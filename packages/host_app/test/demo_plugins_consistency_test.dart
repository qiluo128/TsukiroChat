/// 演示插件清单的**一致性**检查。
///
/// 这个文件存在的原因：加一个演示插件要改**两个**地方 ——
///
///   scripts/sync_demo_plugins.mjs 的 INCLUDE   （把源码复制进 assets）
///   plugin_providers.dart 的 demoTemplatePlugins（装进设备）
///
/// 两个都是硬编码列表，漏一个的表现是「编译通过、测试通过、装完看不见」。
/// 这已经真实发生过（mcd-mcp 漏了两次）。
///
/// 所以这里用**目录**当事实来源，去断言那两个列表没有漏项。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiro_chat/providers/plugin_providers.dart';

void main() {
  test('assets/demo_plugins 下的每个插件都在 demoTemplatePlugins 里', () {
    final root = Directory('assets/demo_plugins');
    expect(root.existsSync(), isTrue, reason: '先跑 node scripts/sync_demo_plugins.mjs');

    final onDisk = <String>[];
    for (final e in root.listSync()) {
      if (e is! Directory) continue;
      // 只有带清单的目录才算插件
      if (!File('${e.path}/manifest.json').existsSync()) continue;
      onDisk.add(e.path.replaceAll('\\', '/').replaceFirst(RegExp(r'^assets/'), 'assets/'));
    }

    expect(onDisk, isNotEmpty, reason: '一个插件都没同步进来');

    final declared = demoTemplatePlugins.toSet();
    final missing = onDisk.where((d) => !declared.contains(d)).toList();

    expect(
      missing,
      isEmpty,
      reason: '这些插件在 assets 里但没在 demoTemplatePlugins 里，装完会看不见：\n'
          '  ${missing.join('\n  ')}\n\n'
          '修法：在 plugin_providers.dart 的 demoTemplatePlugins 加上它们，\n'
          '并把 demoTemplateSetVersion 提高（否则增量安装不会跑）。',
    );
  });

  test('demoTemplatePlugins 里的每一项都真的存在', () {
    final missing = <String>[];
    for (final p in demoTemplatePlugins) {
      if (!File('$p/manifest.json').existsSync()) missing.add(p);
    }
    expect(
      missing,
      isEmpty,
      reason: '这些声明了但 assets 里没有（忘了跑同步脚本？）：\n'
          '  ${missing.join('\n  ')}',
    );
  });
}
