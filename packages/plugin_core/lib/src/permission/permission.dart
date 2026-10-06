/// 权限目录 —— 与 `docs/06-permissions.md` §3 严格一一对应。
///
/// **本文件是权限的唯一事实来源。** 新增权限必须同时更新文档与
/// [permissionCatalog]，否则 `permission_catalog_test.dart` 会失败。
library;

/// 权限风险级别。
enum PermissionLevel {
  /// 安装时一次性授权，之后运行不再打扰。绝大多数权限属此级。
  install,

  /// 每次调用都必须弹原生确认框，且**永不提供「不再询问」**。
  /// 仅用于极高风险能力：无障碍、截屏、录屏、发短信、拨号、读取他人数据。
  confirm,

  /// 宿主保留，插件申请即安装失败。
  denied,
}

/// 一条权限的定义。
class PermissionSpec {
  const PermissionSpec(this.name, this.level, this.description);

  final String name;
  final PermissionLevel level;
  final String description;

  @override
  String toString() => '$name(${level.name})';
}

/// 权限目录：name → spec。
const Map<String, PermissionSpec> permissionCatalog = <String, PermissionSpec>{
  // ── 文件与存储（沙箱内，故为 install 级） ──
  'fs.read': PermissionSpec('fs.read', PermissionLevel.install, '读取插件沙箱内的文件'),
  'fs.write': PermissionSpec('fs.write', PermissionLevel.install, '写入插件沙箱内的文件'),
  'fs.delete': PermissionSpec('fs.delete', PermissionLevel.install, '删除插件沙箱内的文件'),

  // ── 系统信息 ──
  'sys.time': PermissionSpec('sys.time', PermissionLevel.install, '读取当前系统时间'),
  'sys.info': PermissionSpec('sys.info', PermissionLevel.install, '读取电量、网络状态、设备型号、语言区域'),
  'sys.clipboard.read':
      PermissionSpec('sys.clipboard.read', PermissionLevel.confirm, '读取剪贴板内容（常含密码、地址等敏感信息）'),
  'sys.clipboard.write':
      PermissionSpec('sys.clipboard.write', PermissionLevel.install, '写入剪贴板、触发震动'),

  // ── 媒体 ──
  'media.read': PermissionSpec('media.read', PermissionLevel.confirm, '读取相册照片'),
  'media.camera': PermissionSpec('media.camera', PermissionLevel.confirm, '使用摄像头拍照或录像'),
  'media.microphone': PermissionSpec('media.microphone', PermissionLevel.confirm, '使用麦克风录音'),

  // ── 通讯 ──
  'contact.read': PermissionSpec('contact.read', PermissionLevel.confirm, '读取通讯录'),
  'sms.read': PermissionSpec('sms.read', PermissionLevel.confirm, '读取短信（含验证码）'),
  'sms.send': PermissionSpec('sms.send', PermissionLevel.confirm, '以用户手机号发送短信'),
  'call.make': PermissionSpec('call.make', PermissionLevel.confirm, '拨打电话'),

  // ── 日历与应用 ──
  'calendar.read': PermissionSpec('calendar.read', PermissionLevel.install, '读取日历事件'),
  'calendar.write': PermissionSpec('calendar.write', PermissionLevel.install, '创建与修改日历事件'),
  'app.read': PermissionSpec('app.read', PermissionLevel.install, '查询已安装应用列表与信息'),
  'app.launch': PermissionSpec('app.launch', PermissionLevel.install, '打开其他应用或跳转链接'),

  // ── 通知与定位 ──
  'notification.send': PermissionSpec('notification.send', PermissionLevel.install, '发送系统通知'),
  'notification.read': PermissionSpec('notification.read', PermissionLevel.confirm, '读取系统通知'),
  'location': PermissionSpec('location', PermissionLevel.confirm, '获取设备位置'),

  // ── 网络：白名单是权限的一部分，见 manifest.network.allow ──
  'net': PermissionSpec('net', PermissionLevel.install, '发起网络请求（须同时命中 manifest 声明的域名白名单）'),

  // ── UI ──
  'ui': PermissionSpec('ui', PermissionLevel.install, '弹提示、对话框、跳转插件页面'),
  'chat.read': PermissionSpec(
    'chat.read',
    PermissionLevel.install,
    '读取当前对话的上下文（最近一条消息、会话信息）',
  ),
  'agent.state.read': PermissionSpec('agent.state.read', PermissionLevel.install, '读取当前智能体状态'),
  'agent.state.write': PermissionSpec('agent.state.write', PermissionLevel.install, '更新当前智能体状态'),
  'memory.read': PermissionSpec('memory.read', PermissionLevel.install, '读取当前智能体的长期记忆'),
  'memory.write': PermissionSpec('memory.write', PermissionLevel.install, '写入当前智能体的长期记忆'),
  'ui.surface': PermissionSpec('ui.surface', PermissionLevel.install, '创建和更新插件 Surface'),

  'ui.overlay': PermissionSpec('ui.overlay', PermissionLevel.install, '在宿主界面上叠加覆盖层'),

  // ── 模型：消耗用户点数，安装弹窗必须提示 ──
  'model.chat': PermissionSpec('model.chat', PermissionLevel.install, '调用 AI 模型（会消耗用户点数）'),

  // ── 高风险 ──
  'a11y': PermissionSpec('a11y', PermissionLevel.confirm, '无障碍服务：读取屏幕内容并模拟操作其他应用'),
  'screen.capture': PermissionSpec('screen.capture', PermissionLevel.confirm, '截取屏幕'),
  'screen.record': PermissionSpec('screen.record', PermissionLevel.confirm, '录制屏幕'),

  // ── 系统干预：打断用户当前操作 ──
  'sys.intervene': PermissionSpec(
    'sys.intervene',
    PermissionLevel.confirm,
    '打断用户当前操作：屏幕拉回、锁定其他应用、弹出系统弹窗',
  ),
  'sys.overlay': PermissionSpec(
    'sys.overlay',
    PermissionLevel.install,
    '在宿主界面上显示悬浮层（仅叠加显示，不打断操作）',
  ),

  // ── 上下文注入：影响 AI 说什么 ──
  'context.write': PermissionSpec(
    'context.write',
    PermissionLevel.install,
    '往 AI 上下文注入文本或追加消息（可撤销、有长度上限、记审计）',
  ),
  'context.hook': PermissionSpec(
    'context.hook',
    PermissionLevel.install,
    '注册上下文钩子，持续影响每一轮的上下文组装',
  ),

  // ── 消息操作 ──
  'message.read': PermissionSpec('message.read', PermissionLevel.confirm, '读取消息内容，含全部历史对话'),
  'message.write': PermissionSpec('message.write', PermissionLevel.install, '修改或删除已有消息'),
  'message.send': PermissionSpec(
    'message.send',
    PermissionLevel.install,
    '主动发送消息（会触发模型调用并消耗点数）',
  ),

  // ── 调度 ──
  'schedule': PermissionSpec(
    'schedule',
    PermissionLevel.install,
    '创建后台定时任务（最短周期 60 秒，触发时重新校验权限）',
  ),

  // ── 预留 ──
  'mcp': PermissionSpec('mcp', PermissionLevel.install, '连接远程 MCP Server 或暴露本地 MCP Server'),
};

