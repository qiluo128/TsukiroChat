#!/usr/bin/env node
/**
 * 下载 Flutter / JDK 17 / Android cmdline-tools 到 `.tmp/`。
 *
 * 只下载，不解压 —— 解压要写 C:\dev\（工作区外），需要单独提权，
 * 分两步的好处是下载失败不用重来。
 *
 * 源的选择来自 `scripts/bench_toolchain.mjs` 的实测：
 *   flutter   storage.flutter-io.cn   6.40 MB/s   （官方 0.14 MB/s，差 45 倍）
 *   jdk17     清华 Adoptium           6.87 MB/s   （Adoptium 官方 API TLS 不通）
 *   android   dl.google.com           4.63 MB/s
 *
 * 用法:
 *   node scripts/fetch_toolchain.mjs            # 下全部
 *   node scripts/fetch_toolchain.mjs flutter    # 只下某个
 *   node scripts/fetch_toolchain.mjs --check    # 只解析版本，不下载
 */
import https from 'node:https';
import { createWriteStream } from 'node:fs';
import { mkdir, stat, rename, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';

const TMP = path.resolve('.tmp');
const CHECK_ONLY = process.argv.includes('--check');
const only = process.argv.slice(2).filter((a) => !a.startsWith('--'));

const FLUTTER_BASE = 'https://storage.flutter-io.cn/flutter_infra_release/releases';
const JDK_URL = 'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/windows/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip';
const ANDROID_URL = 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip';

function get(url, { redirects = 6 } = {}) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'tsukiro-fetch' } }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        if (redirects <= 0) return reject(new Error('重定向过多'));
        res.resume();
        return resolve(get(new URL(res.headers.location, url).toString(), { redirects: redirects - 1 }));
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

/** 流式下载 + 边下边算 sha256。支持断点：已存在且大小吻合就跳过。 */
async function download(name, url, dest, expectedSha256) {
  const existing = await stat(dest).catch(() => null);
  if (existing && existing.size > 1024 * 1024) {
    const hash = createHash('sha256').update(await readFile(dest)).digest('hex');
    if (!expectedSha256 || hash === expectedSha256) {
      console.log(`  [跳过] ${name} 已存在 (${(existing.size / 1048576).toFixed(1)} MB)`);
      return { path: dest, bytes: existing.size, sha256: hash, skipped: true };
    }
    console.log(`  [重下] ${name} sha256 不符`);
  }

  const res = await get(url);
  const total = Number(res.headers['content-length'] || 0);
  const hash = createHash('sha256');
  let got = 0;
  let lastPct = -1;

  const part = `${dest}.part`;
  const out = createWriteStream(part);
  for await (const chunk of res) {
    hash.update(chunk);
    got += chunk.length;
    if (!out.write(chunk)) await new Promise((r) => out.once('drain', r));
    if (total) {
      const pct = Math.floor((got / total) * 100);
      if (pct !== lastPct && pct % 10 === 0) {
        lastPct = pct;
        process.stdout.write(`\r  ${name}  ${pct}%  ${(got / 1048576).toFixed(1)} / ${(total / 1048576).toFixed(1)} MB`);
      }
    }
  }
  await new Promise((r) => out.end(r));
  process.stdout.write('\r' + ' '.repeat(72) + '\r');

  const sha = hash.digest('hex');
  if (expectedSha256 && sha !== expectedSha256) {
    throw new Error(`${name} sha256 不符\n  期望 ${expectedSha256}\n  实际 ${sha}`);
  }
  await rename(part, dest);
  return { path: dest, bytes: got, sha256: sha, skipped: false };
}

async function main() {
  await mkdir(TMP, { recursive: true });

  // ── 解析 Flutter 最新 stable ──
  console.log('== 解析 Flutter stable ==');
  const releases = JSON.parse(await getText(`${FLUTTER_BASE}/releases_windows.json`));
  const stableHash = releases.current_release?.stable;
  const stable = releases.releases.find(
    (r) => r.hash === stableHash && r.channel === 'stable' && r.archive.endsWith('.zip'),
  );
  if (!stable) throw new Error('解析不出当前 stable 版本');

  const flutterVersion = stable.version;
  const flutterUrl = `${FLUTTER_BASE}/${stable.archive}`;
  console.log(`   版本 : ${flutterVersion}`);
  console.log(`   日期 : ${stable.release_date?.slice(0, 10)}`);
  console.log(`   sha256: ${stable.sha256.slice(0, 16)}…`);
  console.log(`   dart : ${stable.dart_sdk_version ?? '(见 flutter --version)'}`);

  if (CHECK_ONLY) {
    console.log('\n--check 模式，不下载。');
    console.log(`\nflutter : ${flutterUrl}`);
    console.log(`jdk17   : ${JDK_URL}`);
    console.log(`android : ${ANDROID_URL}`);
    return;
  }

  const plan = [
    ['flutter', flutterUrl, path.join(TMP, `flutter_${flutterVersion}-stable.zip`), stable.sha256],
    ['jdk17', JDK_URL, path.join(TMP, 'OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip'), null],
    ['android-cmdline-tools', ANDROID_URL, path.join(TMP, 'commandlinetools-win.zip'), null],
  ];

  const results = [];
  for (const [name, url, dest, sha] of plan) {
    if (only.length && !only.includes(name)) continue;
    console.log(`\n== 下载 ${name} ==`);
    console.log(`   ${url}`);
    try {
      const r = await download(name, url, dest, sha);
      console.log(`   完成: ${(r.bytes / 1048576).toFixed(1)} MB`);
      if (!r.skipped) console.log(`   sha256: ${r.sha256}`);
      results.push({ name, ...r, ok: true });
    } catch (e) {
      console.log(`   ✗ 失败: ${e.message}`);
      results.push({ name, ok: false, error: e.message });
    }
  }

  console.log('\n=== 汇总 ===');
  for (const r of results) {
    console.log(`  ${r.ok ? '✓' : '✗'} ${r.name.padEnd(24)} ${r.ok ? `${(r.bytes / 1048576).toFixed(1)} MB` : r.error}`);
  }
  console.log('\n下一步：解压到 C:\\dev\\（需要提权）');
  console.log('  pwsh -File scripts\\install_toolchain.ps1');
}

main().catch((e) => {
  console.error('\n失败:', e.message);
  process.exit(1);
});
