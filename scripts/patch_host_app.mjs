#!/usr/bin/env node
/**
 * 一次性补丁：修 host_app 的 analyzer 报错。
 *
 * 用 Node 而不是 PowerShell 做这件事：这些补丁都要在单引号/双引号/反引号
 * 之间来回嵌套，PowerShell 的 here-string 转义规则会把人逼疯（刚才就失败了）。
 *
 * 用法: node scripts/patch_host_app.mjs
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const BASE = 'packages/host_app/lib';

/** [相对路径, [[旧, 新], ...]] */
const PATCHES = [
  ['data/models.dart', [
    ['  int? completionTokens;', '  int? tokensCompletion;'],
  ]],

  ['providers/chat_controller.dart', [
    ["import '../data/models.dart';", "import '../data/database.dart';\nimport '../data/models.dart';"],
  ]],

  ['app.dart', [
    [
      "      routes: <String, WidgetBuilder>{\n        Routes.chat: (_) => const ChatPage(),\n        Routes.settings: (_) => const SettingsPage(),\n      },",
      "      routes: <String, WidgetBuilder>{\n        // chat 需要 sessionId，不能用无参路由 —— 由会话列表 push 进来\n        Routes.settings: (_) => const SettingsPage(),\n      },",
    ],
    ["import 'ui/chat_page.dart';\n", ''],
  ]],

  ['theme/design_tokens.dart', [
    ["import 'dart:ui' show Color;\n\n", ''],
  ]],

  ['ui/chat_page.dart', [
    ["import 'package:flutter/services.dart';\n", ''],
    ['  Widget _EmptyHint({required void Function(String) onPick}) => _EmptyState(onPick: onPick);\n\n', ''],
    ['                  ? _EmptyHint(onPick: _fillInput)', '                  ? _EmptyState(onPick: _fillInput)'],
  ]],

  ['ui/message_bubble.dart', [
    ["import 'package:plugin_core/plugin_core.dart';\n", ''],
    ["              if (!isUser) _Avatar(name: '雪', tokens: t),", "              if (!isUser) const _Avatar(name: '雪'),"],
    [
      'class _Avatar extends StatelessWidget {\n  const _Avatar({required this.name, required this.tokens});\n\n  final String name;\n  final dynamic tokens;',
      'class _Avatar extends StatelessWidget {\n  const _Avatar({required this.name});\n\n  final String name;',
    ],
  ]],

  ['ui/session_list_page.dart', [
    ['separatorBuilder: (_, __) => Divider(', 'separatorBuilder: (_, _) => Divider('],
  ]],
];

let failed = 0;
for (const [rel, pairs] of PATCHES) {
  const path = join(BASE, rel);
  if (!existsSync(path)) {
    console.log(`  ! 文件不存在: ${path}`);
    failed++;
    continue;
  }
  let text = readFileSync(path, 'utf8');
  let changed = 0;
  for (const [from, to] of pairs) {
    if (text.includes(from)) {
      text = text.replace(from, to);
      changed++;
    } else {
      console.log(`  ! 未匹配 ${rel}: ${JSON.stringify(from.slice(0, 60))}`);
    }
  }
  if (changed > 0) {
    writeFileSync(path, text, 'utf8');
    console.log(`  已改 ${rel}（${changed}/${pairs.length} 处）`);
  }
  if (changed !== pairs.length) failed++;
}

console.log(failed === 0 ? '\n全部补丁已应用。' : `\n有 ${failed} 处未应用，见上。`);
process.exit(failed === 0 ? 0 : 1);
