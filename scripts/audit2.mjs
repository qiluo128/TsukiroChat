#!/usr/bin/env node
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = process.cwd();
const SKIP = new Set(['.git', 'build', '.dart_tool', 'node_modules', '.dart', '.gradle', 'dist', '.zcode']);
function walk(dir, out = []) {
  let entries; try { entries = readdirSync(dir); } catch { return out; }
  for (const e of entries) {
    if (SKIP.has(e)) continue;
    const p = join(dir, e);
    let s; try { s = statSync(p); } catch { continue; }
    if (s.isDirectory()) walk(p, out); else out.push(p);
  }
  return out;
}
const all = walk(ROOT);
const read = (p) => readFileSync(p, 'utf8');
const rel = (p) => relative(ROOT, p).replace(/\\/g, '/');
const out = [];
const say = (s) => out.push(s);

// ─────── ① 已知缺口标记地图 ───────
say('═══ ① 代码里的"未实现 / 待办"标记 ═══');
const markers = [];
for (const f of all) {
  const r = rel(f);
  if (!/\.(dart|js|mjs|ps1)$/.test(r)) continue;
  if (r.startsWith('scripts/')) continue;
  const lines = read(f).split('\n');
  lines.forEach((l, i) => {
    if (/\\b(TODO|FIXME|HACK|XXX)\\b|\u6682\u672a|\u672a\u5b9e\u73b0|\u5f85\u505a|\u5f85\u52a0/i.test(l) && !/^\s*\/\/\s*$/.test(l)) {
      markers.push(r + ':' + (i + 1) + '  ' + l.trim().slice(0, 110));
    }
  });
}
say(markers.length ? markers.map((m) => '  · ' + m).join('\n') : '  （无）');

// ─────── ② 哪些 lib 文件没有对应的测试覆盖 ───────
say('');
say('═══ ② 没有测试文件提及的 lib 模块 ═══');
const tests = all.filter((p) => rel(p).includes('/test/') && p.endsWith('.dart'));
const testText = tests.map(read).join('\n');
const libs = all.filter((p) => {
  const r = rel(p);
  return p.endsWith('.dart') &&
    (r.startsWith('packages/host_app/lib/') || r.startsWith('packages/plugin_core/lib/'));
});
const uncovered = [];
for (const f of libs) {
  const base = rel(f).split('/').pop().replace('.dart', '');
  if (base.length < 4) continue;
  // 测试里提到过这个文件名或它的主类名，就算有覆盖
  const mentioned = testText.includes(base) ||
    new RegExp('\\b' + base.replace(/(^|_)(\w)/g, (_, __, c) => c.toUpperCase()) + '\\b').test(testText);
  if (!mentioned) uncovered.push(rel(f));
}
say('  lib 文件 ' + libs.length + ' 个，测试未提及 ' + uncovered.length + ' 个：');
say(uncovered.map((u) => '  · ' + u).join('\n'));

// ─────── ③ 文档与代码的明显漂移 ───────
say('');
say('═══ ③ 文档里的数字与代码实际对不上 ═══');
const docs = all.filter((p) => rel(p).startsWith('docs/') && p.endsWith('.md'));
const catalog = read('packages/plugin_core/lib/src/primitive/primitive_catalog.dart');
const declaredCount = [...catalog.matchAll(/_E\('([a-z][a-z0-9_.]*)'/g)].length;
const demo = read('packages/plugin_core/lib/src/primitive/demo_primitives.dart');
const implBlock = demo.slice(demo.indexOf('demoPrimitiveHandlers'));
const implCount = new Set([...implBlock.matchAll(/'([a-z][a-z0-9_.]*)':\s*handle/g)].map((m) => m[1])).size;
say('  代码实际：' + declaredCount + ' 个原语，' + implCount + ' 个已实现');
for (const d of docs) {
  const c = read(d);
  for (const m of c.matchAll(/(\d+)\s*个原语/g)) {
    if (Number(m[1]) !== declaredCount) say('  · ' + rel(d) + ' 说 "' + m[0] + '"，实际 ' + declaredCount);
  }
  for (const m of c.matchAll(/(\d+)\s*个?域/g)) {
    const domains = new Set([...catalog.matchAll(/_E\('([a-z][a-z0-9_.]*)'/g)].map((x) => x[1].split('.')[0])).size;
    if (Number(m[1]) !== domains && Number(m[1]) > 5) say('  · ' + rel(d) + ' 说 "' + m[0] + '"，实际 ' + domains);
  }
}

// ─────── ④ host_app 里直接依赖 data 层的 UI 文件（分层检查） ───────
say('');
say('═══ ④ 分层：UI 直接碰数据层的文件数 ═══');
const uiFiles = all.filter((p) => rel(p).startsWith('packages/host_app/lib/ui/') && p.endsWith('.dart'));
const directData = uiFiles.filter((p) => /import\s+'\.\.\/(\.\.\/)?data\//.test(read(p)));
say('  ui/ 下 ' + uiFiles.length + ' 个文件，其中 ' + directData.length + ' 个直接 import 了 data/：');
say(directData.map((u) => '  · ' + rel(u)).join('\n'));

// ─────── ⑤ 大文件（复杂度信号） ───────
say('');
say('═══ ⑤ 超过 600 行的文件 ═══');
const big = libs.map((p) => ({ p: rel(p), n: read(p).split('\n').length }))
  .filter((x) => x.n > 600).sort((a, b) => b.n - a.n);
say(big.length ? big.map((x) => '  · ' + String(x.n).padStart(4) + '  ' + x.p).join('\n') : '  （无）');

console.log(out.join('\n'));
