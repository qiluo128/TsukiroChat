#!/usr/bin/env node
/**
 * 测速：对若干候选源各拉一小段，比较吞吐，挑最快的。
 *
 * 用法: node scripts/bench_mirrors.mjs [秒数]
 */
import https from 'node:https';

const SECONDS = Number(process.argv[2] ?? 8);
const BYTES = 8 * 1024 * 1024; // 每次最多拉 8MB

const PATH = '/dart-archive/channels/stable/release/latest/sdk/dartsdk-windows-x64-release.zip';

const MIRRORS = [
  ['google-storage (官方)', `https://storage.googleapis.com${PATH}`],
  ['flutter-io.cn (国内官方镜像)', `https://storage.flutter-io.cn${PATH}`],
  ['tuna 清华', `https://mirrors.tuna.tsinghua.edu.cn/dart-archive/channels/stable/release/latest/sdk/dartsdk-windows-x64-release.zip`],
  ['ustc 中科大', `https://mirrors.ustc.edu.cn/dart-archive/channels/stable/release/latest/sdk/dartsdk-windows-x64-release.zip`],
  ['sjtug 上交', `https://mirror.sjtu.edu.cn/dart-archive/channels/stable/release/latest/sdk/dartsdk-windows-x64-release.zip`],
];

function measure(name, url) {
  return new Promise((resolve) => {
    const started = Date.now();
    let received = 0;
    let settled = false;

    const finish = (status) => {
      if (settled) return;
      settled = true;
      const secs = (Date.now() - started) / 1000;
      resolve({ name, url, status, bytes: received, secs, mbps: received / 1048576 / secs });
    };

    const req = https.get(url, { headers: { Range: `bytes=0-${BYTES - 1}` } }, (res) => {
      if (res.statusCode !== 200 && res.statusCode !== 206) {
        res.resume();
        return finish(`HTTP ${res.statusCode}`);
      }
      res.on('data', (chunk) => {
        received += chunk.length;
        if (Date.now() - started > SECONDS * 1000) {
          req.destroy();
          finish('ok');
        }
      });
      res.on('end', () => finish('ok(eof)'));
    });

    req.on('error', (e) => finish(`ERR ${e.code ?? e.message}`));
    req.setTimeout(SECONDS * 1000 + 5000, () => {
      req.destroy();
      finish('timeout');
    });
  });
}

const results = await Promise.all(MIRRORS.map(([name, url]) => measure(name, url)));

results.sort((a, b) => b.mbps - a.mbps);

console.log(`\n每个源最多拉取 ${SECONDS}s / ${BYTES / 1048576}MB\n`);
console.log('  #  吞吐        已拉取     状态        源');
console.log('  ' + '─'.repeat(72));
results.forEach((r, i) => {
  const mb = (r.bytes / 1048576).toFixed(1);
  const rate = r.mbps >= 0.05 ? `${r.mbps.toFixed(2)} MB/s` : '—';
  console.log(
    `  ${String(i + 1).padEnd(2)} ${rate.padEnd(11)} ${(mb + ' MB').padEnd(10)} ` +
    `${r.status.padEnd(11)} ${r.name}`,
  );
});

const best = results.find((r) => r.mbps > 0.05);
if (best) {
  console.log(`\n最快: ${best.name}\n  ${best.url}`);
  console.log(`\n预计 ${(209.7 / best.mbps / 60).toFixed(1)} 分钟下载完 209.7MB`);
} else {
  console.log('\n所有源都不可用，请检查网络。');
}
