/// 原语目录 —— 宿主支持的全部原语。
///
/// **Demo 阶段只实现 4 个，但这里把全部 24 个域都注册上。**
///
/// 为什么：如果 Demo 只把四个原语硬编码进 `switch`，后面每加一个原语都要动宿主核心，
/// 插件框架就退化成了「宿主写死的功能列表」。全部注册 + 占位实现，让「未实现」成为
/// 一个**合法的、可自省的注册状态**，而不是「缺失」。
///
/// 见 `docs/16-extensibility.md` §2.4。
///
/// 加原语的完整流程：
///   1. 在 [_entries] 加一行
///   2. 若要真实现，把 handler 塞进 `implemented` map
///   3. 若涉及新权限，在 `permission.dart` 加一条 —— 会有测试提醒你
library;

import 'primitive_spec.dart';

/// 目录条目。
class _E {
  const _E(
    this.name,
    this.description, {
    this.permission,
    this.kind = PrimitiveKind.request,
    this.schema = const <String, dynamic>{},
    this.since = '0.1.0',
  });

  final String name;
  final String description;
  final String? permission;
  final PrimitiveKind kind;
  final Map<String, dynamic> schema;
  final String since;
}

/// 全部原语声明。
///
/// [implemented] 里给了 handler 的原语会被标为已实现，其余为占位。
List<PrimitiveSpec> standardPrimitiveCatalog({
  Map<String, PrimitiveHandler> implemented = const <String, PrimitiveHandler>{},
}) {
  return _entries.map((e) {
    final handler = implemented[e.name];
    if (handler == null) {
      return PrimitiveSpec.placeholder(
        name: e.name,
        description: e.description,
        permission: e.permission,
        kind: e.kind,
        paramsSchema: e.schema,
        since: e.since,
      );
    }
    return PrimitiveSpec(
      name: e.name,
      description: e.description,
      permission: e.permission,
      kind: e.kind,
      paramsSchema: e.schema,
      handler: handler,
      since: e.since,
    );
  }).toList(growable: false);
}

/// 一个布尔值类型的 JSON Schema 属性。
Map<String, dynamic> _num({num? min, num? max, String? desc}) => <String, dynamic>{
      'type': 'number',
      if (min != null) 'minimum': min,
      if (max != null) 'maximum': max,
      if (desc != null) 'description': desc,
    };

Map<String, dynamic> _str({String? desc, List<String>? enumValues, int? maxLength}) =>
    <String, dynamic>{
      'type': 'string',
      if (desc != null) 'description': desc,
      if (enumValues != null) 'enum': enumValues,
      if (maxLength != null) 'maxLength': maxLength,
    };

Map<String, dynamic> _obj(
  Map<String, dynamic> properties, {
  List<String> required = const <String>[],
}) =>
    <String, dynamic>{
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    };

