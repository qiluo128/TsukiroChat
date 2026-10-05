/// Demo 阶段真正实现的四个原语 + 四个自省原语。
///
/// 选这四条的 deliberately 理由：它们分别命中
/// 「工具调用」「宿主 UI 副作用」「模型代理」「沙箱文件」四条独立链路。
/// 四个都通，说明原语层的**路由、权限、审计、沙箱**四套机制都工作正常。
///
/// 四个自省原语实现成本几乎为零，但它们是"可扩展性"的落地关键 ——
/// 没有它们，插件只能靠版本号猜宿主支持什么（见 `docs/16-extensibility.md` §6）。
library;

import 'dart:convert';

import '../agent/chat_message.dart';
import '../common/errors.dart';
import '../hook/hook_bus.dart';
import '../sandbox/path_guard.dart';
import 'host_services.dart';
import 'primitive_registry.dart';
import 'primitive_spec.dart';

/// 把 handler 塞进 `standardPrimitiveCatalog(implemented: demoPrimitiveHandlers)` 即可。
const Map<String, PrimitiveHandler> demoPrimitiveHandlers = <String, PrimitiveHandler>{
  'sys.time': handleSysTime,
  'chat.lastMessage': handleChatLastMessage,
  'chat.info': handleChatInfo,
  'config.get': handleConfigGet,
  'config.set': handleConfigSet,
  'config.all': handleConfigAll,
  'ui.dialog': handleUiDialog,
  'ui.toast': handleUiToast,
  'fs.read': handleFsRead,
  'model.chat': handleModelChat,
  'primitive.list': handlePrimitiveList,
  'hook.phases': handleHookPhases,
  'host.capabilities': handleHostCapabilities,
};

// ─────────────────────────── sys.time ───────────────────────────

/// 获取当前时间。
///
/// 它是**唯一一个即使无网络也能验证工具调用链路**的原语，所以选它做第一个测试插件。
Future<Object?> handleSysTime(PrimitiveCall call) async {
  final clock = call.require<HostClock>();
  final requested = call.args['tz'] as String?;

  DateTime moment;
  String usedTz;
  if (requested == null || requested.isEmpty || requested == clock.timezoneName) {
    moment = clock.now();
    usedTz = clock.timezoneName;
  } else {
    final inZone = clock.nowIn(requested);
    if (inZone == null) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '宿主不认识时区 "$requested"。请传 IANA 时区名（如 Asia/Shanghai），或留空使用本地时区',
        details: <String, dynamic>{'tz': requested, 'local': clock.timezoneName},
      );
    }
    moment = inZone;
    usedTz = requested;
  }

  final local = requested == null ? moment : moment;
  return <String, dynamic>{
    'iso': local.toIso8601String(),
    'epochMs': local.millisecondsSinceEpoch,
    'human': _humanTime(local),
    'tz': usedTz,
    'weekday': _weekday(local.weekday),
  };
}

String _humanTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}年${t.month}月${t.day}日 ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _weekday(int weekday) =>
    const <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday - 1];

// ─────────────────────────── fs.read ───────────────────────────

/// 读取沙箱内文件。
///
/// 这条链路验证的是**沙箱约束**：路径由 `SandboxPathGuard` 解析，
/// `../../` 之类的穿越会被拦成 `SANDBOX_VIOLATION`。
Future<Object?> handleFsRead(PrimitiveCall call) async {
  final sandbox = call.require<SandboxProvider>();
  final files = call.require<HostFiles>();

  final root = sandbox.dataRootFor(call.pluginId);
  if (root == null) {
    throw TsukiroException(
      TsukiroErrorCode.ioError,
      '插件 ${call.pluginId} 的沙箱目录不存在',
      details: <String, dynamic>{'pluginId': call.pluginId},
    );
  }

  final rawPath = call.args['path'] as String?;
  if (rawPath == null || rawPath.isEmpty) {
    throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 path 参数');
  }

  // 关键：路径必须过守门人。原语实现**不允许自己拼路径**。
  final guard = SandboxPathGuard(root);
  final absolute = guard.resolveAndVerify(rawPath);

  if (!await files.exists(absolute)) {
    throw TsukiroException(
      TsukiroErrorCode.notFound,
      '沙箱内不存在文件 "$rawPath"',
      details: <String, dynamic>{'path': rawPath},
    );
  }

  final encoding = call.args['encoding'] as String? ?? 'utf8';
  if (encoding == 'base64') {
    final bytes = await files.readBytes(absolute);
    return <String, dynamic>{
      'base64': base64Encode(bytes),
      'path': rawPath,
      'bytes': bytes.length,
    };
  }

  final text = await files.readText(absolute);
  return <String, dynamic>{
    'text': text,
    'path': rawPath,
    'bytes': utf8.encode(text).length,
  };
}