/// 无需权限即可调用的原语域（见 `docs/05-primitives.md` §2）。
///
/// 这些域要么只操作插件私有数据，要么是纯计算，要么是基础设施。
///
/// **注意 `context` / `message` / `schedule` 都不在这里** —— 它们影响的是
/// AI 说什么、对话长什么样、后台什么时候干活，全部需要显式授权。
const Set<String> permissionFreeDomains = <String>{
  // read 的是插件自己的配置段（manifest 里 provides.config 声明的），
  // 不含任何用户数据 —— 不该让用户为它做决定。
  'config',
  // 插件私有数据与纯计算
  'state',
  'crypto',
  // 基础设施
  'tool',
  'event',
  'log',
  // 自省：插件有权知道宿主支持什么，否则只能靠版本号猜（见 docs/16 §6）
  'host',
  'primitive',
  'hook',
  'slot',
};

/// 查询权限定义，未知权限返回 null。
PermissionSpec? lookupPermission(String name) => permissionCatalog[name];

/// 该权限名是否在目录中（用于 manifest 校验，防拼错静默失效）。
bool isKnownPermission(String name) => permissionCatalog.containsKey(name);

/// 权限级别，未知权限视为 [PermissionLevel.denied]（fail-closed）。
PermissionLevel levelOf(String name) =>
    permissionCatalog[name]?.level ?? PermissionLevel.denied;

