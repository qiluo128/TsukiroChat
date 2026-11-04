/**
 * 时间插件入口。
 *
 * 生命周期与事件注册都通过 `tsukiro.*` 完成 —— 插件拿不到宿主内部对象，
 * 也拿不到任何 API Key。
 */

tsukiro.lifecycle.on('start', async () => {
  await tsukiro.log.info({ message: '时间插件已启动' });
});

tsukiro.lifecycle.on('stop', async (reason) => {
  await tsukiro.log.info({ message: '时间插件停止', data: { reason } });
});

// 权限被撤销时优雅降级：不再声称自己能回答时间问题
tsukiro.event.on('permission.change', async (e) => {
  if (e.revoked?.includes('sys.time')) {
    await tsukiro.log.warn({ message: 'sys.time 权限被撤销，时间功能已停用' });
    await tsukiro.ui.toast({ text: '时间插件：时间权限已被撤销，功能暂停' });
  }
});
