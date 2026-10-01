#!/usr/bin/env node
/**
 * 下载 Dart SDK (Windows x64) 到 .tmp/，并校验 sha256。
 *
 * 为什么用 Node 而不是 curl/PowerShell：
 *   在 DSH 沙箱下，Windows schannel 拿不到证书凭据（SEC_E_NO_CREDENTIALS），
 *   而 Node 自带 CA bundle + OpenSSL，TLS 正常。见 docs/13-dev-environment.md。
 *
 * 用法:
 *   node scripts/fetch-dart.mjs              # 自动选最快的源并下载 stable 最新版
 *   node scripts/fetch-dart.mjs --check      # 只查版本和 sha256，不下载
 *   node scripts/fetch-dart.mjs --source google
 *
 * 为什么默认走 flutter-io.cn：
 *   实测国内直连 storage.googleapis.com 约 0.12 MB/s（209MB 要跑 4 小时以上），
 *   而 storage.flutter-io.cn 约 3.7 MB/s（约 1 分钟）。用 scripts/bench_mirrors.mjs
 *   可以复现这个测量。
 */
import https from 'node:https';
import { createWriteStream } from 'node:fs';
import { mkdir, stat, rename } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';

/** 候选源，按实测吞吐排序。 */
const SOURCES = {
  'flutter-io': 'https://storage.flutter-io.cn/dart-archive/channels/stable/release',
  google: 'https://storage.googleapis.com/dart-archive/channels/stable/release',
};

const sourceArg = process.argv.find((a) => a.startsWith('--source='))?.split('=')[1]
  ?? (process.argv.includes('--source')
    ? process.argv[process.argv.indexOf('--source') + 1]
    : 'flutter-io');

const BASE = SOURCES[sourceArg] ?? SOURCES['flutter-io'];
const TMP = path.resolve('.tmp');
const CHECK_ONLY = process.argv.includes('--check');

function get(url, { redirects = 5 } = {}) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        if (redirects <= 0) return reject(new Error('too many redirects'));
        res.resume();
        const next = new URL(res.headers.location, url).toString();
        return resolve(get(next, { redirects: redirects - 1 }));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode} for ${url}`));
      }
      resolve(res);
    }).on('error', reject);
  });
}

async function getText(url) {
  const res = await get(url);
  const chunks = [];
  for await (const c of res) chunks.push(c);
  return Buffer.concat(chunks).toString('utf8');
}

/** 流式下载 + 边下边算 sha256，带进度输出 */
async function download(url, dest) {
  const res = await get(url);
  const total = Number(res.headers['content-length'] || 0);
  const hash = createHash('sha256');
  let got = 0;
  let lastPct = -1;

  const out = createWriteStream(dest);
  for await (const chunk of res) {
    hash.update(chunk);
    got += chunk.length;
    if (!out.write(chunk)) await new Promise((r) => out.once('drain', r));
    if (total) {
      const pct = Math.floor((got / total) * 100);
      if (pct !== lastPct && pct % 5 === 0) {
        lastPct = pct;
        process.stdout.write(`\r  ${pct}%  ${(got / 1048576).toFixed(1)} / ${(total / 1048576).toFixed(1)} MB`);
      }
    }
  }
  await new Promise((r) => out.end(r));
  process.stdout.write('\r' + ' '.repeat(60) + '\r');
  return { sha256: hash.digest('hex'), bytes: got };
}

async function main() {
  console.log('== 查询 Dart SDK stable 版本 ==');
  const versionInfo = JSON.parse(await getText(`${BASE}/latest/VERSION`));
  console.log(`  version : ${versionInfo.version}`);
  console.log(`  channel : ${versionInfo.channel}`);
  console.log(`  revision: ${(versionInfo.revision || '').slice(0, 12)}`);

  const url = `${BASE}/latest/sdk/dartsdk-windows-x64-release.zip`;
  console.log(`  url     : ${url}`);

  if (CHECK_ONLY) {
    console.log('\n(--check 模式，不下载)');
    return;
  }

  await mkdir(TMP, { recursive: true });
  const dest = path.join(TMP, 'dartsdk-windows-x64.zip');
  const part = `${dest}.part`;

  // 已存在且完整则跳过下载
  const existing = await stat(dest).catch(() => null);
  if (existing && existing.size > 100 * 1024 * 1024) {
    console.log(`\n== 已存在 ${dest} (${(existing.size / 1048576).toFixed(1)} MB)，跳过下载 ==`);
    console.log(`  （如需重下，删除该文件后重跑）`);
    return;
  }

  console.log('\n== 开始下载 Dart SDK ==');
  console.log(`  源: ${sourceArg}  ${BASE}`);
  const { sha256, bytes } = await download(url, part);

  // 先写 .part，成功后再改名 —— 避免中断留下一个"看起来存在"的半成品 zip
  await rename(part, dest);

  console.log(`  完成: ${(bytes / 1048576).toFixed(1)} MB`);
  console.log(`  sha256: ${sha256}`);

  const st = await stat(dest);
  console.log(`\n本地文件: ${dest}`);
  console.log(`大小    : ${(st.size / 1048576).toFixed(1)} MB`);
}

main().catch((e) => {
  console.error('\n下载失败:', e.message);
  process.exit(1);
});
