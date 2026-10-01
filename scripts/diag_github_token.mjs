#!/usr/bin/env node
/**
 * 诊断细粒度 GitHub PAT 的实际权限范围。
 *
 * 为什么需要这个脚本：
 *   `git push` 报 403 时，直接用 `GET /repos/{owner}/{repo}` 判断是**不可靠**的 ——
 *   公开仓库任何人都能读，该接口返回的 `permissions` 反映的是**已认证用户**的
 *   权限（仓库归你自己时永远是 admin=true），而不是 token 被授予的范围。
 *
 *   真正能区分的是 `GET /user/repos`：对细粒度 PAT，它只返回该 token 被显式
 *   授权访问的仓库。目标仓库不在列表里 → 就是没选上。
 *
 * 用法: node --use-system-ca scripts/diag_github_token.mjs [owner/repo]
 *       （token 从环境变量 GH_TOKEN 读，不从命令行传，避免进 shell 历史）
 */
import https from 'node:https';

const TOKEN = process.env.GH_TOKEN;
const TARGET = process.argv[2] ?? 'qiluo128/TsukiroChat';

if (!TOKEN) {
  console.error('缺少环境变量 GH_TOKEN');
  process.exit(2);
}

const TOKEN_KIND = TOKEN.startsWith('github_pat_')
  ? '细粒度 PAT（权限在网页上按仓库逐项配置）'
  : TOKEN.startsWith('ghp_')
    ? '经典 PAT（权限是账号级的 scope，如 repo）'
    : '未知类型';

function api(path) {
  return new Promise((resolve) => {
    const req = https.get(
      {
        hostname: 'api.github.com',
        path,
        headers: {
          Authorization: `Bearer ${TOKEN}`,
          Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'tsukiro-diag',
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let body;
          try { body = JSON.parse(text); } catch { body = text; }
          resolve({ status: res.statusCode, headers: res.headers, body });
        });
      },
    );
    req.on('error', (e) => resolve({ status: 0, headers: {}, body: { message: e.message } }));
    req.setTimeout(20000, () => {
      req.destroy();
      resolve({ status: 0, headers: {}, body: { message: 'timeout' } });
    });
  });
}

console.log(`token 类型: ${TOKEN_KIND}\n`);

// ① 身份
const me = await api('/user');
if (me.status !== 200) {
  console.log(`✗ token 无效或已过期 (HTTP ${me.status}): ${me.body?.message ?? ''}`);
  console.log('\n→ 去 https://github.com/settings/personal-access-tokens 重新生成。');
  process.exit(1);
}
console.log(`① 身份: ${me.body.login}`);

// ② 该 token 被授权访问的仓库列表（关键判定）
const repos = await api('/user/repos?per_page=100&sort=updated');
let accessible = null;
if (repos.status === 200 && Array.isArray(repos.body)) {
  accessible = repos.body.map((r) => r.full_name);
  console.log(`② 该 token 被授权访问 ${accessible.length} 个仓库`);
  const found = accessible.includes(TARGET);
  console.log(`   目标仓库 ${TARGET}: ${found ? '✓ 在列表内' : '✗ 不在列表内'}`);
  if (!found) {
    if (accessible.length > 0) {
      console.log(`   列表前几个: ${accessible.slice(0, 5).join(', ')}`);
    }
  }
} else {
  console.log(`② 无法列出仓库 (HTTP ${repos.status}): ${repos.body?.message ?? ''}`);
}

// ③ 仓库详情（仅供参考，注意它反映的是用户权限）
const repo = await api(`/repos/${TARGET}`);
if (repo.status === 200) {
  const p = repo.body.permissions ?? {};
  console.log(`③ 仓库可见: private=${repo.body.private}, default_branch=${repo.body.default_branch}`);
  console.log(`   （注意：permissions 反映的是"用户"对仓库的权限，不能代表 token 范围）`);
  console.log(`   admin=${!!p.admin} push=${!!p.push} pull=${!!p.pull}`);
} else {
  console.log(`③ 仓库不可见 (HTTP ${repo.status}): ${repo.body?.message ?? ''}`);
}

// 结论
console.log('\n结论：');
if (accessible && !accessible.includes(TARGET)) {
  console.log('  ✗ token 没有被授权访问这个仓库 —— 这就是 push 403 的原因。');
  console.log('    修法：打开 https://github.com/settings/personal-access-tokens');
  console.log('          编辑该 token → Repository access 选 "Only select repositories"');
  console.log(`          → 勾上 ${TARGET}`);
  console.log('          → Repository permissions → Contents 设为 "Read and write"');
  console.log('          → 保存后重试推送（token 值不变，无需换新）');
} else if (accessible && accessible.includes(TARGET)) {
  console.log('  ? token 能看到该仓库但仍被拒。请检查 Contents 权限是否为 Read-only。');
  console.log('    修法：同一页面 → Repository permissions → Contents → Read and write');
} else {
  console.log('  无法自动判定，请把上面的完整输出发我。');
}
