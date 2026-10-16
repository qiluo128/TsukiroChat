#!/usr/bin/env node
// 按代码实际状态更新文档（数字 + 过时断言）
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

let bad = 0;
function edit(file, pairs, label) {
  if (!existsSync(file)) { console.log('  ! 不存在 ' + file); bad++; return; }
  let c = readFileSync(file, 'utf8');
  let ok = 0;
  for (const [from, to] of pairs) {
    if (c.includes(from)) { c = c.replace(from, to); ok++; }
    else { console.log('  ! 未匹配 ' + file + ': ' + JSON.stringify(from.slice(0, 50))); bad++; }
  }
  writeFileSync(file, c, 'utf8');
  console.log('  ✓ ' + label + ' (' + ok + '/' + pairs.length + ')');
}

// 代码实际值（脚本里硬编码，但来源是 catalog 与 demo_primitives）
const catalog = readFileSync('packages/plugin_core/lib/src/primitive/primitive_catalog.dart', 'utf8');
const DOMAINS = new Set([...catalog.matchAll(/_E\('([a-z][a-z0-9_.]*)'/g)].map((m) => m[1].split('.')[0])).size;
const TOTAL = [...catalog.matchAll(/_E\('([a-z][a-z0-9_.]*)'/g)].length;
const demo = readFileSync('packages/plugin_core/lib/src/primitive/demo_primitives.dart', 'utf8');
const implBlock = demo.slice(demo.indexOf('demoPrimitiveHandlers'));
const IMPL = new Set([...implBlock.matchAll(/'([a-z][a-z0-9_.]*)':\s*handle/g)].map((m) => m[1])).size;

// ① 域数：把过时的具体数字换成实际值
for (const [file, pairs] of Object.entries({
  'docs/05-primitives.md': [
    ['23 个域', DOMAINS + ' 个域'],
    ['19 个域', DOMAINS + ' 个域'],
  ],
  'docs/11-roadmap.md': [
    ['19 个域', DOMAINS + ' 个域'],
  ],
  'docs/15-status.md': [
    ['24 域', DOMAINS + ' 域'],
    ['24 个域', DOMAINS + ' 个域'],
  ],
  'docs/16-extensibility.md': [
    ['23 个域', DOMAINS + ' 个域'],
  ],
})) {
  edit(file, pairs, '① ' + file);
}

// ② "4 个原语" 这类早已过时的表述
for (const file of ['docs/11-roadmap.md', 'docs/16-extensibility.md']) {
  edit(file, [
    ['4 个原语', TOTAL + ' 个原语'],
  ], '② ' + file);
}

// ③ 代码注释里的过时断言
edit('packages/plugin_core/lib/plugin_core.dart', [
  ['`SlotRegistry`（待做）', '`SlotRegistry`'],
], '③ plugin_core.dart 的"待做"');

edit('packages/host_app/lib/providers/plugin_providers.dart', [
  ['其余 105 个已注册未实现', '其余 ' + (TOTAL - IMPL) + ' 个已注册未实现'],
], '③ plugin_providers.dart 的未实现数');

console.log('\n  实际：' + DOMAINS + ' 个域 / ' + TOTAL + ' 个原语 / ' + IMPL + ' 个已实现');
console.log(bad === 0 ? '\n完成。' : '\n有 ' + bad + ' 处问题。');
