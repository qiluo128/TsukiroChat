/**
 * 猜数字插件入口。
 *
 * 本体只负责响应工具栏按钮；真正的游戏逻辑在 pages/game.html 里。
 */

tsukiro.event.on('ui.click', async (e) => {
  if (e.id !== 'open-game') return;

  const opened = await tsukiro.ui.navigate({ pageId: 'game' });
  if (!opened) {
    await tsukiro.ui.toast({ text: '打不开游戏窗口' });
  }
});

// 页面被关闭时（用户手动关窗）记一条日志，方便排查
tsukiro.event.on('page.close', async (e) => {
  if (e.pageId === 'game') {
    await tsukiro.log.info({ message: '游戏窗口已关闭' });
  }
});
