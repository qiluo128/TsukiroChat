// 石头剪刀布：规则和状态机在插件侧；WebView/Flame 只负责渲染。
const CHOICES = ['rock', 'paper', 'scissors'];
const LABELS = { rock: '石头', paper: '布', scissors: '剪刀' };
let surface = null;
let score = { user: 0, ai: 0, draws: 0, rounds: 0 };
let lastResult = '';

function resultOf(user, ai) {
  if (user === ai) return 'draw';
  if ((user === 'rock' && ai === 'scissors') ||
      (user === 'paper' && ai === 'rock') ||
      (user === 'scissors' && ai === 'paper')) return 'user';
  return 'ai';
}

function scene() {
  return {
    title: '石头剪刀布',
    score: `${score.user}胜 ${score.ai}负 ${score.draws}平`,
    result: lastResult,
    buttons: CHOICES.map((id) => ({ id, label: LABELS[id] })),
    actions: [
      { id: 'again', label: '再来一局' },
      { id: 'exit', label: '退出' },
    ],
  };
}

async function render() {
  if (surface) await tsukiro.surface.update({ surfaceId: surface, state: scene() });
}

async function open(kind) {
  surface = kind === 'web' ? 'web-game' : 'flame-game';
  const opened = await tsukiro.surface.open({ surfaceId: surface });
  if (!opened || opened.ok === false) {
    await tsukiro.ui.toast({ text: `${kind === 'web' ? 'WebView' : 'Flame'} 游戏暂不可用` });
    surface = null;
    return;
  }
  await render();
}

async function askAi(userChoice) {
  const response = await tsukiro.agent.model.chat({
    messages: [
      { role: 'system', content: '你是石头剪刀布对手。只输出 rock、paper 或 scissors 三者之一。' },
      { role: 'user', content: `用户出了 ${LABELS[userChoice]}。请随机选择一个出拳，只输出英文枚举。` },
    ],
  });
  const value = String(response.text || '').toLowerCase();
  return CHOICES.find((choice) => value.includes(choice)) || CHOICES[Math.floor(Math.random() * 3)];
}

async function play(userChoice) {
  try {
    const aiChoice = await askAi(userChoice);
    const winner = resultOf(userChoice, aiChoice);
    score.rounds += 1;
    if (winner === 'user') score.user += 1;
    else if (winner === 'ai') score.ai += 1;
    else score.draws += 1;
    lastResult = `你：${LABELS[userChoice]} · AI：${LABELS[aiChoice]} · ${winner === 'draw' ? '平局' : winner === 'user' ? '你赢了' : 'AI 赢了'}`;
    await render();
  } catch (error) {
    await tsukiro.ui.toast({ text: `AI 出拳失败：${error.message || error}` });
  }
}

async function finish() {
  if (score.rounds === 0) return;
  try {
    const response = await tsukiro.agent.model.chat({
      messages: [
        { role: 'system', content: '你是当前智能体。用自然、简短的中文评价刚才的石头剪刀布，不要输出原始 JSON。' },
        { role: 'user', content: `游戏结束，共 ${score.rounds} 局；用户 ${score.user} 胜，AI ${score.ai} 胜，平局 ${score.draws} 局。请评价这次游戏。` },
      ],
    });
    const text = String(response.text || '这局玩得不错。').trim();
    await tsukiro.memory.add({
      content: `与用户玩了${score.rounds}局石头剪刀布：用户${score.user}胜、AI${score.ai}胜、平局${score.draws}局。评价：${text}`,
      kind: 'game_summary',
    });
    await tsukiro.message.append({ content: text, role: 'assistant' });
    lastResult = text;
    await render();
  } catch (error) {
    await tsukiro.ui.toast({ text: `评价失败：${error.message || error}` });
  }
}

async function reset() {
  score = { user: 0, ai: 0, draws: 0, rounds: 0 };
  lastResult = '';
  await render();
}

async function close() {
  if (surface) await tsukiro.surface.close({ surfaceId: surface });
  surface = null;
}

tsukiro.event.on('rps.open.web', () => open('web'));
tsukiro.event.on('rps.open.flame', () => open('flame'));
tsukiro.event.on('surface.event', async (event) => {
  if (!event || event.surfaceId !== surface) return;
  if (event.action === 'choice') await play(event.value);
  else if (event.action === 'again') await reset();
  else if (event.action === 'finish') await finish();
  else if (event.action === 'exit') await close();
});
