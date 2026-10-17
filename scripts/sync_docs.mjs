#!/usr/bin/env node
// 稳健版：用正则把所有 "N 个域" / "N 个原语" 换成代码实际值，
// 不依赖上一次替换后的具体数字。
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const CAT = 'packages/plugin_core/lib/src/primitive/primitive_catalog.dart';
const catalog = readFileSync(CAT, 'utf8');
const names = [...catalog.matchAll(/_E\('([a-z][a-z0-9_.]*)'/g)].map((m) => m[1]);
const DOMAINS = new Set(names.map((n) => n.split('.')[0])).size;
const TOTAL = names.length;
const demo = readFileSync('packages/plugin_core/lib/src/primitive/demo_primitives.dart', 'utf8');
const implBlock = demo.slice(demo.indexOf('demoPrimitiveHandlers'));
const IMPL = new Set([...implBlock.matchAll(/'([a-z][a-z0-9_.]*)':\s*handle/g)].map((m) => m[1])).size;

let changed = 0;
for (const f of readdirSync('docs').filter((x) => x.endsWith('.md'))) {
  const p = join('docs', f);
  let c = readFileSync(p, 'utf8');
  const before = c;
  c = c.replace(/\d+(?=\s*个域)/g, String(DOMAINS));
  c = c.replace(/\d+(?=\s*域\b)/g, String(DOMAINS));
  c = c.replace(/\d+(?=\s*个原语)/g, String(TOTAL));
  if (c !== before) { writeFileSync(p, c, 'utf8'); changed++; console.log('  ✓ docs/' + f); }
}

// 代码注释里的未实现数
const pp = 'packages/host_app/lib/providers/plugin_providers.dart';
let ppc = readFileSync(pp, 'utf8');
const before = ppc;
ppc = ppc.replace(/其余\s*\d+\s*个已注册未实现/, '其余 ' + (TOTAL - IMPL) + ' 个已注册未实现');
if (ppc !== before) { writeFileSync(pp, ppc, 'utf8'); console.log('  ✓ plugin_providers.dart'); }

console.log('\n  实际：' + DOMAINS + ' 个域 / ' + TOTAL + ' 个原语 / ' + IMPL + ' 个已实现');
console.log('  改动了 ' + changed + ' 个文档');
