#!/usr/bin/env node
/**
 * 内容写权限探针。
 *
 * 目的：`git push` 403 时，判断到底是
 *   (a) token 的 Contents 权限是 Read-only  —— 需要改 token
 *   (b) token 能写，问题在 git 侧           —— 需要查别处
 *
 * 做法：向仓库创建一个 **dangling blob**（`POST /git/blobs`）。
 *   - 不创建引用、不出现在任何分支、UI 上看不见，GitHub 会自行回收
 *   - 这是区分 (a)/(b) 唯一可靠的方式：GET 类接口无法反映写权限
 *
 * 用法: node --use-system-ca scripts/probe_write.mjs <owner/repo>
 */
import https from 'node:https';

const TOKEN = process.env.GH_TOKEN;
const REPO = process.argv[2];

if (!TOKEN) { console.error('缺少 GH_TOKEN'); process.exit(2); }
if (!REPO) { console.error('用法: node --use-system-ca scripts/probe_write.mjs <owner/repo>'); process.exit(2); }

function request(method, path, payload) {
  return new Promise((resolve) => {
    const body = payload ? JSON.stringify(payload) : null;
    const req = https.request(
      {
        hostname: 'api.github.com',
        path,
        method,
        headers: {
          Authorization: `Bearer ${TOKEN}`,
          Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'tsukiro-probe',
          ...(body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {}),
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let parsed;
          try { parsed = JSON.parse(text); } catch { parsed = text; }
          resolve({ status: res.statusCode, body: parsed });
        });
      },
    );
    req.on('error', (e) => resolve({ status: 0, body: { message: e.message } }));
    req.setTimeout(20000, () => { req.destroy(); resolve({ status: 0, body: { message: 'timeout' } }); });
    if (body) req.write(body);
    req.end();
  });
}

console.log(`探测 ${REPO} 的写权限（创建一个 dangling blob，无副作用）…\n`);

const res = await request('POST', `/repos/${REPO}/git/blobs`, {
  content: 'tsukiro write probe — 可安全忽略，无引用、会被 GitHub 回收',
  encoding: 'utf-8',
});

if (res.status === 201) {
  console.log('✓ 写权限正常（HTTP 201）');
  console.log(`  blob sha: ${res.body.sha}`);
  console.log('\n结论：token 能写仓库 → 403 的原因不在 token。');
  console.log('  接下来应排查 git 侧：代理、凭据助手缓存、URL 改写等。');
} else if (res.status === 403) {
  console.log(`✗ 写权限被拒（HTTP 403）: ${res.body?.message ?? ''}`);
  console.log('\n结论：token 的 Contents 权限是 Read-only。');
  console.log('  修法（token 值不变，不用重新生成）：');
  console.log('    1. 打开 https://github.com/settings/personal-access-tokens');
  console.log('    2. 点开这个 token → Repository permissions');
  console.log('    3. 把 Contents 从 "Read-only" 改成 "Read and write"');
  console.log('    4. 保存，然后直接重试推送');
} else if (res.status === 404) {
  console.log(`✗ 仓库不可见（HTTP 404）: ${res.body?.message ?? ''}`);
  console.log('\n结论：token 没有被授权访问这个仓库。');
  console.log('  修法：编辑 token → Repository access → 勾上本仓库。');
} else {
  console.log(`? 未预期的响应 HTTP ${res.status}: ${res.body?.message ?? JSON.stringify(res.body)}`);
}
