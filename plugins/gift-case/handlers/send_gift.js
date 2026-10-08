/**
 * 工具处理器：send_gift
 *
 * 宿主在模型触发 `send_gift` 时通过 Bridge 调到这里。
 * 返回值会被包成 `role: "tool"` 消息交给模型。
 *
 * 这个处理器**不直接画界面** —— 它只负责把礼物记下来，
 * 然后告诉入口去刷新展柜。界面是声明描述的，不是在这里构建的。
 */

/** 图形白名单。和宿主 UiShape 枚举一一对应。 */
const SHAPES = ['circle', 'square', 'triangle', 'star', 'heart', 'diamond', 'hexagon'];

/** 颜色必须匹配 #RRGGBB 或 #RGB。 */
const COLOR_RE = /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

/** 一份礼物的名字最多多长。太长会把卡片撑变形。 */
const MAX_NAME = 24;
const MAX_DESC = 120;

/** 展柜留多少份。超出就丢最旧的。 */
const MAX_GIFTS = 200;

function normalizeColor(raw) {
  if (typeof raw !== 'string') return null;
  const text = raw.trim();
  if (!COLOR_RE.test(text)) return null;
  return text.startsWith('#') ? text : '#' + text;
}

function today() {
  // 只用来给展柜排序和显示，不追求精确时区
  return new Date().toISOString().slice(0, 10);
}

export default async function send_gift(args) {
  const name = String(args.name || '').trim().slice(0, MAX_NAME);
  if (!name) {
    return {
      ok: false,
      error: '礼物需要一个名字',
      hint: '请给礼物起一个具体的名字再试一次。',
    };
  }

  const description = String(args.description || '').trim().slice(0, MAX_DESC);

  // 非法图形退回 heart：这是礼物，因为参数写错就送不出去太苛刻。
  // **但要在返回值里说明**，否则模型不知道自己的参数被改了。
  const rawShape = String(args.shape || '').trim();
  const shape = SHAPES.includes(rawShape) ? rawShape : 'heart';
  const shapeCorrected = rawShape !== '' && !SHAPES.includes(rawShape);

  const color = normalizeColor(args.color) || '#E8556D';
  const colorCorrected = args.color != null && normalizeColor(args.color) === null;

  const r = await tsukiro.state.get({ key: 'gifts' });
  const existing = Array.isArray(r && r.value) ? r.value : [];

  const gift = {
    id: 'g' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
    name,
    description,
    shape,
    color,
    at: today(),
  };

  // 新的放后面，展柜显示时再反转 —— 这样裁剪最旧的很简单
  const next = existing.concat([gift]).slice(-MAX_GIFTS);
  await tsukiro.state.set({ key: 'gifts', value: next });

  // 让开着的展柜立刻刷新。
  // 用户正看着展柜时收到礼物，不该要关掉重开才看得到。
  //
  // 这是**插件内部**的事件（handler → index.js），
  // 不经过宿主，所以不需要权限。
  tsukiro.event.emit('gift.changed', { id: gift.id });

  return {
    ok: true,
    gift: { name, description, shape, color },
    total: next.length,
    // 参数被纠正过就明说 —— 让模型知道下次该怎么写
    ...(shapeCorrected || colorCorrected
      ? {
          corrected: {
            ...(shapeCorrected ? { shape: { given: rawShape, used: shape } } : {}),
            ...(colorCorrected ? { color: { given: args.color, used: color } } : {}),
          },
          hint: '部分参数不被支持，已用默认值代替。图形只能是 ' + SHAPES.join('/') + '，颜色要写成 #RRGGBB。',
        }
      : {}),
    hint: `礼物已放进展柜（共 ${next.length} 份）。用自然、简短的中文告诉用户你送了什么，不要输出 JSON。`,
  };
}
