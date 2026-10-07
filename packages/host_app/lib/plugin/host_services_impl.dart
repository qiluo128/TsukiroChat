/// 宿主对内核 [HostClock] / [HostUi] / [HostFiles] 等接口的实现。
///
/// ## 为什么这个文件之前不存在（真因）
///
/// 内核把"宿主能力"设计成**按类型注入的服务**（`call.require<HostClock>()`），
/// 这是好的解耦 —— 内核不认识任何具体的宿主实现。
///
/// 但我在 `plugin_providers.dart` 里只写了：
///
/// ```dart
/// final registry = PrimitiveRegistry(gatekeeper: ...);
/// registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
/// ```
///
/// **一个服务都没注入。** 于是所有需要宿主服务的原语（`sys.time`、`ui.toast`、
/// `fs.read`、`model.chat` …）必然抛「宿主未注入服务 …」——
/// 而链路的其他部分（Bridge、权限、工具调用）全都是通的，
/// 表现就是"插件跑起来了、工具调到了、但一执行就报错"。
library;

import 'package:flutter/material.dart';
import 'package:model_gateway/model_gateway.dart';
import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../services/model_diagnostics.dart';
import '../services/memory_providers.dart';
import '../services/utility_model.dart';
import '../services/agent_context.dart';
import 'app_keys.dart';

/// 全局 messenger key。
///
/// [HostUi.toast] 是在 widget 树之外被调用的（可能来自 WebView 的回调），
/// 拿不到 `BuildContext`，只能靠这个全局入口弹提示。

// ═══════════════════════════ 时钟 ═══════════════════════════

/// 设备时钟。
class AppHostClock implements HostClock {
  const AppHostClock();

  @override
  DateTime now() => DateTime.now();

  @override
  String get timezoneName => _localZoneName();

  @override
  DateTime? nowIn(String timezoneName) {
    final offset = _offsets[timezoneName];
    if (offset == null) return null;
    // DateTime.now() 是本地时间；先转到 UTC 再按目标偏移换算。
    // 用 `isUtc: false` + 手动偏移，因为 Dart 没有"任意时区"的原生支持
    // （那要 timezone 包 + 时区数据库，约 1 MB）。
    // 对"现在几点"这个用途，一张常见时区表就够了。
    final utc = DateTime.now().toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
      utc.millisecond,
    ).add(Duration(minutes: offset));
  }

  /// 设备本地时区名。
  ///
  /// Dart 拿不到 IANA 名（`DateTime.now().timeZoneName` 返回的是缩写如 "CST"，
  /// 而且各平台不一致）。所以从系统时区偏移反推一个最接近的常见时区名 ——
  /// **对用户来说"Asia/Shanghai"比"CST"有用得多**，后者还有歧义
  /// （CST 也可能是美国中部时间）。
  String _localZoneName() {
    final offset = DateTime.now().timeZoneOffset.inMinutes;
    for (final entry in _offsets.entries) {
      if (entry.value == offset) return entry.key;
    }
    return 'UTC${offset >= 0 ? '+' : '-'}'
        '${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:'
        '${(offset.abs() % 60).toString().padLeft(2, '0')}';
  }

  /// 常见 IANA 时区 → UTC 偏移（分钟）。
  ///
  /// **不含夏令时** —— 有夏令时的地区在夏令时期间会差一小时。
  /// 这是刻意的取舍：完整时区库要 1 MB 和一份会过期的数据，
  /// 而"现在几点"的场景里错一小时是可接受的，
  /// 装不上（体积翻倍）才是不可接受的。真有需要时再引 `timezone` 包。
  static const Map<String, int> _offsets = <String, int>{
    'Pacific/Honolulu': -600,
    'America/Anchorage': -540,
    'America/Los_Angeles': -480,
    'America/Denver': -420,
    'America/Chicago': -360,
    'America/New_York': -300,
    'America/Sao_Paulo': -180,
    'Atlantic/Azores': -60,
    'UTC': 0,
    'Europe/London': 0,
    'Europe/Paris': 60,
    'Europe/Berlin': 60,
    'Europe/Moscow': 180,
    'Asia/Dubai': 240,
    'Asia/Karachi': 300,
    'Asia/Kolkata': 330,
    'Asia/Dhaka': 360,
    'Asia/Bangkok': 420,
    'Asia/Shanghai': 480,
    'Asia/Hong_Kong': 480,
    'Asia/Taipei': 480,
    'Asia/Singapore': 480,
    'Asia/Kuala_Lumpur': 480,
    'Australia/Perth': 480,
    'Asia/Seoul': 540,
    'Asia/Tokyo': 540,
    'Australia/Adelaide': 570,
    'Australia/Sydney': 600,
    'Pacific/Auckland': 720,
  };
}

