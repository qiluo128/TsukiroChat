#!/usr/bin/env node
/**
 * 构建产物体检。
 *
 * ## 为什么必须有这个脚本
 *
 * 踩过一次：Flutter 模板只在 `debug/AndroidManifest.xml` 里有 INTERNET 权限，
 * `main/` 里没有。结果：
 *   - `flutter analyze` 干净
 *   - 单元测试全绿
 *   - debug 包能联网
 *   - **release 包装到手机上，所有网络请求瞬间失败**（"测试连接"直接报无网络）
 *
 * 这类问题**只有看最终产物才能发现**。源码怎么写都不算数 ——
 * 真正生效的是 Gradle 合并之后那一份。
 *
 * ## 一个反直觉的点
 *
 * AGP 对 release 包会**混淆资源文件名**：`res/xml/network_security_config.xml`
 * 在 APK 里变成了 `res/XX.xml`。所以**不能按路径去 APK 里找**配置文件，
 * 会得出"文件没打进去"的错误结论。
 *
 * 正确做法是查两处：
 *   1. `build/app/intermediates/merged_manifest/release/.../AndroidManifest.xml`
 *      —— Gradle 合并后的明文清单，这是编译进包的那一份
 *   2. `aapt2 dump permissions <apk>` —— 从最终二进制里反查权限
 *
 * 用法: node scripts/verify_apk.mjs
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync, readdirSync, mkdirSync } from 'node:fs';
import path from 'node:path';

const APK = 'packages/host_app/build/app/outputs/flutter-apk/app-release.apk';
const MERGED_CANDIDATES = [
  'packages/host_app/build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml',
  'packages/host_app/build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml',
];
const NSC_SOURCE = 'packages/host_app/android/app/src/main/res/xml/network_security_config.xml';
const MAIN_MANIFEST = 'packages/host_app/android/app/src/main/AndroidManifest.xml';

const problems = [];
const notes = [];

function findAapt2() {
  const root = 'C:\\dev\\android-sdk\\build-tools';
  if (!existsSync(root)) return null;
  const versions = readdirSync(root).sort((a, b) =>
    b.localeCompare(a, undefined, { numeric: true }),
  );
  for (const v of versions) {
    const p = path.join(root, v, 'aapt2.exe');
    if (existsSync(p)) return p;
  }
  return null;
}

console.log('构建产物体检\n');

// ═══════════ ① 合并后的清单（最关键） ═══════════
console.log('=== ① 合并后的 release 清单 ===');
const mergedPath = MERGED_CANDIDATES.find((p) => existsSync(p));
if (!mergedPath) {
  console.log('  ✗ 找不到合并后的清单');
  console.log('    先构建：cd packages/host_app && flutter build apk --release');
  problems.push('找不到合并清单，无法验证');
} else {
  console.log(`  ${mergedPath}`);
  const xml = readFileSync(mergedPath, 'utf8');

  const hasInternet = /android\.permission\.INTERNET/.test(xml);
  const hasNetState = /android\.permission\.ACCESS_NETWORK_STATE/.test(xml);
  const hasNsc = /android:networkSecurityConfig="@xml\/network_security_config"/.test(xml);

  for (const m of xml.matchAll(/<uses-permission[^>]*android:name="([^"]+)"/g)) {
    console.log(`    uses-permission: ${m[1]}`);
  }

  if (hasInternet) {
    console.log('  ✓ INTERNET');
  } else {
    console.log('  ✗ **缺 INTERNET** —— release 包所有网络请求都会失败');
    problems.push('合并清单里没有 android.permission.INTERNET');
  }
  if (!hasNetState) notes.push('没有 ACCESS_NETWORK_STATE（非必需，但错误提示会不够准）');
  if (hasNsc) {
    console.log('  ✓ networkSecurityConfig 已引用');
  } else {
    console.log('  ✗ 没有引用 networkSecurityConfig');
    problems.push('合并清单没有引用 networkSecurityConfig，Android 9+ 会拦掉明文 HTTP');
  }
}

// ═══════════ ② 明文流量策略 ═══════════
console.log('\n=== ② 明文流量策略 ===');
if (!existsSync(NSC_SOURCE)) {
  console.log(`  ✗ 找不到 ${NSC_SOURCE}`);
  problems.push('network_security_config.xml 不存在');
} else {
  const nsc = readFileSync(NSC_SOURCE, 'utf8');
  const baseAllows = /<base-config[^>]*cleartextTrafficPermitted="true"/.test(nsc);
  if (baseAllows) {
    console.log('  ✓ base-config 允许明文（用户自填的国内中转站常是 http）');
  } else {
    console.log('  ✗ base-config 没有允许明文 —— 明文 HTTP 站会连不上');
    problems.push('network_security_config 没有允许明文流量');
  }
  const trustsSystem = /<certificates\s+src="system"\s*\/>/.test(nsc);
  console.log(
    trustsSystem
      ? '  ✓ 仍校验系统 CA（不是"关掉 TLS 校验"，只是额外允许明文）'
      : '  ! 没看到 system 信任锚',
  );
}

// ═══════════ ③ 从最终二进制反查权限 ═══════════
console.log('\n=== ③ APK 二进制反查（aapt2） ===');
const aapt2 = findAapt2();
if (!existsSync(APK)) {
  console.log(`  ✗ 找不到 ${APK}`);
  problems.push('APK 不存在');
} else if (!aapt2) {
  notes.push('找不到 aapt2，跳过二进制反查');
} else {
  const size = statSync(APK).size / 1048576;
  console.log(`  APK: ${size.toFixed(1)} MB`);

  let permOut = '';
  try {
    permOut = execFileSync(aapt2, ['dump', 'permissions', APK], { encoding: 'utf8' });
  } catch (e) {
    permOut = `${e.stdout ?? ''}${e.stderr ?? ''}`;
  }

  if (/android\.permission\.INTERNET/.test(permOut)) {
    console.log('  ✓ 二进制清单里确实有 INTERNET');
  } else {
    console.log('  ✗ 二进制清单里没有 INTERNET —— 与合并清单不一致，可能没重新构建');
    problems.push('APK 二进制清单缺 INTERNET（合并清单有，说明 APK 是旧的）');
  }

  let xmlOut = '';
  try {
    xmlOut = execFileSync(
      aapt2,
      ['dump', 'xmltree', '--file', 'AndroidManifest.xml', APK],
      { encoding: 'utf8' },
    );
  } catch (e) {
    xmlOut = `${e.stdout ?? ''}${e.stderr ?? ''}`;
  }
  if (/networkSecurityConfig/.test(xmlOut)) {
    console.log('  ✓ 二进制清单引用了 networkSecurityConfig');
    console.log('    （资源名被 AGP 混淆成 res/XX.xml 是正常的，不能按路径找）');
  } else {
    console.log('  ✗ 二进制清单没有 networkSecurityConfig');
    problems.push('APK 二进制清单没有 networkSecurityConfig');
  }
}

// ═══════════ ④ 源码清单（防止以后有人把权限挪走） ═══════════
console.log('\n=== ④ 源码清单 ===');
if (existsSync(MAIN_MANIFEST)) {
  const src = readFileSync(MAIN_MANIFEST, 'utf8');
  if (/android\.permission\.INTERNET/.test(src)) {
    console.log('  ✓ main/AndroidManifest.xml 里有 INTERNET');
  } else {
    console.log('  ✗ main/AndroidManifest.xml 里没有 INTERNET');
    console.log('    （只在 debug 里加是不够的 —— release 包不会合并过去）');
    problems.push('源码 main 清单缺 INTERNET');
  }
} else {
  notes.push('找不到 main/AndroidManifest.xml');
}

// ═══════════ ⑤ 打进包的敏感资源 ═══════════
console.log('\n=== ⑤ 打包进来的资源 ===');
try {
  const listOut = execFileSync(
    'powershell',
    [
      '-NoProfile', '-Command',
      `Add-Type -AssemblyName System.IO.Compression.FileSystem; ` +
      `$z=[System.IO.Compression.ZipFile]::OpenRead('${path.resolve(APK)}'); ` +
      `$z.Entries | Where-Object { $_.FullName -match 'dev-config' } | ForEach-Object { $_.FullName }; ` +
      `$z.Dispose()`,
    ],
    { encoding: 'utf8' },
  );
  const lines = listOut.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  for (const l of lines) console.log(`  ${l}`);
  if (lines.some((l) => /dev-config\.json$/.test(l))) {
    notes.push('APK 里有 assets/dev-config.json（含真实 API Key）—— 自用没问题，别发给别人');
  }
} catch {
  notes.push('没能列出 APK 资源');
}

// ═══════════ 结论 ═══════════
console.log('\n=== 结论 ===');
for (const n of notes) console.log(`  ! ${n}`);
if (problems.length) {
  console.log('');
  for (const p of problems) console.log(`  ✗ ${p}`);
  console.log(`\n发现 ${problems.length} 个会导致真机联网失败的问题。`);
  process.exit(2);
}
console.log('  ✓ 清单与网络配置都正确，可以装机。');
