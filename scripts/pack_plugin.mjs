#!/usr/bin/env node
/**
 * 把插件目录打包成符合 Tsukiro Chat 规范的 zip。
 *
 * 用法:
 *   node scripts/pack_plugin.mjs plugins/time-plugin
 *   node scripts/pack_plugin.mjs plugins/time-plugin --out dist/
 *   node scripts/pack_plugin.mjs plugins/time-plugin --malicious-traversal   # 造恶意样本（仅测试用）
 *
 * 为什么自己写 zip 而不是用 archiver:
 *   1. 零依赖（archiver 需要 npm install，CI 上多一步）
 *   2. 需要精确控制条目路径 —— 测试 Zip Slip 防护时必须能造出 `../evil.txt` 条目，
 *      而正规 zip 库都会拒绝写这种路径。
 *
 * 规范见 docs/04-plugin-spec.md
 */
import { readFile, writeFile, readdir, stat, mkdir } from 'node:fs/promises';
import { createDeflateRaw } from 'node:zlib';
import { createHash } from 'node:crypto';
import path from 'node:path';

// ─────────────────────────── CRC32 ───────────────────────────
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// ─────────────────────────── deflate ─────────────────────────
function deflateRaw(buf) {
  return new Promise((resolve, reject) => {
    const d = createDeflateRaw({ level: 9 });
    const chunks = [];
    d.on('data', (c) => chunks.push(c));
    d.on('end', () => resolve(Buffer.concat(chunks)));
    d.on('error', reject);
    d.end(buf);
  });
}

// ─────────────────────────── zip 写入 ─────────────────────────
/** 把一个 { entryPath, data } 列表写成 zip Buffer */
async function buildZip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;

  for (const { entryPath, data } of entries) {
    const nameBuf = Buffer.from(entryPath, 'utf8');
    const crc = crc32(data);
    const comp = await deflateRaw(data);
    const method = 8; // deflate

    // 本地文件头
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);            // version needed
    local.writeUInt16LE(0x0800, 6);        // flags: UTF-8 名称
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0, 10);            // mod time
    local.writeUInt16LE(0x21, 12);         // mod date (1980-01-01)
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(comp.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);            // extra len
    locals.push(local, nameBuf, comp);

    // 中央目录项
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);          // version made by
    central.writeUInt16LE(20, 6);          // version needed
    central.writeUInt16LE(0x0800, 8);      // flags
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x21, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(comp.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt16LE(0, 30);          // extra
    central.writeUInt16LE(0, 32);          // comment
    central.writeUInt16LE(0, 34);          // disk
    central.writeUInt16LE(0, 36);          // internal attrs
    central.writeUInt32LE(0, 38);          // external attrs
    central.writeUInt32LE(offset, 42);     // local header offset
    centrals.push(central, nameBuf);

    offset += local.length + nameBuf.length + comp.length;
  }

  const centralBuf = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);

  return Buffer.concat([...locals, centralBuf, eocd]);
}

// ─────────────────────────── 收集文件 ────────────────────────
async function collect(dir, base = dir, out = []) {
  for (const name of await readdir(dir)) {
    if (name === '.DS_Store' || name === 'Thumbs.db') continue;
    const full = path.join(dir, name);
    const st = await stat(full);
    if (st.isDirectory()) {
      await collect(full, base, out);
    } else {
      // zip 条目一律用正斜杠，与平台无关
      const rel = path.relative(base, full).split(path.sep).join('/');
      out.push({ entryPath: rel, data: await readFile(full) });
    }
  }
  return out;
}

// ─────────────────────────── 校验 ───────────────────────────
const FORBIDDEN_EXT = ['.so', '.dll', '.dylib', '.exe', '.node'];
const MAX_FILE = 10 * 1024 * 1024;
const MAX_TOTAL = 50 * 1024 * 1024;

