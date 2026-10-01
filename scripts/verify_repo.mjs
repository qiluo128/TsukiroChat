#!/usr/bin/env node
/**
 * 从 GitHub API 核验推送结果。
 *
 * 用法: node --use-system-ca scripts/verify_repo.mjs <owner/repo> [branch]
 */
import https from 'node:https';

const TOKEN = process.env.GH_TOKEN;
const REPO = process.argv[2] ?? 'qiluo128/TsukiroChat';
const BRANCH = process.argv[3] ?? 'main';

function api(path) {
  return new Promise((resolve) => {
    const req = https.get(
      {
        hostname: 'api.github.com',
        path,
        headers: {
          Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'tsukiro-verify',
          ...(TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}),
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let body;
          try { body = JSON.parse(text); } catch { body = text; }
          resolve({ status: res.statusCode, body });
        });
      },
    );
    req.on('error', (e) => resolve({ status: 0, body: { message: e.message } }));
    req.setTimeout(20000, () => { req.destroy(); resolve({ status: 0, body: { message: 'timeout' } }); });
  });
}

const repo = await api(`/repos/${REPO}`);
if (repo.status !== 200) {
  console.log(`✗ 无法读取仓库 (HTTP ${repo.status}): ${repo.body?.message ?? ''}`);
  process.exit(1);
}
console.log(`仓库      : ${repo.body.full_name}`);
console.log(`可见性    : ${repo.body.private ? '私有' : '公开'}`);
console.log(`默认分支  : ${repo.body.default_branch}`);
console.log(`大小      : ${repo.body.size} KB`);

const commit = await api(`/repos/${REPO}/commits/${BRANCH}`);
if (commit.status === 200) {
  const c = commit.body;
  console.log(`\n最新提交  : ${c.sha.slice(0, 7)}  ${c.commit.message.split('\n')[0]}`);
  console.log(`作者      : ${c.commit.author.name} <${c.commit.author.email}>`);
  console.log(`时间      : ${c.commit.author.date}`);
  const files = c.files ?? [];
  console.log(`本次变更  : ${files.length} 个文件, +${files.reduce((s, f) => s + f.additions, 0)} / -${files.reduce((s, f) => s + f.deletions, 0)}`);
}

const tree = await api(`/repos/${REPO}/git/trees/${BRANCH}?recursive=1`);
if (tree.status === 200) {
  const entries = tree.body.tree ?? [];
  const blobs = entries.filter((e) => e.type === 'blob');
  console.log(`\n文件总数  : ${blobs.length}`);
  console.log(`截断      : ${tree.body.truncated ? '是（列表未完整）' : '否'}`);

  // 按顶层目录归类
  const byDir = new Map();
  for (const b of blobs) {
    const parts = b.path.split('/');
    const top = parts.length === 1 ? '(根目录)' : parts[0] + '/';
    byDir.set(top, (byDir.get(top) ?? 0) + 1);
  }
  console.log('\n按顶层归类:');
  for (const [dir, n] of [...byDir.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(n).padStart(3)}  ${dir}`);
  }

  // 关键文件抽查
  console.log('\n关键文件抽查:');
  const must = [
    'README.md',
    '.gitignore',
    '.gitattributes',
    'docs/README.md',
    'docs/15-status.md',
    'packages/plugin_core/pubspec.yaml',
    'packages/plugin_core/pubspec.lock',
    'packages/plugin_core/lib/src/permission/gatekeeper.dart',
    'packages/plugin_core/lib/src/packaging/package_inspector.dart',
    'plugins/time-plugin/manifest.json',
    'scripts/pack_plugin.mjs',
  ];
  const paths = new Set(blobs.map((b) => b.path));
  for (const m of must) {
    console.log(`  ${paths.has(m) ? '✓' : '✗'} ${m}`);
  }

  // 不该上传的东西
  console.log('\n不应上传的路径检查:');
  const forbidden = blobs.map((b) => b.path).filter((p) =>
    /^(\.dart|\.tmp|dist)\//.test(p) || p.includes('.dart_tool') || p.endsWith('.zip') || p.includes('pub-cache'),
  );
  if (forbidden.length === 0) {
    console.log('  ✓ 未发现缓存/产物/打包文件');
  } else {
    for (const f of forbidden.slice(0, 10)) console.log(`  ✗ ${f}`);
  }
}
