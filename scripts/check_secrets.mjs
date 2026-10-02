#!/usr/bin/env node
/**
 * 检查公开仓库里是否泄露了凭据。
 *
 * 为什么要专门做这件事：`.gitignore` 只能防住"以后不再提交"，
 * **防不住"已经提交过"**。一旦某个含密钥的文件进过历史，删掉它并不能移除 ——
 * 只能轮换密钥。所以每次改完凭据相关的配置，都该跑一次这个检查。
 *
 * 用法: node --use-system-ca scripts/check_secrets.mjs <owner/repo>
 */
import https from 'node:https';

const TOKEN = process.env.GH_TOKEN;
const REPO = process.argv[2] ?? 'qiluo128/TsukiroChat';

/** 凭据形态的特征串。用宽松匹配，宁可误报不可漏报。 */
const PATTERNS = [
  { name: '老式 GitHub PAT', re: /ghp_[A-Za-z0-9]{20,}/ },
  { name: '细粒度 GitHub PAT', re: /github_pat_[A-Za-z0-9_]{20,}/ },
  { name: 'OpenAI 风格 key', re: /sk-[A-Za-z0-9]{24,}/ },
  { name: 'AWS Access Key', re: /AKIA[0-9A-Z]{16}/ },
  { name: '私钥', re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: 'Slack token', re: /xox[baprs]-[A-Za-z0-9-]{10,}/ },
];

/** 允许出现的占位符（文档与模板里的示例）。 */
const ALLOWLIST = [
  /sk-\.\.\./,
  /sk-<[^>]*>/,
  /"<在这里填[^"]*>"/,
  /sk-invalidkey/,
  /sk-xxxx/i,
  /<[a-z_-]*(key|token)[a-z_-]*>/i,
];

/**
 * 自身文件名。
 *
 * **必须跳过自己**：这个文件里有各种凭据的**正则模式**。如果把真实凭据字面量
 * 写进 allowlist 来压误报，那就是自相矛盾 —— 扫描器本身成了泄露源。
 * （这不是假设：第一版就是这么写的，被 GitHub Push Protection 当场拦下。）
 */
const SELF = 'scripts/check_secrets.mjs';

function api(path) {
  return new Promise((resolve) => {
    const req = https.get(
      {
        hostname: 'api.github.com',
        path,
        headers: {
          Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'tsukiro-secret-scan',
          ...(TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}),
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          let body;
          try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { body = null; }
          resolve({ status: res.statusCode, body });
        });
      },
    );
    req.on('error', (e) => resolve({ status: 0, body: { message: e.message } }));
    req.setTimeout(30000, () => { req.destroy(); resolve({ status: 0, body: { message: 'timeout' } }); });
  });
}

/** 取文件原文（raw 不走 API 配额）。 */
function raw(path) {
  return new Promise((resolve) => {
    const req = https.get(
      {
        hostname: 'raw.githubusercontent.com',
        path: `/${REPO}/HEAD/${path}`,
        headers: { 'User-Agent': 'tsukiro-secret-scan' },
      },
      (res) => {
        if (res.statusCode !== 200) { res.resume(); return resolve(null); }
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      },
    );
    req.on('error', () => resolve(null));
    req.setTimeout(30000, () => { req.destroy(); resolve(null); });
  });
}

const tree = await api(`/repos/${REPO}/git/trees/HEAD?recursive=1`);
if (tree.status !== 200) {
  console.error(`无法读取仓库树 (HTTP ${tree.status}): ${tree.body?.message}`);
  process.exit(2);
}

const blobs = tree.body.tree.filter((e) => e.type === 'blob');
console.log(`扫描 ${REPO}：${blobs.length} 个文件\n`);

// ── ① 不该存在的路径 ──
const forbidden = blobs
  .map((b) => b.path)
  .filter((p) => /(^|\/)dev-config\.json$|(^|\/)\.env$|\.local\.json$|\.pem$|(^|\/)secrets?\//.test(p));

console.log('① 凭据类路径检查');
if (forbidden.length === 0) {
  console.log('   ✓ 没有 dev-config.json / .env / *.pem / secrets/ 类文件');
} else {
  for (const p of forbidden) console.log(`   ✗ ${p}`);
}

// ── ② 文件内容扫描（只扫文本类，且跳过体积大的）──
console.log('\n② 内容扫描');
const textish = blobs.filter((b) =>
  /\.(dart|json|md|yaml|yml|js|mjs|ts|ps1|sh|txt|html|svg|gitignore|gitattributes)$/.test(b.path) ||
  !b.path.includes('.'),
);

let findings = 0;
let scanned = 0;
for (const b of textish) {
  if (b.size > 512 * 1024) continue; // 大文件跳过，避免拖慢
  if (b.path === SELF) continue; // 自身跳过，见 SELF 的说明
  const content = await raw(b.path);
  if (content == null) continue;
  scanned++;

  for (const { name, re } of PATTERNS) {
    const m = content.match(new RegExp(re.source, 'g'));
    if (!m) continue;
    for (const hit of m) {
      // 占位符不算
      if (ALLOWLIST.some((a) => a.test(hit))) continue;
      findings++;
      console.log(`   ✗ ${b.path}  疑似 ${name}：${hit.slice(0, 12)}…`);
    }
  }
}

console.log(`   已扫描 ${scanned} 个文本文件`);
if (findings === 0) {
  console.log('   ✓ 未发现凭据');
}

console.log('\n结论：');
if (forbidden.length === 0 && findings === 0) {
  console.log('  ✓ 公开仓库中没有凭据。');
} else {
  console.log('  ✗ 发现可疑内容。注意：.gitignore 挡不住已经提交过的文件，');
  console.log('    必须**轮换密钥**（删文件不能从 git 历史里移除它）。');
  process.exit(1);
}
