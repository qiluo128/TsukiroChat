#!/usr/bin/env node
/**
 * TLS 连通性探测。
 *
 * 用途：DSH 沙箱下 Windows schannel 拿不到证书凭据，curl / Invoke-WebRequest 全部失败，
 * 而 Node 自带 CA bundle + OpenSSL 正常。check_env.ps1 用这个脚本判断当前环境
 * 该用哪条路下载。
 *
 * 用法: node scripts/tls_probe.mjs [url]
 * 输出: OK 200  或  FAIL <原因>   （退出码 0 / 1）
 */
import https from 'node:https';

const url = process.argv[2] ?? 'https://pub.dev';

const req = https.get(url, { timeout: 10000 }, (res) => {
  res.resume();
  console.log(`OK ${res.statusCode}`);
  process.exit(res.statusCode === 200 ? 0 : 1);
});

req.on('timeout', () => {
  req.destroy();
  console.log('FAIL timeout');
  process.exit(1);
});

req.on('error', (e) => {
  console.log(`FAIL ${e.code ?? e.message}`);
  process.exit(1);
});