/// 原语 → 权限的**精确**映射。
///
/// 只列「不能靠域名默认值推导」的那些：同一域名下权限不同（fs 读/写/删、
/// media 读/相机/麦克风、app 读/启动、calendar 读/写、notification 发/读）。
///
/// 与 `docs/05-primitives.md` §2 的映射表一一对应。
const Map<String, String> _exactPrimitivePermissions = <String, String>{
  // 文件系统：读 / 写 / 删 三个权限
  'fs.list': 'fs.read',
  'fs.read': 'fs.read',
  'fs.meta': 'fs.read',
  'fs.pickFile': 'fs.read',
  'fs.write': 'fs.write',
  'fs.mkdir': 'fs.write',
  'fs.saveFile': 'fs.write',
  'fs.delete': 'fs.delete',

  // 系统信息：时间单独一档，其余合并为 sys.info
  'sys.time': 'sys.time',
  'sys.battery': 'sys.info',
  'sys.network': 'sys.info',
  'sys.device': 'sys.info',
  'sys.locale': 'sys.info',
  'sys.clipboard.read': 'sys.clipboard.read',
  'sys.clipboard.write': 'sys.clipboard.write',
  'sys.vibrate': 'sys.clipboard.write',

  // 媒体：相册读 / 相机 / 麦克风 三档
  'media.listPhotos': 'media.read',
  'media.getPhoto': 'media.read',
  'media.audio.play': 'media.read',
  'media.video.play': 'media.read',
  'media.camera.capture': 'media.camera',
  'media.camera.record': 'media.camera',
  'media.audio.record': 'media.microphone',

  // 上下文注入：单次写入 vs 持续钩子，风险不同档
  'context.inject': 'context.write',
  'context.append': 'context.write',
  'context.onBuild': 'context.hook',
  'context.onBeforeModel': 'context.hook',
  'context.onAfterModel': 'context.hook',

  // 消息操作：读 / 写 / 主动发送 三档（发送会触发模型调用，单独一档）
  'message.get': 'message.read',
  'message.update': 'message.write',
  'message.append': 'message.write',
  'message.delete': 'message.write',
  'message.send': 'message.send',

  // 系统干预：打断用户当前操作（overlay 只叠加显示，风险低一档）
  'sys.screen.pullBack': 'sys.intervene',
  'sys.app.lock': 'sys.intervene',
  'sys.dialog.popup': 'sys.intervene',
  'sys.overlay.show': 'sys.overlay',
  'sys.overlay.hide': 'sys.overlay',

  // 通讯：发短信与读短信分开
  'sms.send': 'sms.send',
  'sms.list': 'sms.read',
  'sms.listen': 'sms.read',
  'call.make': 'call.make',
  'call.log': 'call.make',

  // 日历：读 / 写
  'calendar.list': 'calendar.read',
  'calendar.create': 'calendar.write',
  'calendar.update': 'calendar.write',

  // 应用：读 / 启动
  'app.list': 'app.read',
  'app.isInstalled': 'app.read',
  'app.info': 'app.read',
  'app.open': 'app.launch',

  // 通知：发 / 读
  'notification.send': 'notification.send',
  'notification.cancel': 'notification.send',
  'notification.listen': 'notification.read',

  // 截屏：捕获 / 录屏
  'screen.capture': 'screen.capture',
  'screen.analyze': 'screen.capture',
  'screen.record': 'screen.record',

  // 智能体状态与记忆
  'agent.state.get': 'agent.state.read',
  'agent.state.set': 'agent.state.write',
  'agent.greet': 'agent.state.write',
  'agent.model.chat': 'model.chat',
  'memory.list': 'memory.read',
  'memory.add': 'memory.write',
  'surface.open': 'ui.surface',
  'surface.update': 'ui.surface',
  'surface.close': 'ui.surface',
};

/// 域名 → 默认权限。适用于「整个域共用同一个权限」的情况。
const Map<String, String> _domainDefaultPermissions = <String, String>{
  'contact': 'contact.read',
  'location': 'location',
  'net': 'net',
  'model': 'model.chat',
  'a11y': 'a11y',
  'mcp': 'mcp',
  'schedule': 'schedule',
  'ui': 'ui', // ui.overlay.* 是特例，见下
  // chat.* 读的是用户的对话内容，该让用户知道并同意。
  // 原先没有这个域，于是 requiredPermissionFor 返回域名 'chat'，
  // 而 'chat' 不在权限目录里 → 门禁判「未知权限」直接拒。
  // 表现是插件调 chat.lastMessage 必然失败，且看不出原因。
  'chat': 'chat.read',
  'agent': 'agent.state.read',
  'memory': 'memory.read',
};

/// 某原语（如 `sys.time`、`fs.read`）所需的权限名。
///
/// 返回 null 表示该原语**无需权限**（见 [permissionFreeDomains]）。
///
/// **未知域名会返回域名本身**，而不是 null。这是刻意的 fail-closed 设计：
/// 该名字不在权限目录中，守门人会判 `unknownPermission` 并拒绝，而不是放行。
/// 新增原语域时必须同步在目录里加权限，否则调用会被拒 —— 宁可拒绝也不放行。
String? requiredPermissionFor(String primitive) {
  final text = primitive.trim();
  if (text.isEmpty) return null;

  // ① 名字本身就在权限目录里 → 自身。
  //    必须放在格式检查之前，因为 location / net / ui / a11y / mcp 这些权限名
  //    没有点号，会被下面的「必须是 domain.action」检查误判为非法原语名。
  //    这条规则同时保证了「目录里每个权限名映射到自身」这一不变量。
  if (isKnownPermission(text)) return text;

  final dot = text.indexOf('.');
  // 没有点号（`foo`）或以点结尾（`foo.`）都不是合法原语名
  if (dot <= 0 || dot == text.length - 1) return null;

  // ② 无需权限的域
  final domain = text.substring(0, dot);
  if (permissionFreeDomains.contains(domain)) return null;

  // ③ 同一域名下权限不同的精确映射（fs 读写删、media 读/相机/麦克风、…）
  final exact = _exactPrimitivePermissions[text];
  if (exact != null) return exact;

  // ④ ui.overlay.show / ui.overlay.hide 归到 ui.overlay
  if (text.startsWith('ui.overlay.')) return 'ui.overlay';

  // ⑤ 整域共用同一权限
  final byDomain = _domainDefaultPermissions[domain];
  if (byDomain != null) return byDomain;

  // ⑥ 未知域：返回域名，交给守门人按「未知权限」拒绝（fail-closed）。
  //    绝不能返回 null —— 那等于「无需权限」，是 fail-open。
  return domain;
}
