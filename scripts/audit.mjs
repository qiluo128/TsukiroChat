#!/usr/bin/env node
// 全量架构检查（只读，不改代码）
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = process.cwd();
const SKIP = new Set(['.git', 'build', '.dart_tool', 'node_modules', '.dart', '.gradle', 'dist', '.zcode']);
function walk(dir, out = []) {
  let entries;
  try { entries = readdirSync(dir); } catch { return out; }
  for (const e of entries) {
    if (SKIP.has(e)) continue;
    const p = join(dir, e);
    let s;
    try { s = statSync(p); } catch { continue; }
    if (s.isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}
const all = walk(ROOT);
const read = (p) => readFileSync(p, 'utf8');
const rel = (p) => relative(ROOT, p).replace(/\\/g, '/');

const report = [];
function section(title) { report.push('', '═══ ' + title + ' ═══'); }

// ─────────── ① plugin_core 必须保持 Flutter-free ───────────
section('① plugin_core 的 Flutter-free 不变量');
const coreFiles = all.filter((p) => rel(p).startsWith('packages/plugin_core/lib/') && p.endsWith('.dart'));
const violations = [];
for (const f of coreFiles) {
  const c = read(f);
  if (/import\s+'package:flutter\//.test(c)) violations.push(rel(f));
  if (/import\s+'dart:ui'/.test(c)) violations.push(rel(f) + '  (dart:ui)');
}
report.push(violations.length === 0
  ? '  ✓ 干净（' + coreFiles.length + ' 个文件，没有 Flutter / dart:ui 依赖）'
  : '  ✗ 违反：\n' + violations.map((v) => '    ' + v).join('\n'));

// ─────────── ② 原语目录 vs 实际 handler 对账 ───────────
section('② 原语：目录条目 vs 已实现 handler');
const catalog = read('packages/plugin_core/lib/src/primitive/primitive_catalog.dart');
const demo = read('packages/plugin_core/lib/src/primitive/demo_primitives.dart');
const declared = [...catalog.matchAll(/_E\('([a-z][a-z0-9_.]*)'/g)].map((m) => m[1]);
const implBlock = demo.slice(demo.indexOf('demoPrimitiveHandlers'));
const implemented = new Set([...implBlock.matchAll(/'([a-z][a-z0-9_.]*)':\s*handle/g)].map((m) => m[1]));

const dupes = declared.filter((n, i) => declared.indexOf(n) !== i);
report.push('  目录声明 ' + declared.length + ' 个，有 handler ' + implemented.size + ' 个');
if (dupes.length) report.push('  ✗ **目录里有重复条目**：' + [...new Set(dupes)].join(', '));
const orphanHandlers = [...implemented].filter((n) => !declared.includes(n));
report.push(orphanHandlers.length
  ? '  ✗ **有 handler 但目录里没有**（永远调不到）：' + orphanHandlers.join(', ')
  : '  ✓ 没有孤儿 handler');

const byDomain = {};
for (const n of declared) { const d = n.split('.')[0]; byDomain[d] = byDomain[d] || { t: 0, i: 0 }; byDomain[d].t++; if (implemented.has(n)) byDomain[d].i++; }
const empty = Object.entries(byDomain).filter(([, v]) => v.i === 0).map(([k]) => k);
report.push('  一个都没实现的域（' + empty.length + ' 个）：' + empty.join(' '));

// ─────────── ③ 声明了但没人读的常量 ───────────
section('③ 声明了却没人引用的常量（"上限没生效"的高发区）');
const deadConsts = [];
for (const f of coreFiles.concat(all.filter((p) => rel(p).startsWith('packages/host_app/lib/'))) ) {
  if (!f.endsWith('.dart')) continue;
  const c = read(f);
  for (const m of c.matchAll(/static const (?:int|double|String) (\w+)\s*=/g)) {
    const name = m[1];
    if (name.length < 4) continue;
    // 在整个仓库里找该名字出现次数（>1 说明别处用过）
    let uses = 0;
    for (const g of all) {
      if (!g.endsWith('.dart')) continue;
      uses += (read(g).match(new RegExp('\\b' + name + '\\b', 'g')) || []).length;
    }
    // 声明处算 1 次；只有 1 次 = 没人用
    if (uses <= 1) deadConsts.push(rel(f) + ' :: ' + name);
  }
}
report.push(deadConsts.length ? deadConsts.map((d) => '  ✗ ' + d).join('\n') : '  ✓ 没找到');

// ─────────── ④ 空 catch（吞异常） ───────────
section('④ 空 catch（吞掉异常的地方）');
const emptyCatches = [];
for (const f of all) {
  if (!f.endsWith('.dart') || rel(f).includes('/test/')) continue;
  const lines = read(f).split('\n');
  lines.forEach((l, i) => {
    if (/catch\s*\([^)]*\)\s*\{\s*\}/.test(l) || /catch\s*\([^)]*\)\s*\{\s*\/\//.test(l)) {
      emptyCatches.push(rel(f) + ':' + (i + 1) + '  ' + l.trim());
    }
  });
}
report.push(emptyCatches.length ? emptyCatches.map((d) => '  · ' + d).join('\n') : '  ✓ 没找到');

// ─────────── ⑤ 从未被 import 的文件（孤儿文件） ───────────
section('⑤ 没有任何文件 import 的 Dart 文件');
const orphans = [];
for (const f of all) {
  const r = rel(f);
  if (!f.endsWith('.dart')) continue;
  if (!r.startsWith('packages/host_app/lib/') && !r.startsWith('packages/plugin_core/lib/') && !r.startsWith('packages/model_gateway/lib/')) continue;
  const base = r.split('/').pop();
  let imported = 0;
  for (const g of all) {
    if (!g.endsWith('.dart') || g === f) continue;
    if (read(g).includes(base)) imported++;
  }
  if (imported === 0) orphans.push(r);
}
report.push(orphans.length ? orphans.map((d) => '  ✗ ' + d).join('\n') : '  ✓ 没找到');

console.log(report.join('\n'));