// ─────────────────────────── ui.toast ───────────────────────────

/// 弹一条轻提示。验证的是「宿主 UI 副作用」这条链路。
Future<Object?> handleUiToast(PrimitiveCall call) async {
  final ui = call.require<HostUi>();
  final text = call.args['text'] as String?;
  if (text == null || text.isEmpty) {
    throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 text 参数');
  }

  final durationMs = call.args['durationMs'] as int? ?? 2000;
  final kind = call.args['kind'] as String? ?? 'info';

  ui.toast(
    text,
    duration: Duration(milliseconds: durationMs),
    kind: kind,
  );
  return <String, dynamic>{'ok': true};
}

// ─────────────────────────── model.chat ───────────────────────────

/// 调用 AI 模型。
///
/// **这条链路证明了插件拿不到 Key**：参数 schema 里根本没有 `apiKey` / `baseUrl` /
/// `headers`，而且 `additionalProperties: false` 会让多传字段直接报错。
/// 凭据只存在于宿主注入的 [ModelGateway] 里。
Future<Object?> handleModelChat(PrimitiveCall call) async {
  final gateway = call.require<ModelGateway>();

  final rawMessages = call.args['messages'];
  if (rawMessages is! List || rawMessages.isEmpty) {
    throw TsukiroException(
      TsukiroErrorCode.invalidArgs,
      'messages 必须是非空数组',
      details: <String, dynamic>{'messagesType': rawMessages.runtimeType.toString()},
    );
  }

  final messages = <ChatMessage>[];
  for (var i = 0; i < rawMessages.length; i++) {
    final item = rawMessages[i];
    if (item is! Map) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'messages[$i] 必须是对象，实际是 ${item.runtimeType}',
      );
    }
    final role = ChatRole.parse(item['role']?.toString());
    final content = item['content']?.toString();
    if (content == null) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'messages[$i] 缺少 content',
      );
    }
    messages.add(ChatMessage(role: role, content: content));
  }

  final wantsStream = call.args['stream'] == true;

  final reply = await gateway.complete(ModelRequest(
    messages: messages,
    model: call.args['model'] as String?,
    temperature: (call.args['temperature'] as num?)?.toDouble(),
    stream: wantsStream,
  ));

  return <String, dynamic>{
    'text': reply.text,
    'toolCalls': reply.toolCalls.map((t) => t.toJson()).toList(growable: false),
    'usage': <String, dynamic>{
      'prompt': reply.promptTokens,
      'completion': reply.completionTokens,
    },
    'model': gateway.activeModel,
  };
}

// ─────────────────────────── 自省 ───────────────────────────

/// 列出宿主支持的全部原语。
Future<Object?> handlePrimitiveList(PrimitiveCall call) async {
  final registry = call.require<PrimitiveRegistry>();
  final onlyImplemented = call.args['implementedOnly'] == true;

  final items = registry.all
      .where((s) => !onlyImplemented || s.implemented)
      .map((s) => s.describe())
      .toList(growable: false);

  return <String, dynamic>{
    'total': registry.length,
    'implemented': registry.implementedCount,
    'primitives': items,
  };
}

/// 列出宿主支持的钩子时机。
Future<Object?> handleHookPhases(PrimitiveCall call) async {
  final bus = call.service<HookBus>();
  if (bus == null) {
    // 宿主没装钩子总线时，至少把相位清单给出来
    return <String, dynamic>{
      'phases': HookPhase.values.map((p) => p.name).toList(growable: false),
      'registered': <String, int>{},
    };
  }
  return bus.describe();
}

