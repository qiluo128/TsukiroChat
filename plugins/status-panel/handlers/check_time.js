/**
 * 工具处理器：check_time
 *
 * 宿主在模型触发 `check_time` 时通过 Bridge 的 `inv tool.invoke` 调到这里。
 * 返回值会被包成 `role: "tool"` 消息交给模型。
 *
 * @param {{ timezone?: string }} args
 * @returns {Promise<object>}
 */
export default async function check_time(args) {
  const t = await tsukiro.sys.time({ tz: args.timezone });

  return {
    time: t.iso,
    epochMs: t.epochMs,
    timezone: t.tz,
    human: t.human,
    // 给模型的额外提示：这类字段对提升工具调用质量很有帮助
    hint: '请用自然语言把时间告诉用户，不要直接输出 JSON。',
  };
}
