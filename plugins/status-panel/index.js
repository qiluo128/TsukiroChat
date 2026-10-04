/**
 * 状态面板插件入口。
 *
 * 这个插件的用途是**验证宿主的 UI 渲染链路**：
 *   声明式 UI → 宿主画成原生控件 → 点击 → 事件回到这里 → 调原语 → 宿主弹提示
 *
 * 每一步都可能断，而这个插件把每一步都走一遍。
 */

tsukiro.lifecycle.on('start', async () => {
  await tsukiro.log.info({
    message: '状态面板已启动',
    data: tsukiro.__registered(),
  });
});

tsukiro.lifecycle.on('stop', async (reason) => {
  await tsukiro.log.info({ message: '状态面板停止', data: { reason } });
});

tsukiro.lifecycle.on('error', async (e) => {
  await tsukiro.log.error({ message: '状态面板出错', data: e });
});

/**
 * 「现在几点」按钮。
 *
 * 这条路径串起了全部环节：按钮 → 事件 → 原语调用 → 门禁 → 实际执行 →
 * 结果回到插件 → 再调 ui.toast → 宿主弹提示。
 */
tsukiro.event.on('status.time_clicked', async () => {
  try {
    const t = await tsukiro.sys.time({});
    await tsukiro.ui.toast({ text: '现在是 ' + t.human });
  } catch (e) {
    // 演示失败路径：权限被撤销、原语未实现都会走到这里。
    // **必须 catch** —— 让异常逃逸出去的话，用户点了按钮什么都不会发生。
    await tsukiro.ui.toast({ text: '读时间失败：' + (e.message || e) });
  }
});

tsukiro.event.on('status.greet', async () => {
  await tsukiro.ui.toast({ text: '你好，我是状态面板插件。' });
});

// toggle 的事件名没写 onClick.event，所以走兜底的 ui.click
tsukiro.event.on('ui.click', async (e) => {
  await tsukiro.log.info({ message: '收到界面点击', data: e });

  // 只有 toggle 会带 value
  if (e && typeof e.value === 'boolean') {
    await tsukiro.ui.toast({
      text: '自动报时已' + (e.value ? '开启' : '关闭'),
    });
  }
});

// 权限被撤销时优雅降级
tsukiro.event.on('permission.change', async (e) => {
  if (e.revoked && e.revoked.indexOf('sys.time') >= 0) {
    await tsukiro.log.warn({ message: 'sys.time 权限被撤销，报时功能停用' });
  }
});
