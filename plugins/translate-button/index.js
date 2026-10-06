/**
 * 翻译按钮插件。
 *
 * 演示三件事：
 *   1. 插件往宿主 UI 插槽（chat.toolbar）放控件
 *   2. 控件点击通过事件回传到插件
 *   3. 插件调 AI —— **走宿主原语，插件全程接触不到 API Key**
 */

tsukiro.event.on('ui.click', async (e) => {
  if (e.id !== 'translate') return;
  await handleTranslate();
});

/**
 * 清单里声明的是 `"onClick": { "event": "translate.clicked" }`，
 * 而上面只监听了兜底的 `ui.click` —— 于是点按钮**没有任何反应**。
 *
 * 声明与实现必须一致。这里补上清单声明的事件名：
 * 清单是插件的对外接口，实现应该去满足它，而不是反过来。
 */
tsukiro.event.on('translate.clicked', async () => {
  await handleTranslate();
});

async function handleTranslate() {
  // 取上一条助手消息作为待翻译内容
  const last = await tsukiro.chat.lastMessage({ role: 'assistant' });
  if (!last || !last.text) {
    await tsukiro.ui.toast({ text: '还没有可翻译的消息' });
    return;
  }

  const target = (await tsukiro.config.get('target')) ?? '中文';
  const tone = (await tsukiro.config.get('tone')) ?? '自然';

  await tsukiro.ui.toast({ text: `翻译中…（${target}）` });

  let translated;
  try {
    // 注意：这里没有 apiKey、没有 baseUrl、没有 headers。
    // model.chat 的参数 schema 里根本没有这些字段。
    const res = await tsukiro.model.chat({
      messages: [
        {
          role: 'system',
          content:
            '你是一个翻译引擎。只输出译文，不要解释，不要加引号，' +
            '不要保留原文。若原文已是目标语言，则原样返回。',
        },
        {
          role: 'user',
          content: `把下面的内容翻译成${target}，语气${tone}：\n\n${last.text}`,
        },
      ],
      stream: false,
    });
    translated = res.text;
  } catch (err) {
    // 权限被撤销、余额不足、限流都会走到这里
    await tsukiro.ui.dialog({
      title: '翻译失败',
      content: `${err.code}：${err.message}`,
      buttons: [{ id: 'ok', label: '知道了' }],
    });
    return;
  }

  const choice = await tsukiro.ui.dialog({
    title: `翻译（${target}）`,
    content: translated,
    buttons: [
      { id: 'copy', label: '复制' },
      { id: 'close', label: '关闭' },
    ],
  });

  const button = choice && (choice.clicked ?? choice.buttonId);
  if (button === 'copy') {
    try {
      await tsukiro.sys.clipboard.write({ text: translated });
      await tsukiro.ui.toast({ text: '已复制到剪贴板' });
    } catch (err) {
      await tsukiro.ui.toast({ text: '复制失败：' + (err.message || err) });
    }
  }
}

// 用户在设置页改了目标语言时给个反馈
tsukiro.event.on('config.change', async (e) => {
  if (e.key === 'target') {
    await tsukiro.ui.toast({ text: `目标语言已切换为 ${e.value}` });
  }
});
