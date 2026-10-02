#!/usr/bin/env node
/**
 * host_app 补丁（第二批）。
 *
 * 与 patch_host_app.mjs 分开是因为第一批已经应用过了 ——
 * 补丁脚本做成幂等的，重跑不会重复改。
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const BASE = 'packages/host_app/lib';

const PATCHES = [
  ['data/database.dart', [
    ["'tokens_completion': m.completionTokens,", "'tokens_completion': m.tokensCompletion,"],
  ]],

  ['providers/chat_controller.dart', [
    ["import 'package:model_gateway/model_gateway.dart';\n", ''],
  ]],

  ['ui/settings_page.dart', [
    [
      `          children: ProviderProtocol.values.map((p) {
            return RadioListTile<ProviderProtocol>(
              value: p,
              groupValue: _protocol,
              title: Text(_protocolLabel(p)),
              subtitle: Text(_protocolHint(p), style: const TextStyle(fontSize: 12)),
              onChanged: (v) => Navigator.pop(ctx, v),
            );
          }).toList(growable: false),`,
      `          // 不用 RadioListTile：它的 groupValue/onChanged 在 Flutter 3.32+
          // 已废弃（要包一层 RadioGroup）。这里就一个简单选择列表，
          // ListTile + 勾选图标更直接，也少一层状态传递。
          children: ProviderProtocol.values.map((p) {
            final selected = p == _protocol;
            return ListTile(
              title: Text(_protocolLabel(p)),
              subtitle: Text(_protocolHint(p), style: const TextStyle(fontSize: 12)),
              trailing: selected
                  ? Icon(Icons.check, size: 18, color: context.tokens.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, p),
            );
          }).toList(growable: false),`,
    ],
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

console.log(failed === 0 ? '\n第二批补丁已应用。' : `\n有 ${failed} 处未应用。`);
process.exit(failed === 0 ? 0 : 1);