// ═══════════════════════════ 界面 ═══════════════════════════

/// 把插件的 UI 请求接到宿主的界面上。
class AppHostUi implements HostUi {
  const AppHostUi();

  @override
  void toast(String text, {Duration duration = const Duration(seconds: 3), String kind = 'info'}) {
    final messenger = appMessengerKey.currentState;
    if (messenger == null) {
      // 宿主界面还没准备好（比如插件在启动阶段就弹提示）。
      // **不抛异常** —— 一条提示弹不出来，不该让插件的整个操作失败。
      debugPrint('[plugin:ui] toast 丢弃（messenger 未就绪）：$text');
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: duration,
    ));
  }

  @override
  Future<String?> dialog({
    required String title,
    String? content,
    List<UiButton> buttons = const <UiButton>[],
  }) async {
    final navigator = appNavigatorKey.currentState;
    final context = appNavigatorKey.currentContext;
    if (navigator == null || context == null) return null;

    // 插件没给按钮时给一个"知道了"，否则对话框关不掉
    final effective = buttons.isEmpty
        ? const <UiButton>[UiButton('ok', '知道了')]
        : buttons;

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: content == null ? null : Text(content),
        actions: <Widget>[
          for (final b in effective)
            TextButton(
              onPressed: () => Navigator.pop(ctx, b.id),
              child: Text(b.label),
            ),
        ],
      ),
    );
  }

  @override
  Future<bool> navigate(String pageId, {Map<String, dynamic>? params}) async {
    // 插件独立页面（`provides.pages`）需要 WebView 弹层，
    // 属于后续工作。**明确返回 false**，而不是假装成功 ——
    // 插件据此可以降级，而不是卡在"以为打开了"的状态。
    debugPrint('[plugin:ui] 插件页面 $pageId 尚未支持');
    return false;
  }

  @override
  Future<void> close() async {
    final navigator = appNavigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  Future<void> setTitle(String title) async {
    // 宿主只有插件页面才有"容器标题"的概念，而插件页面还没做
    debugPrint('[plugin:ui] setTitle("$title") 暂不支持');
  }
}

// ═══════════════════════════ 装配 ═══════════════════════════

/// 组装宿主服务注册表。
///
/// [primitiveRegistry] 与 [hookBus] 也注册进去了 —— 因为
/// `primitive.list` / `host.capabilities` / `hook.phases` 这三个原语
/// 要向宿主**自省**，它们需要的就是这两个对象本身。
///
/// 没注册的服务（`HostFiles` / `SandboxProvider` / `ModelGateway`）
/// 会让对应原语抛出明确的「宿主未注入服务 X」——
/// 这是**如实报错**，比返回假数据好：插件能据此知道宿主还不支持，
/// 而不是拿到一个看起来成功的空结果。
ServiceRegistry buildHostServices({
  required PrimitiveRegistry primitiveRegistry,
  required HookBus hookBus,
  ModelGateway? modelGateway,
}) {
  final services = ServiceRegistry();
  services
    ..put<HostClock>(const AppHostClock())
    ..put<HostUi>(const AppHostUi())
    ..put<PrimitiveRegistry>(primitiveRegistry)
    ..put<HookBus>(hookBus);
  if (modelGateway != null) services.put<ModelGateway>(modelGateway);
  return services;
}

// ═══════════════════════════ 对话上下文 ═══════════════════════════

/// 当前打开的对话。
///
/// 由聊天页在进入/退出时设置。插件调 `chat.lastMessage()` 时**不带会话 id**，
/// 所以宿主必须知道"用户现在看的是哪个对话"。
class AppChatContext implements HostChatContext {
  AppChatContext({required this.repos});

  final Future<Repos> repos;

  /// 当前打开的智能体/对话，由宿主页面维护。
  String? activeAgentId;

  /// 当前打开的对话 id。聊天页负责维护。
  @override
  String? activeConversationId;

