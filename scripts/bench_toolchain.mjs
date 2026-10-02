#!/usr/bin/env node
/**
 * 工具链源探测 —— 在下载 1GB+ 之前先确认源可用且够快。
 *
 * 为什么必须做这一步：Dart SDK 那次实测官方源 0.12 MB/s（要 4 小时），
 * 国内镜像 3.7 MB/s（1 分钟）—— 差 30 倍。不先测就下，可能白等半天。
 *
 * 用法: node scripts/bench_toolchain.mjs [每个源秒数]
 */
import https from 'node:https';

const SECONDS = Number(process.argv[2] ?? 6);
const MAX_BYTES = 6 * 1024 * 1024;

/** 候选目标。每个给一组镜像，探测时全部测。 */
const TARGETS = [
  {
    name: 'flutter',
    candidates: [
      ['flutter-io.cn (国内官方镜像)', 'https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.35.4-stable.zip'],
      ['google 官方', 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.35.4-stable.zip'],
    ],
  },
  {
    name: 'jdk17',
    candidates: [
      ['Adoptium API (官方)', 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse'],
      ['Adoptium 清华镜像', 'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/windows/'],
      ['Adoptium 中科大镜像', 'https://mirrors.ustc.edu.cn/adoptium/17/jdk/x64/windows/'],
    ],
  },
  {
    name: 'android-cmdline-tools',
    candidates: [
      ['dl.google.com (官方)', 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip'],
      ['flutter-io.cn 镜像', 'https://storage.flutter-io.cn/android/repository/commandlinetools-win-11076708_latest.zip'],
    ],
  },
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
      resolve({ name, url, status, bytes: received, mbps: received / 1048576 / secs });
    };

    let req;
    try {
      req = https.get(url, { headers: { Range: `bytes=0-${MAX_BYTES - 1}`, 'User-Agent': 'tsukiro-bench' } }, (res) => {
        // 跟随重定向（Adoptium API 会 302 到 GitHub）
        if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
          res.resume();
          probe(name, new URL(res.headers.location, url).toString()).then(resolve);
          settled = true;
          return;
        }
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
        res.on('end', () => finish(received > 0 ? 'ok(eof)' : 'empty'));
      });
    } catch (e) {
      return finish(`ERR ${e.message}`);
    }

    req.on('error', (e) => finish(`ERR ${e.code ?? e.message}`));
    req.setTimeout(SECONDS * 1000 + 8000, () => {
      req.destroy();
      finish('timeout');
    });
  });
}

console.log(`每个源最多拉 ${SECONDS}s / ${MAX_BYTES / 1048576}MB\n`);

const all = [];
for (const target of TARGETS) {
  console.log(`── ${target.name} ──`);
  const results = await Promise.all(target.candidates.map(([n, u]) => probe(n, u)));
  results.sort((a, b) => b.mbps - a.mbps);
  for (const r of results) {
    const rate = r.mbps >= 0.02 ? `${r.mbps.toFixed(2)} MB/s` : '—';
    console.log(`   ${rate.padEnd(10)} ${(r.bytes / 1048576).toFixed(1).padStart(5)} MB  ${r.status.padEnd(10)} ${r.name}`);
  }
  const best = results.find((r) => r.mbps > 0.02);
  console.log(`   → 选: ${best ? best.name : '（无可用源）'}\n`);
  all.push({ target: target.name, best });
}

console.log('=== 汇总 ===');
for (const { target, best } of all) {
  console.log(`  ${target.padEnd(24)} ${best ? `${best.mbps.toFixed(2)} MB/s  ${best.url}` : '无可用源'}`);
}