/// 全部条目。按域名分组，与 `docs/05-primitives.md` 的表格顺序一致。
///
/// 用 `final` 而不是 `const`：部分条目的 schema 由 [_obj] / [_str] 这类辅助函数
/// 拼出来，而函数调用不能出现在常量表达式里。可读性比"是常量"更重要。
final List<_E> _entries = <_E>[
  // ───────────────────── 1. 文件系统 ─────────────────────
  _E('fs.list', '列出沙箱内文件',
      permission: 'fs.read',
      schema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string'},
          'recursive': <String, dynamic>{'type': 'boolean'},
          'pattern': <String, dynamic>{'type': 'string'},
        },
        'required': <String>[],
        'additionalProperties': false,
      }),
  _E('fs.read', '读取沙箱内的文本或二进制文件',
      permission: 'fs.read',
      schema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string', 'description': '相对沙箱根目录的路径'},
          'encoding': <String, dynamic>{'type': 'string', 'enum': <String>['utf8', 'base64']},
        },
        'required': <String>['path'],
        'additionalProperties': false,
      }),
  _E('fs.write', '写入沙箱内文件', permission: 'fs.write'),
  _E('fs.delete', '删除沙箱内文件', permission: 'fs.delete'),
  _E('fs.meta', '读取文件元信息', permission: 'fs.read'),
  _E('fs.mkdir', '创建沙箱内目录', permission: 'fs.write'),
  _E('fs.pickFile', '让用户选择文件并复制进沙箱', permission: 'fs.read'),
  _E('fs.saveFile', '把沙箱内文件导出给用户', permission: 'fs.write'),

  // ───────────────────── 2. 系统信息 ─────────────────────
  _E('sys.time', '获取当前时间',
      permission: 'sys.time',
      schema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'tz': <String, dynamic>{
            'type': 'string',
            'description': 'IANA 时区名，如 Asia/Shanghai。留空使用设备本地时区',
          },
        },
        'required': <String>[],
        'additionalProperties': false,
      }),
  // ───────────────────── 对话上下文 ─────────────────────
  //
  // 注意这些原语**不带会话 id** —— 语义是"用户现在看的那个对话"。
  // 见 HostChatContext 的说明。
  _E('chat.lastMessage', '取当前对话里最近一条消息',
      permission: 'chat.read',
      schema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'role': <String, dynamic>{
            'type': 'string',
            'enum': <String>['user', 'assistant', 'system'],
            'description': '只取该角色的最近一条；留空表示不限角色',
          },
        },
        'required': <String>[],
        'additionalProperties': false,
      }),
  _E('chat.info', '取当前对话的元信息（标题、条数）', permission: 'chat.read'),
  _E('agent.state.get', '读取当前智能体状态', permission: 'agent.state.read'),
  _E('agent.state.set', '更新当前智能体状态', permission: 'agent.state.write'),
  _E('agent.greet', '让当前智能体回应一次问候并记住这次互动', permission: 'agent.state.write'),
  _E('agent.model.chat', '使用当前智能体模型生成文本', permission: 'model.chat'),
  _E('surface.open', '打开插件 Surface', permission: 'ui.surface'),
  _E('surface.update', '更新插件 Surface 状态', permission: 'ui.surface'),
  _E('surface.close', '关闭插件 Surface', permission: 'ui.surface'),
  _E('memory.list', '读取当前智能体长期记忆', permission: 'memory.read'),
  _E('memory.add', '写入当前智能体长期记忆', permission: 'memory.write'),

  // ───────────────────── 插件配置 ─────────────────────
  //
  // **无需权限**：读写的都是插件自己在清单里声明的配置段，
  // 不含任何用户数据，不该让用户为它做决定。
  _E('config.get', '读取插件自己的配置项'),
  _E('config.set', '写入插件自己的配置项'),
  _E('config.all', '读取插件自己的全部配置'),

  _E('sys.battery', '电池状态', permission: 'sys.info'),
  _E('sys.network', '网络状态', permission: 'sys.info'),
  _E('sys.device', '设备信息', permission: 'sys.info'),
  _E('sys.locale', '语言与区域设置', permission: 'sys.info'),
  _E('sys.clipboard.read', '读取剪贴板', permission: 'sys.clipboard.read'),
  _E('sys.clipboard.write', '写入剪贴板',
      permission: 'sys.clipboard.write',
      schema: _obj(<String, dynamic>{'text': _str()}, required: <String>['text'])),
  _E('sys.vibrate', '震动', permission: 'sys.clipboard.write'),

  // ── 2.1 高敏感：打断用户当前操作（confirm 级） ──
  _E('sys.screen.pullBack', '把屏幕内容拉回（干预用户当前操作）',
      permission: 'sys.intervene', since: '0.6.0'),
  _E('sys.app.lock', '锁定指定应用（干预用户当前操作）',
      permission: 'sys.intervene',
      since: '0.6.0',
      schema: _obj(<String, dynamic>{'pkg': _str()}, required: <String>['pkg'])),
  _E('sys.dialog.popup', '弹出系统级弹窗（干预用户当前操作）',
      permission: 'sys.intervene',
      since: '0.6.0',
      schema: _obj(<String, dynamic>{
        'title': _str(),
        'content': _str(),
      }, required: <String>['title'])),
  _E('sys.overlay.show', '显示悬浮层', permission: 'sys.overlay', since: '0.6.0'),
  _E('sys.overlay.hide', '隐藏悬浮层', permission: 'sys.overlay', since: '0.6.0'),

  // ───────────────────── 3. 媒体 ─────────────────────
  _E('media.listPhotos', '列出相册照片', permission: 'media.read'),
  _E('media.getPhoto', '获取指定照片', permission: 'media.read'),
  _E('media.camera.capture', '拍照', permission: 'media.camera'),
  _E('media.camera.record', '录像', permission: 'media.camera'),
  _E('media.audio.record', '录音', permission: 'media.microphone'),
  _E('media.audio.play', '播放音频', permission: 'media.read'),
  _E('media.video.play', '播放视频', permission: 'media.read'),

  // ───────────────────── 4. 通讯 ─────────────────────
  _E('contact.list', '列出通讯录', permission: 'contact.read'),
  _E('contact.get', '读取某个联系人', permission: 'contact.read'),
  _E('contact.search', '搜索通讯录', permission: 'contact.read'),
  _E('sms.send', '发送短信（极为敏感，需每次确认）',
      permission: 'sms.send',
      schema: _obj(<String, dynamic>{'to': _str(), 'text': _str()},
          required: <String>['to', 'text'])),
  _E('sms.list', '读取短信', permission: 'sms.read'),
  _E('sms.listen', '监听新短信', permission: 'sms.read', kind: PrimitiveKind.event),
  _E('call.make', '拨打电话', permission: 'call.make'),
  _E('call.log', '读取通话记录', permission: 'call.make'),

  // ───────────────────── 5. 日历 ─────────────────────
  _E('calendar.list', '列出日历事件', permission: 'calendar.read'),
  _E('calendar.create', '创建日历事件', permission: 'calendar.write'),
  _E('calendar.update', '修改日历事件', permission: 'calendar.write'),

  // ───────────────────── 6. 应用 ─────────────────────
  _E('app.list', '列出已安装应用', permission: 'app.read'),
  _E('app.isInstalled', '检查应用是否已安装', permission: 'app.read'),
  _E('app.info', '读取应用信息', permission: 'app.read'),
  _E('app.open', '打开应用或跳转链接', permission: 'app.launch'),

  // ───────────────────── 7. 通知 ─────────────────────
  _E('notification.send', '发送系统通知', permission: 'notification.send'),
  _E('notification.cancel', '取消通知', permission: 'notification.send'),
  _E('notification.listen', '监听通知', permission: 'notification.read',
      kind: PrimitiveKind.event),

  // ───────────────────── 8. 定位 ─────────────────────
  _E('location.get', '获取当前位置', permission: 'location'),
  _E('location.watch', '持续监听位置', permission: 'location',
      kind: PrimitiveKind.event),
  _E('location.geocode', '地址与坐标互转', permission: 'location'),

  // ───────────────────── 9. 网络 ─────────────────────
  _E('net.request', '发起 HTTP 请求（须命中 manifest 域名白名单）',
      permission: 'net'),
  _E('net.download', '下载文件到沙箱', permission: 'net',
      kind: PrimitiveKind.task),
  _E('net.upload', '上传沙箱内文件', permission: 'net',
      kind: PrimitiveKind.task),
  _E('net.websocket', '建立 WebSocket 连接', permission: 'net',
      kind: PrimitiveKind.task),

  // ───────────────────── 10. UI ─────────────────────
  _E('ui.toast', '弹出一条轻提示',
      permission: 'ui',
      schema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'text': <String, dynamic>{'type': 'string', 'maxLength': 500},
          'durationMs': <String, dynamic>{'type': 'integer', 'minimum': 200, 'maximum': 10000},
          'kind': <String, dynamic>{'type': 'string', 'enum': <String>['info', 'success', 'warn', 'error']},
        },
        'required': <String>['text'],
        'additionalProperties': false,
      }),
  _E('ui.dialog', '弹出对话框', permission: 'ui'),
  _E('ui.sheet', '弹出底部面板', permission: 'ui'),
  _E('ui.overlay.show', '显示覆盖层', permission: 'ui.overlay'),
  _E('ui.overlay.hide', '隐藏覆盖层', permission: 'ui.overlay'),
  _E('ui.navigate', '打开插件的独立页面', permission: 'ui'),
  _E('ui.close', '关闭当前页面', permission: 'ui'),
  _E('ui.setTitle', '设置容器标题', permission: 'ui'),
  _E('ui.setBadge', '设置角标', permission: 'ui'),

  // ───────────────────── 11. 存储（无需权限） ─────────────────────
  _E('state.get', '读取插件私有键值'),
  _E('state.set', '写入插件私有键值'),
  _E('state.delete', '删除插件私有键值'),
  _E('state.list', '列出插件私有键值'),

  // ───────────────────── 12. 加密（无需权限） ─────────────────────
  _E('crypto.hash', '计算哈希'),
  _E('crypto.random', '生成随机数'),
  _E('crypto.encrypt', '加密'),
  _E('crypto.decrypt', '解密'),

  // ───────────────────── 13. 无障碍（confirm 级） ─────────────────────
  _E('a11y.find', '在屏幕上查找元素', permission: 'a11y'),
  _E('a11y.click', '点击屏幕元素', permission: 'a11y'),
  _E('a11y.setText', '向输入框写入文本', permission: 'a11y'),
  _E('a11y.scroll', '滚动屏幕', permission: 'a11y'),
  _E('a11y.screenshot', '截取无障碍树', permission: 'a11y'),

  // ───────────────────── 14. 截屏（confirm 级） ─────────────────────
  _E('screen.capture', '截屏', permission: 'screen.capture'),
  _E('screen.record', '录屏', permission: 'screen.record',
      kind: PrimitiveKind.task),
  _E('screen.analyze', '让视觉模型分析屏幕内容', permission: 'screen.capture'),

  // ───────────────────── 15. 模型（走宿主网关） ─────────────────────
  _E('model.chat', '调用 AI 模型（消耗用户点数；插件拿不到任何 Key）',
      permission: 'model.chat',
      schema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'messages': <String, dynamic>{'type': 'array'},
          'model': <String, dynamic>{
            'type': 'string',
            'description': '逻辑模型名（default / fast / smart），不是上游真实模型名',
          },
          'temperature': <String, dynamic>{'type': 'number', 'minimum': 0, 'maximum': 2},
          'stream': <String, dynamic>{'type': 'boolean'},
        },
        'required': <String>['messages'],
        'additionalProperties': false,
      }),
  _E('model.embed', '文本向量化', permission: 'model.chat'),
  _E('model.vision', '图片理解', permission: 'model.chat'),

  // ───────────────────── 16. 工具 ─────────────────────
  _E('tool.list', '列出可用工具（含其他插件提供的）'),
  _E('tool.call', '调用工具（含其他插件提供的）'),

  // ───────────────────── 17. 事件 ─────────────────────
  _E('event.on', '订阅事件'),
  _E('event.emit', '发出事件（仅限自己的命名空间）'),
  _E('event.off', '取消订阅'),

  // ───────────────────── 18. 日志 ─────────────────────
  _E('log.info', '写信息日志'),
  _E('log.warn', '写警告日志'),
  _E('log.error', '写错误日志'),

  // ───────────────────── 19. MCP（预留） ─────────────────────
  _E('mcp.serve', '暴露本地 MCP Server（预留）', permission: 'mcp'),
  _E('mcp.stop', '停止本地 MCP Server（预留）', permission: 'mcp'),
  _E('mcp.status', '查询本地 MCP Server 状态（预留）', permission: 'mcp'),

  // ───────────────────── 20. 上下文注入 ─────────────────────
  _E('context.inject', '往 system prompt 注入一段文本',
      permission: 'context.write',
      schema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'text': <String, dynamic>{'type': 'string', 'maxLength': 8192},
          'position': <String, dynamic>{'type': 'string', 'enum': <String>['prepend', 'append']},
          'priority': <String, dynamic>{'type': 'integer'},
          'ttlMs': <String, dynamic>{'type': 'integer', 'minimum': 1000},
          'scope': <String, dynamic>{'type': 'string', 'enum': <String>['once', 'session', 'persistent']},
          'tag': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['text'],
        'additionalProperties': false,
      }),
  _E('context.append', '往对话末尾追加一条消息',
      permission: 'context.write',
      schema: _obj(<String, dynamic>{
        'role': _str(enumValues: <String>['user', 'assistant', 'system']),
        'content': _str(),
      }, required: <String>['role', 'content'])),
  _E('context.onBuild', '注册上下文组装钩子', permission: 'context.hook'),
  _E('context.onBeforeModel', '注册调模型前的钩子', permission: 'context.hook'),
  _E('context.onAfterModel', '注册模型返回后的钩子', permission: 'context.hook'),

  // ───────────────────── 21. 消息操作 ─────────────────────
  _E('message.get', '读取消息', permission: 'message.read'),
  _E('message.update', '修改已有消息', permission: 'message.write'),
  _E('message.append', '往已有消息追加内容', permission: 'message.write'),
  _E('message.send', '主动发消息（会触发模型调用并消耗点数）',
      permission: 'message.send',
      schema: _obj(<String, dynamic>{
        'content': _str(maxLength: 8000),
        'role': _str(enumValues: <String>['assistant', 'system']),
      }, required: <String>['content'])),
  _E('message.delete', '删除消息', permission: 'message.write'),

  // ───────────────────── 22. 调度 ─────────────────────
  _E('schedule.once', '延迟执行一次',
      permission: 'schedule',
      schema: _obj(<String, dynamic>{
        'delayMs': _num(min: 1000),
        'handler': _str(),
        'tag': _str(),
      }, required: <String>['delayMs', 'handler'])),
  _E('schedule.interval', '周期执行',
      permission: 'schedule',
      schema: _obj(<String, dynamic>{
        'periodMs': _num(min: 60000, desc: '最短 60 秒。需要更频繁请用事件，不要轮询'),
        'handler': _str(),
        'tag': _str(),
        'immediate': <String, dynamic>{'type': 'boolean'},
      }, required: <String>['periodMs', 'handler'])),
  _E('schedule.cancel', '取消任务', permission: 'schedule'),
  _E('schedule.list', '列出任务', permission: 'schedule'),

  // ───────────────────── 23. 自省（无需权限） ─────────────────────
  _E('host.capabilities', '查询宿主综合能力（原语、钩子、插槽）'),
  _E('primitive.list', '列出宿主支持的全部原语'),
  _E('hook.phases', '列出宿主支持的钩子时机'),
  _E('slot.list', '列出宿主预埋的 UI 插槽'),
];