  @override
  Future<Map<String, dynamic>?> lastMessage(
    String conversationId, {
    String? role,
  }) async {
    final r = await repos;
    // 多取几条再按角色筛 —— 存储层没有"按角色取最后一条"的接口，
    // 而这里最多扫 40 条，代价可以忽略
    final messages = await r.messages.list(conversationId, limit: 40);

    for (final m in messages.reversed) {
      if (role != null && role.isNotEmpty && m.role.name != role) continue;
      final text = m.content;
      if (text == null || text.trim().isEmpty) continue;
      return <String, dynamic>{
        'id': m.id,
        'role': m.role.name,
        'text': text,
        'createdAt': m.createdAt.toIso8601String(),
      };
    }
    return null;
  }
}

// ═══════════════════════════ 智能体状态与记忆 ═══════════════════════════

class AppAgentState implements HostAgentState {
  AppAgentState({
    required this.repos,
    required this.chat,
    required this.utility,
    required this.agentGateway,
    this.surfaceController,
    this.onChanged,
    this.memory,
  });

  /// 记忆实现注册表。**外部记忆插件通过它接管记忆。**
  final MemoryProviderRegistry? memory;

  /// 插件改了智能体状态后回调，用来通知界面重建。
  ///
  /// **没有它，状态面板就永远停在第一次读到的值上** ——
  /// 插件改了库，但宿主界面不知道要重画（用户反馈的「不更新」）。
  final void Function(String pluginId)? onChanged;

  final Future<Repos> repos;
  final AppChatContext chat;
  final UtilityModelService utility;
  final HttpModelGateway? Function(String agentId) agentGateway;
  final HostSurfaceController? surfaceController;


  @override
  String? get activeAgentId => chat.activeAgentId;

  @override
  String? get activeConversationId => chat.activeConversationId;

  String _stateKey(String pluginId) => 'plugin.agent_state.$pluginId.${chat.activeAgentId}';

  Future<void> _requireContext() async {
    if (chat.activeAgentId == null || chat.activeAgentId!.isEmpty) {
      throw StateError('当前不在智能体页面');
    }
  }

  /// 当前生效的记忆实现。
  ///
  /// 按 `agent.memory.providerPluginId` 解析；没配就是内置实现。
  /// **找不到时退到内置** —— 见 MemoryProviderRegistry.resolve 的说明：
  /// 插件被卸载/停用时不该让用户打不开对话。
  ///
  /// **这是外部记忆插件接入的缝。** 插件注册进注册表之后，
  /// 这里与 AgentContextBuilder 都会自动走它，上层一行不用改。
  Future<MemoryProvider> _memoryProvider() async {
    final registry = memory;
    if (registry == null) return BuiltinMemoryProvider(repos);

    final agentId = chat.activeAgentId;
    if (agentId == null || agentId.isEmpty) return registry.builtin;

    final agent = await (await repos).agents.get(agentId);
    return registry.resolve(agent?.memory.providerPluginId);
  }