/// 综合能力清单 —— 插件用它决定「用高级能力」还是「降级实现」。
Future<Object?> handleHostCapabilities(PrimitiveCall call) async {
  final registry = call.require<PrimitiveRegistry>();
  final bus = call.service<HookBus>();

  return <String, dynamic>{
    'hostApi': '1.0.0',
    'manifestVersion': 1,
    'bridgeProtocolVersion': 1,
    'primitives': <String, dynamic>{
      for (final s in registry.all)
        s.name: <String, dynamic>{
          'implemented': s.implemented,
          'permission': s.permission,
          'kind': s.kind.name,
        },
    },
    'hookPhases': HookPhase.values.map((p) => p.name).toList(growable: false),
    'hooksRegistered': bus?.length ?? 0,
  };
}

// ─────────────────────────── chat.* ───────────────────────────

/// 取当前对话里最近一条消息。
///
/// **必须通过 [HostChatContext] 拿"当前对话"**，而不是让插件传会话 id ——
/// 插件根本不知道宿主界面上开着哪个对话。
Future<Object?> handleChatLastMessage(PrimitiveCall call) async {
  final ctx = call.require<HostChatContext>();

  final conversationId = ctx.activeConversationId;
  if (conversationId == null || conversationId.isEmpty) {
    // 明确区分"没在对话里"和"对话里没消息" ——
    // 前者用户可以切回去解决，后者只能换个说法
    throw TsukiroException(
      TsukiroErrorCode.invalidArgs,
      '用户当前不在任何对话里，取不到消息',
    );
  }

  final role = call.args['role'] as String?;
  if (role != null && role.isNotEmpty) {
    const allowed = <String>{'user', 'assistant', 'system'};
    if (!allowed.contains(role)) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'role 只能是 user / assistant / system，收到 "$role"',
      );
    }
  }

  final msg = await ctx.lastMessage(
    conversationId,
    role: (role == null || role.isEmpty) ? null : role,
  );
  // 返回 null 而不是抛异常：**"没有消息"是正常结果**，
  // 插件会据此提示用户"还没有可翻译的消息"
  return msg;
}

/// 当前对话的元信息。
Future<Object?> handleChatInfo(PrimitiveCall call) async {
  final ctx = call.require<HostChatContext>();
  final id = ctx.activeConversationId;
  return <String, dynamic>{
    'active': id != null,
    'conversationId': id,
  };
}

// ─────────────────────────── config.* ───────────────────────────

/// 读插件自己的配置项。
Future<Object?> handleConfigGet(PrimitiveCall call) async {
  final config = call.require<HostPluginConfig>();
  final key = call.args['key'] as String?;
  if (key == null || key.isEmpty) {
    throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 key 参数');
  }
  final value = await config.get(call.pluginId, key, fallback: call.args['default']);
  return <String, dynamic>{'key': key, 'value': value};
}

/// 写插件自己的配置项。
Future<Object?> handleConfigSet(PrimitiveCall call) async {
  final config = call.require<HostPluginConfig>();
  final key = call.args['key'] as String?;
  if (key == null || key.isEmpty) {
    throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 key 参数');
  }
  if (!call.args.containsKey('value')) {
    throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 value 参数');
  }
  await config.set(call.pluginId, key, call.args['value']);
  return <String, dynamic>{'ok': true, 'key': key};
}

/// 读插件全部配置。
Future<Object?> handleConfigAll(PrimitiveCall call) async {
  final config = call.require<HostPluginConfig>();
  return config.all(call.pluginId);
}

// ─────────────────────────── ui.dialog ───────────────────────────

/// 弹对话框，返回被点按钮的 id。
Future<Object?> handleUiDialog(PrimitiveCall call) async {
  final ui = call.require<HostUi>();
  final title = call.args['title'] as String?;
  if (title == null || title.isEmpty) {
    throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 title 参数');
  }

  final rawButtons = call.args['buttons'];
  final buttons = <UiButton>[];
  if (rawButtons is List) {
    for (final b in rawButtons) {
      if (b is! Map) continue;
      final id = b['id']?.toString();
      final label = b['label']?.toString();
      if (id == null || label == null) continue;
      buttons.add(UiButton(id, label, style: b['style']?.toString() ?? 'default'));
    }
  }

  final clicked = await ui.dialog(
    title: title,
    content: call.args['content'] as String?,
    buttons: buttons,
  );
  return <String, dynamic>{'clicked': clicked};
}
