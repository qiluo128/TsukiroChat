#!/usr/bin/env node
/**
 * 中转站 / API 探针 —— 回答三个问题：
 *   1. 连通吗？
 *   2. `/v1/models` 能拉到模型表吗？
 *   3. `/v1/chat/completions` 能真的出字吗（含流式）？
 *
 * 凭据只从环境变量读，**绝不写进文件、绝不回显**。
 *
 * 用法:
 *   $env:PROBE_BASE='http://host:port/v1'; $env:PROBE_KEY='sk-...'
 *   node scripts/probe_model_api.mjs [模型名]
 *
 * 为什么用 node 而不是 curl：本机沙箱下 Windows schannel 拿不到证书凭据，
 * curl / Invoke-WebRequest 对 https 全部失败；node 自带 CA 正常。
 * （这个中转站是 http，本来不受影响，但脚本要能通用。）
 */
import http from 'node:http';
import https from 'node:https';

const BASE = (process.env.PROBE_BASE ?? '').replace(/\/+$/, '');
const KEY = process.env.PROBE_KEY ?? '';
const MODEL = process.argv[2] ?? process.env.PROBE_MODEL ?? '';

if (!BASE) {
  console.error('缺少 PROBE_BASE，例如 http://103.236.91.136:52165/v1');
  process.exit(2);
}
if (!KEY) {
  console.error('缺少 PROBE_KEY');
  process.exit(2);
}

/** 发一个请求，返回 { status, headers, text, ms } */
function request(method, path, { body, stream = false, timeoutMs = 60000 } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(BASE + path);
    const isHttps = url.protocol === 'https:';
    const payload = body ? JSON.stringify(body) : null;

    const req = (isHttps ? https : http).request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname + url.search,
        method,
        headers: {
          Authorization: `Bearer ${KEY}`,
          'Content-Type': 'application/json',
          Accept: stream ? 'text/event-stream' : 'application/json',
          'User-Agent': 'tsukiro-probe',
          ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
        },
      },
      (res) => {
        const started = Date.now();
        const chunks = [];
        res.on('data', (c) => {
          chunks.push(c);
          if (stream) {
            // 流式：边收边打印
            process.stdout.write(c.toString('utf8'));
          }
        });
        res.on('end', () =>
          resolve({
            status: res.statusCode,
            headers: res.headers,
            text: Buffer.concat(chunks).toString('utf8'),
            ms: Date.now() - started,
          }),
        );
      },
    );

    req.on('error', reject);
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`超时 ${timeoutMs}ms`));
    });
    if (payload) req.write(payload);
    req.end();
  });
}

const line = (s) => console.log(s);
const hr = () => line('─'.repeat(64));

// ───────── ① 连通性 ─────────
hr();
line(`① 连通性  ${BASE}`);
try {
  const r = await request('GET', '/models', { timeoutMs: 20000 });
  line(`   HTTP ${r.status}  ${r.ms}ms`);
  if (r.status === 200) {
    let parsed = null;
    try { parsed = JSON.parse(r.text); } catch { /* 可能不是 JSON */ }

    const list = parsed?.data ?? parsed?.models ?? (Array.isArray(parsed) ? parsed : null);
    if (Array.isArray(list)) {
      line(`   ✓ 拉到模型表：${list.length} 个模型`);
      const ids = list.map((m) => m.id ?? m.name ?? m.model).filter(Boolean);
      line(`   前 20 个：`);
      for (const id of ids.slice(0, 20)) line(`     · ${id}`);
      if (ids.length > 20) line(`     … 还有 ${ids.length - 20} 个`);

      if (MODEL && !ids.some((i) => i === MODEL || i.includes(MODEL))) {
        line(`   ⚠ 你指定的模型 "${MODEL}" 不在列表里（可能是别名或路由名）`);
      }
    } else {
      line('   ? 返回了 200 但结构不认得，前 300 字符：');
      line('   ' + r.text.slice(0, 300));
    }
  } else {
    line(`   ✗ 失败：${r.text.slice(0, 300)}`);
  }
} catch (e) {
  line(`   ✗ 连不上：${e.message}`);
}
line('');

// ───────── ② 非流式补全 ─────────
if (MODEL) {
  hr();
  line(`② 非流式补全  model=${MODEL}`);
  try {
    const r = await request('POST', '/chat/completions', {
      body: {
        model: MODEL,
        messages: [
          { role: 'system', content: '你是一个简洁的助手，只回答被问到的内容。' },
          { role: 'user', content: '用一句话回答：你现在能正常工作吗？' },
        ],
        max_tokens: 64,
        stream: false,
      },
      timeoutMs: 90000,
    });
    line(`   HTTP ${r.status}  ${r.ms}ms`);
    if (r.status === 200) {
      const parsed = JSON.parse(r.text);
      const text = parsed?.choices?.[0]?.message?.content ?? '(空)';
      line(`   ✓ 回复：${text}`);
      line(`   model  : ${parsed?.model ?? '(未返回)'}`);
      const u = parsed?.usage;
      if (u) line(`   usage  : prompt=${u.prompt_tokens} completion=${u.completion_tokens} total=${u.total_tokens}`);
    } else {
      line(`   ✗ 失败：${r.text.slice(0, 500)}`);
    }
  } catch (e) {
    line(`   ✗ ${e.message}`);
  }
  line('');

  // ───────── ③ 流式 + 工具调用 ─────────
  hr();
  line(`③ 流式 + 工具调用  model=${MODEL}`);
  try {
    const r = await request('POST', '/chat/completions', {
      body: {
        model: MODEL,
        messages: [{ role: 'user', content: '现在几点了？用 get_time 工具查。' }],
        tools: [
          {
            type: 'function',
            function: {
              name: 'get_time',
              description: '获取当前时间',
              parameters: {
                type: 'object',
                properties: { timezone: { type: 'string', description: 'IANA 时区名' } },
                required: [],
              },
            },
          },
        ],
        tool_choice: 'auto',
        max_tokens: 200,
        stream: true,
      },
      stream: true,
      timeoutMs: 90000,
    });
    line(`\n   HTTP ${r.status}  ${r.ms}ms`);
    if (r.status !== 200) {
      line(`   ✗ 失败`);
    } else {
      line('   ↑ 以上是原始 SSE 流');
      const hasToolCall = r.text.includes('tool_calls');
      line(`   工具调用：${hasToolCall ? '✓ 模型发起了 tool_calls' : '— 模型选择直接回答'}`);
    }
  } catch (e) {
    line(`   ✗ ${e.message}`);
  }
} else {
  hr();
  line('② ③ 已跳过（未指定模型名）。指定方式：node scripts/probe_model_api.mjs <模型名>');
}

line('');
hr();
line('探测完成。');