  @override
  Future<Map<String, dynamic>> getState(String pluginId) async {
    await _requireContext();
    final raw = await (await repos).settings.get(_stateKey(pluginId));
    if (raw == null || raw.isEmpty) return <String, dynamic>{'mood': 50, 'opinion': '还在了解中'};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  @override
  Future<Map<String, dynamic>> setState(String pluginId, Map<String, dynamic> patch) async {
    await _requireContext();
    final current = await getState(pluginId);
    final next = <String, dynamic>{...current};
    if (patch.containsKey('mood')) {
      final mood = (patch['mood'] as num?)?.toInt();
      if (mood != null) next['mood'] = mood.clamp(0, 100);
    }
    if (patch.containsKey('opinion')) next['opinion'] = '${patch['opinion']}'.trim();
    if (patch.containsKey('lastGreeting')) next['lastGreeting'] = '${patch['lastGreeting']}';
    await (await repos).settings.set(_stateKey(pluginId), jsonEncode(next));
    // 通知界面重建 —— 少了这一步，插件改了状态但面板永远显示旧值
    onChanged?.call(pluginId);
    return next;
  }

  @override
  Future<String> greet(String pluginId) async {
    await _requireContext();
    final agent = await (await repos).agents.get(chat.activeAgentId!);
    if (agent == null) throw StateError('当前智能体不存在');
    final state = await getState(pluginId);
    // **人设不再写进这里。**
    //
    // 它已经通过 AgentContextBuilder 进了 system prompt；
    // 在 user 消息里再抄一遍，会让模型以为"人设"是这一轮的新指令，
    // 反而压过记忆和对话历史 —— 表现就是「只有人设」。
    final prompt = '用户刚刚向你打招呼。请结合你的角色、你们之前的对话和当前状态，'
        '简短回应一句自然的话。'
        '\n当前心情：${state['mood']} / 100；你对用户的看法：${state['opinion']}';
    final gateway = agentGateway(chat.activeAgentId!);
    if (gateway == null) throw StateError('当前智能体没有可用模型');
    final taskMessages = <ChatMessage>[
      ChatMessage.system('只输出自然的简短回应。'),
      ChatMessage.user(prompt),
    ];
    final messages = await AgentContextBuilder(await repos, memory: memory).messages(
      agent,
      taskMessages,
      conversationId: chat.activeConversationId,
      // 带对话历史 —— 用户反馈「打招呼像是第一次见面」就是这里缺的
      includeHistory: true,
    );
    // **预算不能给小。**
    //
    // 推理模型的思维链**也计入 max_tokens**（docs/17 实测）。
    // 原先这里是 120 —— 思维链一写就吃光，正文为空，
    // 而且请求很快返回（因为产出本来就少）。
    // 表现就是"等待时间明显比正常短 + 说返回了空内容"。
    //
    // 1200 是够写一段两三百字回复、再留出思维链余量的量。
    // 要更省的话应该做成"思维链预算"的配置项，而不是把总预算压小。
    const budget = 1200;
    final reply = await gateway.complete(ModelRequest(
      messages: messages,
      maxTokens: budget,
    ));
    if (isEmptyReply(reply)) {
      // 空正文有好几种原因（思维链吃光预算 / finish_reason=length /
      // 模型真回了个空串），报错要说清是哪一种 ——
      // 全部糊成"返回了空内容"的话，用户只会反复重试，
      // 而重试永远不会让预算变大。
      throw StateError(describeEmptyReply(
        reply,
        where: '打招呼',
        requestedMaxTokens: budget,
      ));
    }
    final replyText = reply.text.trim();
    final next = await setState(pluginId, <String, dynamic>{
      'lastGreeting': replyText,
      'mood': ((state['mood'] as num?)?.toInt() ?? 50) + 2,
      'opinion': '愿意主动打招呼，关系正在变熟',
    });
    await addMemory(pluginId,
        content: '用户主动向我打招呼，我回应：“$replyText”',
        kind: 'greeting',
        metadata: <String, dynamic>{'state': next});
    return reply.text.trim();
  }

  @override
  Future<Map<String, dynamic>> modelChat(
    String pluginId,
    List<Map<String, dynamic>> messages,
  ) async {
    await _requireContext();
    final gateway = agentGateway(chat.activeAgentId!);
    if (gateway == null) throw StateError('当前智能体没有可用模型');
    final taskMessages = messages
        .map((message) => ChatMessage(
              role: ChatRole.parse(message['role']?.toString()),
              content: message['content']?.toString(),
            ))
        .toList(growable: false);
    final agent = await (await repos).agents.get(chat.activeAgentId!);
    if (agent == null) throw StateError('当前智能体不存在');
    final contextualMessages =
        await AgentContextBuilder(await repos, memory: memory).messages(
      agent,
      taskMessages,
      conversationId: chat.activeConversationId,
      includeHistory: true,
    );
    // 这里**不设 maxTokens** —— 让上游用自己的默认值。
    //
    // 插件的 agent.model.chat 是要"真的说话"的（石头剪刀布的赛评、
    // 翻译结果…），压小预算就会重演 greet 那个问题。
    final reply = await gateway.complete(ModelRequest(messages: contextualMessages));
    if (isEmptyReply(reply)) {
      throw StateError(describeEmptyReply(reply, where: 'agent.model.chat'));
    }
    return <String, dynamic>{'text': reply.text, 'model': gateway.activeModel};
  }

  @override
  Future<String> appendAssistantMessage(String pluginId, String content) async {
    await _requireContext();
    final conversationId = chat.activeConversationId;
    if (conversationId == null || conversationId.isEmpty) {
      throw StateError('当前不在对话中，无法追加评价');
    }
    final reposValue = await repos;
    final id = newId('m');
    final seq = await reposValue.messages.nextSeq(conversationId);
    await reposValue.messages.insert(StoredChatMessage(
      id: id,
      conversationId: conversationId,
      role: ChatRole.assistant,
      content: content.trim(),
      seq: seq,
      createdAt: DateTime.now(),
      metadata: <String, dynamic>{'pluginId': pluginId, 'kind': 'plugin_evaluation'},
    ));
    return id;
  }

  @override
  Future<bool> openSurface(String pluginId, String surfaceId) async {
    await _requireContext();
    return surfaceController?.open(pluginId, surfaceId) ?? false;
  }

  @override
  Future<bool> updateSurface(String pluginId, String surfaceId, Map<String, dynamic> state) async {
    await _requireContext();
    return surfaceController?.update(pluginId, surfaceId, state) ?? false;
  }

  @override
  Future<bool> closeSurface(String pluginId, String surfaceId) async =>
      surfaceController?.close(pluginId, surfaceId) ?? false;

  @override
  Future<bool> surfaceEvent(String pluginId, String surfaceId, Map<String, dynamic> event) async =>
      surfaceController?.event(pluginId, surfaceId, event) ?? false;

  @override
  Future<Map<String, dynamic>?> surfaceState(String pluginId, String surfaceId) async => null;

  @override
  Future<List<Map<String, dynamic>>> listMemories(
    String pluginId, {
    String? keyword,
    int limit = 20,
  }) async {
    await _requireContext();
    final entries = keyword == null || keyword.trim().isEmpty
        // **走注册表，不直接读表。**
        //
        // 否则插件版记忆实现接管之后，`memory.list` 读到的还是内置表 ——
        // 插件写进去的记忆自己读不到，而且不报错。
        ? await (await _memoryProvider()).retrieve(MemoryQuery(
            agentId: chat.activeAgentId!,
            conversationId: chat.activeConversationId,
            limit: limit.clamp(1, 50),
            maxChars: null,
          ))
        : await (await _memoryProvider()).retrieve(MemoryQuery(
            agentId: chat.activeAgentId!,
            conversationId: chat.activeConversationId,
            limit: limit.clamp(1, 50),
            query: keyword,
          ));
    return entries
        .where((e) => e.metadata['pluginId'] == pluginId)
        .map((e) => <String, dynamic>{
              'id': e.id,
              'content': e.content,
              // type 现在是**开放式字符串**（内核 MemoryRecord 的设计），
              // 不再是枚举 —— 插件自定义的记忆类型也能原样带出来
              'type': e.type,
            })
        .toList(growable: false);
  }

  @override
  Future<String> addMemory(
    String pluginId, {
    required String content,
    String kind = 'custom',
    Map<String, dynamic>? metadata,
  }) async {
    await _requireContext();
    final safe = content.trim();
    if (safe.isEmpty || safe.length > 2000) throw StateError('记忆内容长度必须为 1–2000 字符');
    final entry = MemoryEntry(
      id: newId('memory'),
      agentId: chat.activeAgentId!,
      conversationId: null,
      type: MemoryType.custom,
      content: safe,
      createdAt: DateTime.now(),
      metadata: <String, dynamic>{'pluginId': pluginId, 'kind': kind, ...?metadata},
    );
    await (await repos).memories.add(entry);
    return entry.id;
  }
}

// ═══════════════════════════ 插件配置 ═══════════════════════════

/// 插件配置，存在宿主 settings 表里。
///
/// 键前缀 `plugin.config.<pluginId>.` —— 命名空间隔离，
/// 插件 A 拿不到插件 B 的配置（前缀对不上）。
class AppPluginConfig implements HostPluginConfig {
  AppPluginConfig({required this.repos});

  final Future<Repos> repos;

  String _key(String pluginId, String key) => 'plugin.config.$pluginId.$key';

  @override
  Future<Object?> get(String pluginId, String key, {Object? fallback}) async {
    final r = await repos;
    final raw = await r.settings.get(_key(pluginId, key));
    if (raw == null || raw.isEmpty) return fallback;
    // 存 JSON —— 字符串/数字/布尔/对象都能原样往返，
    // 不用在宿主侧加类型标注，也不用猜插件想存什么
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  @override
  Future<void> set(String pluginId, String key, Object? value) async {
    final r = await repos;
    await r.settings.set(_key(pluginId, key), jsonEncode(value));
  }

  @override
  Future<Map<String, Object?>> all(String pluginId) async {
    // settings 表只能按键查，没有"按前缀列出"。
    // 插件配置项很少（清单里声明几个就是几个），而 schema 默认值
    // 由插件侧用 get(key, fallback:) 拿到 —— 所以这里返回空表是正确的，
    // 不是偷懒。真要列全量时再加一个前缀索引。
    return <String, Object?>{};
  }
}
