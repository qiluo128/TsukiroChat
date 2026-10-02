#!/usr/bin/env node
/**
 * Maven 仓库源探测。
 *
 * 为什么需要：`flutter doctor` 报 `maven.google.com` 超时。
 * 这个域名是国内做 Android 开发最常见的卡点 —— Gradle 解析 Android 依赖
 * 全靠它，不通的话构建会在下载阶段挂住（而且报错信息通常很难指向真正原因）。
 *
 * 探测目标：官方源 + 国内常见镜像，找出可用且够快的。
 *
 * 用法: node scripts/bench_maven.mjs [秒数]
 */
import https from 'node:https';

const SECONDS = Number(process.argv[2] ?? 5);
const MAX = 512 * 1024;

const CANDIDATES = [
  ['google 官方', 'https://maven.google.com/androidx/core/core/1.13.1/core-1.13.1.pom'],
  ['dl.google.com（同源别名）', 'https://dl.google.com/dl/android/maven2/androidx/core/core/1.13.1/core-1.13.1.pom'],
  ['阿里云 google 镜像', 'https://maven.aliyun.com/repository/google/androidx/core/core/1.13.1/core-1.13.1.pom'],
  ['阿里云 central 镜像', 'https://maven.aliyun.com/repository/central/org/jetbrains/kotlin/kotlin-stdlib/2.0.0/kotlin-stdlib-2.0.0.pom'],
  ['腾讯云 central 镜像', 'https://mirrors.cloud.tencent.com/nexus/repository/maven-public/org/jetbrains/kotlin/kotlin-stdlib/2.0.0/kotlin-stdlib-2.0.0.pom'],
  ['Maven Central 官方', 'https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/2.0.0/kotlin-stdlib-2.0.0.pom'],
];

function probe(name, url) {
  return new Promise((resolve) => {
    const started = Date.now();
    let received = 0;
    let settled = false;
    const finish = (status) => {
      if (settled) return;
      settled = true;
      const secs = Math.max((Date.now() - started) / 1000, 0.001);
      resolve({ name, status, bytes: received, ms: Date.now() - started, kbps: received / 1024 / secs });
    };

    let req;
    try {
      req = https.get(url, { headers: { 'User-Agent': 'tsukiro-bench', Range: `bytes=0-${MAX - 1}` } }, (res) => {
        if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
          res.resume();
          settled = true;
          probe(name, new URL(res.headers.location, url).toString()).then(resolve);
          return;
        }
        if (res.statusCode !== 200 && res.statusCode !== 206) {
          res.resume();
          return finish(`HTTP ${res.statusCode}`);
        }
        res.on('data', (c) => {
          received += c.length;
          if (Date.now() - started > SECONDS * 1000) { req.destroy(); finish('ok'); }
        });
        res.on('end', () => finish('ok(200)'));
      });
    } catch (e) { return finish(`ERR ${e.message}`); }

    req.on('error', (e) => finish(`ERR ${e.code ?? e.message}`));
    req.setTimeout(SECONDS * 1000 + 6000, () => { req.destroy(); finish('TIMEOUT'); });
  });
}

console.log(`Maven 源探测（每个最多 ${SECONDS}s）\n`);
const results = await Promise.all(CANDIDATES.map(([n, u]) => probe(n, u)));
for (const r of results) {
  const speed = r.kbps > 1 ? `${r.kbps.toFixed(0)} KB/s` : '—';
  const body = r.bytes > 0 ? `${(r.bytes / 1024).toFixed(1)} KB` : '';
  console.log(`  ${r.status.padEnd(12)} ${speed.padEnd(10)} ${body.padEnd(9)} ${r.name}`);
}

const usable = results.filter((r) => r.status.startsWith('ok') && r.bytes > 0);
console.log('\n可用源（按速度）:');
usable.sort((a, b) => b.kbps - a.kbps);
for (const r of usable) console.log(`  ${r.kbps.toFixed(0).padStart(6)} KB/s  ${r.name}`);

const google = results.find((r) => r.name === 'google 官方');
console.log('\n结论:');
if (google && google.status.startsWith('ok') && google.bytes > 0) {
  console.log('  google 官方可达，暂时不需要配镜像。');
} else {
  console.log(`  google 官方不可用（${google?.status}）→ **必须配 Gradle 镜像**，`);
  console.log('  否则 Android 构建会在解析依赖时挂住。');
  console.log('  用 scripts/setup_gradle_mirror.ps1 写入 init.gradle。');
}
