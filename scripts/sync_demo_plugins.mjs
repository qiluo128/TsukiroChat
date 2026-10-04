#!/usr/bin/env node
/**
 * 把仓库根目录的 `plugins/` 同步到宿主工程的 assets 里，**并自动更新 pubspec 的 asset 声明**。
 *
 * ## 为什么要复制而不是直接引用
 *
 * Flutter 的 asset 只能来自包内路径，不能引用 `../../plugins/`。
 * 所以需要一次复制。用脚本而不是手工复制：**保持单一事实来源** ——
 * `plugins/` 才是插件源码所在，assets 里那份是构建产物（已 gitignore）。
 *
 * ## 为什么 pubspec 也要脚本改
 *
 * **Flutter 的目录 asset 声明不递归。** 写 `- assets/demo_plugins/` 只会
 * 带上那一层的文件，`time-plugin/manifest.json` 和
 * `time-plugin/handlers/get_time.js` 都不会进包 —— 而且**没有任何报错**，
 * 直到运行时读 asset 才失败。
 *
 * pubspec 又不支持通配符，所以只能把每一层目录都列出来。
 * 手工维护一定会漏（新加一个插件、或插件里多一个子目录），
 * 所以交给这个脚本生成。
 *
 * 用法: node scripts/sync_demo_plugins.mjs
 */
import {
  readdirSync, readFileSync, writeFileSync, mkdirSync, rmSync,
  existsSync, statSync,
} from 'node:fs';
import path from 'node:path';

const SRC = 'plugins';
const DEST = 'packages/host_app/assets/demo_plugins';
const PUBSPEC = 'packages/host_app/pubspec.yaml';

/** 只同步这些插件（全同步会让 APK 变大，而且不是每个都适合演示）。 */
const INCLUDE = ['time-plugin', 'translate-button', 'sakura-theme', 'status-panel'];

const MARK_START = '    # >>> demo_plugins (由 scripts/sync_demo_plugins.mjs 生成，勿手改)';
const MARK_END = '    # <<< demo_plugins';

/** 递归复制，返回复制到的文件数，并收集所有**含文件的目录**（pubspec 要列这些）。 */
function copyDir(from, to, dirs) {
  mkdirSync(to, { recursive: true });
  let count = 0;
  let hasFile = false;

  for (const entry of readdirSync(from, { withFileTypes: true })) {
    const src = path.join(from, entry.name);
    const dst = path.join(to, entry.name);
    if (entry.isDirectory()) {
      const sub = copyDir(src, dst, dirs);
      count += sub.count;
      if (sub.count > 0) hasFile = true;
    } else if (entry.isFile()) {
      const size = statSync(src).size;
      if (size > 512 * 1024) {
        console.log(`  · 跳过 ${src}（${(size / 1024).toFixed(0)} KB 太大）`);
        continue;
      }
      writeFileSync(dst, readFileSync(src));
      count++;
      hasFile = true;
    }
  }

  // 只有真的装了东西的目录才需要声明 —— 空目录声明了会让 pubspec 报错。
  //
  // 路径要**相对包根**（pubspec 所在目录），不是相对仓库根 ——
  // 写成 `packages/host_app/assets/...` 的话 Flutter 找不到，而且报错很含糊。
  if (hasFile) dirs.push(path.relative(path.dirname(PUBSPEC), to).replaceAll('\\', '/'));
  return { count };
}

/** 把 asset 声明写进 pubspec（替换标记之间的内容）。 */
function updatePubspec(dirs) {
  const text = readFileSync(PUBSPEC, 'utf8');
  const startIdx = text.indexOf(MARK_START);
  const endIdx = text.indexOf(MARK_END);

  const block = [MARK_START, ...dirs.map((d) => `    - ${d}/`), MARK_END].join('\n');

  let next;
  if (startIdx >= 0 && endIdx > startIdx) {
    const afterEnd = text.indexOf('\n', endIdx);
    next = text.slice(0, startIdx) + block + text.slice(afterEnd);
  } else {
    // 首次：插在 `- assets/plugin_runtime/` 之后
    const anchor = '    - assets/plugin_runtime/\n';
    const at = text.indexOf(anchor);
    if (at < 0) throw new Error('找不到插入位置：pubspec 里没有 assets/plugin_runtime/');
    const insertAt = at + anchor.length;
    next = text.slice(0, insertAt) + block + '\n' + text.slice(insertAt);
  }

  writeFileSync(PUBSPEC, next, 'utf8');
  return dirs.length;
}

if (!existsSync(SRC)) {
  console.error(`✗ 找不到 ${SRC}`);
  process.exit(1);
}

// 清空重建 —— 残留文件会让人以为某个插件还在
if (existsSync(DEST)) rmSync(DEST, { recursive: true, force: true });

const available = readdirSync(SRC, { withFileTypes: true })
  .filter((e) => e.isDirectory())
  .map((e) => e.name);

console.log(`源目录: ${SRC}`);
console.log(`全部插件: ${available.join(', ')}\n`);

const dirs = [];
let total = 0;
for (const name of INCLUDE) {
  if (!available.includes(name)) {
    console.log(`  ! ${name} 不存在，跳过`);
    continue;
  }
  const r = copyDir(path.join(SRC, name), path.join(DEST, name), dirs);
  console.log(`  ✓ ${name.padEnd(20)} ${r.count} 个文件`);
  total += r.count;
}

const n = updatePubspec(dirs);
console.log(`\n共 ${total} 个文件；pubspec 里写了 ${n} 条目录声明。`);
console.log('\n**注意**：Flutter 的目录 asset 不递归，所以每一层都要列 ——');
console.log('这就是为什么要自动生成而不是手写。');