function validate(entries) {
  const errors = [];
  let total = 0;

  for (const e of entries) {
    total += e.data.length;
    if (e.data.length > MAX_FILE) {
      errors.push(`单文件超限: ${e.entryPath} (${(e.data.length / 1048576).toFixed(1)} MB > 10 MB)`);
    }
    const ext = path.extname(e.entryPath).toLowerCase();
    if (FORBIDDEN_EXT.includes(ext)) {
      errors.push(`禁止的文件类型: ${e.entryPath}`);
    }
    if (e.entryPath.split('/').includes('node_modules')) {
      errors.push(`禁止包含 node_modules: ${e.entryPath}`);
    }
  }
  if (total > MAX_TOTAL) {
    errors.push(`总体积超限: ${(total / 1048576).toFixed(1)} MB > 50 MB`);
  }

  const manifest = entries.find((e) => e.entryPath === 'manifest.json');
  if (!manifest) errors.push('根目录缺少 manifest.json');

  if (manifest) {
    let m;
    try {
      m = JSON.parse(manifest.data.toString('utf8'));
    } catch (err) {
      errors.push(`manifest.json 不是合法 JSON: ${err.message}`);
    }
    if (m) {
      for (const f of ['manifestVersion', 'id', 'name', 'version']) {
        if (m[f] === undefined) errors.push(`manifest.json 缺少必填字段: ${f}`);
      }
      // 入口文件必须真的在包里。零代码插件（纯美化包/人设包）没有 runtime，跳过。
      const main = m.runtime?.main;
      if (main && !entries.some((e) => e.entryPath === main)) {
        errors.push(`manifest.json 声明的入口不存在: ${main}`);
      }
      // 反过来：声明了需要代码的能力就必须有 runtime（与宿主解析器同一规则）
      if (!m.runtime) {
        const codeProvides = [
          m.provides?.tools?.length ? 'tools' : null,
          m.provides?.ui?.length ? 'ui' : null,
          m.provides?.pages?.length ? 'pages' : null,
          m.provides?.layout ? 'layout' : null,
          m.provides?.replaces ? 'replaces' : null,
        ].filter(Boolean);
        if (codeProvides.length) {
          errors.push(
            `声明了 ${codeProvides.join(' / ')} 却没有 runtime —— 这些能力需要代码实现`,
          );
        }
      }
      for (const t of m.provides?.tools ?? []) {
        if (!t.handler) { errors.push(`工具 ${t.name} 缺少 handler`); continue; }
        if (!entries.some((e) => e.entryPath === t.handler)) {
          errors.push(`工具 ${t.name} 的 handler 不存在: ${t.handler}`);
        }
      }
      for (const p of m.provides?.pages ?? []) {
        if (p.entry && !entries.some((e) => e.entryPath === p.entry)) {
          errors.push(`页面 ${p.id} 的 entry 不存在: ${p.entry}`);
        }
      }
    }
  }
  return { errors, total };
}

// ─────────────────────────── main ───────────────────────────
async function main() {
  const argv = process.argv.slice(2);
  const malIdx = argv.indexOf('--malicious-traversal');
  const outIdx = argv.indexOf('--out');
  const outDir = outIdx >= 0 ? argv[outIdx + 1] : 'dist';

  const srcArg = argv.find((a) => !a.startsWith('--') && a !== outDir);
  if (!srcArg) {
    console.error('用法: node scripts/pack_plugin.mjs <插件目录> [--out dist/] [--malicious-traversal]');
    process.exit(2);
  }

  const src = path.resolve(srcArg);
  if (!(await stat(src).catch(() => null))?.isDirectory()) {
    console.error(`不是目录: ${src}`);
    process.exit(2);
  }

  console.log(`== 打包插件: ${path.basename(src)} ==`);
  const entries = await collect(src);
  console.log(`  文件数: ${entries.length}`);

  if (malIdx >= 0) {
    // 故意注入 Zip Slip 条目，用于测试宿主防护
    entries.push({
      entryPath: '../evil-traversal.txt',
      data: Buffer.from('如果你在沙箱外看到这个文件，说明 Zip Slip 防护没生效。', 'utf8'),
    });
    console.log('  ⚠ 已注入恶意条目: ../evil-traversal.txt（仅测试用）');
  } else {
    const { errors, total } = validate(entries);
    console.log(`  解压后大小: ${(total / 1024).toFixed(1)} KB`);
    if (errors.length) {
      console.error('\n❌ 校验失败:');
      for (const e of errors) console.error(`   - ${e}`);
      process.exit(1);
    }
    console.log('  ✅ 校验通过');
  }

  const zip = await buildZip(entries);
  await mkdir(outDir, { recursive: true });

  const manifest = entries.find((e) => e.entryPath === 'manifest.json');
  let name = path.basename(src);
  let version = '0.0.0';
  if (manifest) {
    const m = JSON.parse(manifest.data.toString('utf8'));
    name = m.id ?? name;
    version = m.version ?? version;
  }
  const suffix = malIdx >= 0 ? '-MALICIOUS' : '';
  const outPath = path.join(outDir, `${name}-${version}${suffix}.zip`);
  await writeFile(outPath, zip);

  const sha = createHash('sha256').update(zip).digest('hex');
  console.log(`\n  输出: ${outPath}`);
  console.log(`  大小: ${(zip.length / 1024).toFixed(1)} KB`);
  console.log(`  sha256: ${sha}`);
}

main().catch((e) => {
  console.error('打包失败:', e);
  process.exit(1);
});
