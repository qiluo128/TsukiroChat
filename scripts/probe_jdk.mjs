#!/usr/bin/env node
/**
 * JDK 源探测。
 *
 * 为什么单独做：Adoptium 官方 API 在本机 TLS 校验失败
 * （UNABLE_TO_VERIFY_LEAF_SIGNATURE，同一套中间人证书问题），
 * 而各镜像站的目录结构不一致，得先看清有什么文件再下。
 *
 * 用法: node scripts/probe_jdk.mjs
 */
import https from 'node:https';

function get(url, { maxBytes = 0, timeoutMs = 15000 } = {}) {
  return new Promise((resolve) => {
    const started = Date.now();
    let received = 0;
    let settled = false;

    const finish = (status, body) => {
      if (settled) return;
      settled = true;
      resolve({
        status,
        body,
        bytes: received,
        mbps: received / 1048576 / Math.max((Date.now() - started) / 1000, 0.001),
      });
    };

    let req;
    try {
      req = https.get(url, { headers: { 'User-Agent': 'tsukiro-probe' } }, (res) => {
        if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
          res.resume();
          settled = true;
          const next = new URL(res.headers.location, url).toString();
          get(next, { maxBytes, timeoutMs }).then((r) => resolve({ ...r, redirectedTo: next }));
          return;
        }
        if (res.statusCode !== 200) {
          res.resume();
          return finish(`HTTP ${res.statusCode}`, null);
        }
        const chunks = [];
        res.on('data', (c) => {
          received += c.length;
          if (body_wanted) chunks.push(c);
          if (maxBytes && received >= maxBytes) {
            req.destroy();
            finish('ok', Buffer.concat(chunks).toString('utf8'));
          }
        });
        res.on('end', () => finish(received > 0 ? 'ok(200)' : 'empty', Buffer.concat(chunks).toString('utf8')));
      });
    } catch (e) {
      return finish(`ERR ${e.message}`, null);
    }

    const body_wanted = maxBytes === 0;

    req.on('error', (e) => finish(`ERR ${e.code ?? e.message}`, null));
    req.setTimeout(timeoutMs, () => {
      req.destroy();
      finish('timeout', null);
    });
  });
}

/** 从 HTML 目录列表里抽出 .zip 文件名 */
function zipNames(html) {
  if (!html) return [];
  const out = new Set();
  for (const m of html.matchAll(/href="([^"]+\.zip)"/gi)) {
    out.add(decodeURIComponent(m[1].split('/').pop()));
  }
  return [...out];
}

console.log('=== JDK 17 候选源 ===\n');

// ① 清华 Adoptium 目录
const tuna = 'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/windows/';
const t = await get(tuna);
console.log(`① 清华 Adoptium   ${t.status}  ${t.body?.length ?? 0} 字节`);
const tunaZips = zipNames(t.body);
if (tunaZips.length) {
  console.log(`   找到 ${tunaZips.length} 个 zip，最新几个：`);
  for (const z of tunaZips.slice(-3)) console.log(`     · ${z}`);
} else {
  console.log('   （没解析到 zip，可能目录结构不同）');
}

// ② 中科大 Adoptium
const ustc = 'https://mirrors.ustc.edu.cn/adoptium/17/jdk/x64/windows/';
const u = await get(ustc);
console.log(`\n② 中科大 Adoptium  ${u.status}`);
const ustcZips = zipNames(u.body);
if (ustcZips.length) for (const z of ustcZips.slice(-3)) console.log(`     · ${z}`);

// ③ 华为云 OpenJDK
const hw = 'https://mirrors.huaweicloud.com/openjdk/17.0.2/';
const h = await get(hw);
console.log(`\n③ 华为云 OpenJDK  ${h.status}`);
const hwZips = zipNames(h.body);
if (hwZips.length) for (const z of hwZips.slice(-5)) console.log(`     · ${z}`);

// ④ Microsoft JDK（aka.ms 会 302）
const ms = 'https://aka.ms/download-jdk/microsoft-jdk-17.0.13-windows-x64.zip';
const m = await get(ms, { maxBytes: 4 * 1024 * 1024 });
console.log(`\n④ Microsoft JDK 17  ${m.status}  ${(m.bytes / 1048576).toFixed(1)}MB  ${m.mbps.toFixed(2)} MB/s`);
if (m.redirectedTo) console.log(`   重定向到: ${m.redirectedTo}`);

// ⑤ 对选中的清华文件做一次限速测速
if (tunaZips.length) {
  const target = tunaZips[tunaZips.length - 1];
  const url = tuna + target;
  console.log(`\n⑤ 测速 ${target}`);
  const s = await get(url, { maxBytes: 6 * 1024 * 1024 });
  console.log(`   ${s.status}  ${(s.bytes / 1048576).toFixed(1)}MB  ${s.mbps.toFixed(2)} MB/s`);
}
