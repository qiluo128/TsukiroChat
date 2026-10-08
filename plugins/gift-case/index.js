/**
 * 礼物展柜 · 入口
 *
 * 这个插件演示的是**原生界面窗口**：插件送来一棵声明式 UI 树，
 * 宿主用 Flutter 渲染。插件拿不到 Flutter，也拿不到颜色之外的样式。
 *
 * 于是深浅色切换、主题换色、圆角间距字体全都自动跟着宿主走 ——
 * 用 WebView 画同样的东西永远做不到这点。
 */

const WINDOW_ID = 'case';
const MAX_GIFTS = 200;

/** 读礼物列表。没写过就是空数组。 */
async function loadGifts() {
  const r = await tsukiro.state.get({ key: 'gifts' });
  const value = r && r.value;
  return Array.isArray(value) ? value : [];
}

/**
 * 把礼物列表变成一棵 UI 树。
 *
 * 这棵树的形状就是宿主渲染的全部输入 —— 没有 HTML、没有 CSS，
 * 也没有「样式」这种东西，只有语义。
 */
function buildTree(gifts) {
  if (gifts.length === 0) {
    return {
      type: 'column',
      align: 'center',
      spacing: 14,
      children: [
        { type: 'shape', shape: 'diamond', color: '#C9D6DB', size: 'lg' },
        { type: 'text', text: '还没有收到礼物', size: 'lg', emphasis: 'muted', align: 'center' },
        {
          type: 'text',
          text: '和它聊聊天吧 —— 说不定它会想送你点什么。',
          size: 'sm',
          emphasis: 'muted',
          align: 'center',
        },
      ],
    };
  }

  // 最新的排在前面：用户想先看到刚收到的
  const ordered = gifts.slice().reverse();

  return {
    type: 'column',
    spacing: 16,
    children: [
      {
        type: 'text',
        text: `一共收到 ${gifts.length} 份礼物`,
        size: 'sm',
        emphasis: 'muted',
      },
      {
        type: 'grid',
        columns: gifts.length === 1 ? 1 : 2,
        spacing: 12,
        children: ordered.map((g) => {
          const [year, month, day] = String(g.at || '').split('-');
          const when = year ? `${month}-${day}` : '';
          return {
            type: 'card',
            id: g.id,
            onTap: 'gift.tap',
            children: [
              {
                type: 'column',
                align: 'center',
                spacing: 8,
                children: [
                  { type: 'shape', shape: g.shape, color: g.color, size: 'md' },
                  { type: 'text', text: g.name, align: 'center' },
                ],
              },
            ],
          };
        }),
      },
    ],
  };
}

/** 把展柜内容推给宿主。窗口没开着时更新会返回 false，这不是错误。 */
async function refresh() {
  const gifts = await loadGifts();
  await tsukiro.ui.window.update({ windowId: WINDOW_ID, root: buildTree(gifts) });
}

tsukiro.lifecycle.on('start', async () => {
  const gifts = await loadGifts();
  await tsukiro.log.info({
    message: '礼物展柜已启动',
    data: { gifts: gifts.length },
  });
});

// 主界面点「礼物展柜」
tsukiro.event.on('gift.open', async () => {
  try {
    const gifts = await loadGifts();
    const opened = await tsukiro.ui.window.open({
      windowId: WINDOW_ID,
      title: gifts.length > 0 ? `礼物展柜（${gifts.length}）` : '礼物展柜',
      root: buildTree(gifts),
    });
    if (!opened || opened.opened === false) {
      await tsukiro.ui.toast({ text: '礼物展柜打不开，请重试' });
    }
  } catch (e) {
    // **必须 catch** —— 让异常逃逸出去的话，用户点了按钮什么都不会发生
    await tsukiro.ui.toast({ text: '打开礼物展柜失败：' + (e.message || e) });
  }
});

// 礼物被点了一下：给一句提示，顺带告诉用户是哪一份
tsukiro.event.on('gift.tap', async (e) => {
  try {
    const gifts = await loadGifts();
    const gift = gifts.find((g) => g.id === e.nodeId);
    if (!gift) return;
    await tsukiro.ui.toast({
      text: gift.description ? `${gift.name}：${gift.description}` : gift.name,
    });
  } catch (err) {
    await tsukiro.log.warn({ message: '查看礼物失败', data: { error: String(err) } });
  }
});

// 送礼物由工具处理器写入，写完之后要把开着的展柜刷新一下 ——
// 否则用户正看着展柜时收到礼物，要关掉重开才看得到
tsukiro.event.on('gift.changed', async () => {
  await refresh();
});

tsukiro.lifecycle.on('stop', async (reason) => {
  await tsukiro.ui.window.close({ windowId: WINDOW_ID }).catch(() => {});
  await tsukiro.log.info({ message: '礼物展柜停止', data: { reason } });
});
