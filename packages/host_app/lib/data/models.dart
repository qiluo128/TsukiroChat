/// 数据模型。
///
/// 以 `docs/18-agent-and-memory.md` 为准：**智能体（Agent）是核心单位**，
/// 对话与记忆都从属于它。
///
/// v1 曾把「会话」当顶层容器 —— 那只在只有一个 AI 角色时成立。见 18 号文档 §1。
library;

import 'dart:math';

import 'package:model_gateway/model_gateway.dart';
import 'package:plugin_core/plugin_core.dart';

// ═══════════════════════════ 智能体 ═══════════════════════════

/// 示例对话。
class ExampleDialog {
  const ExampleDialog({required this.user, required this.assistant});

  final String user;
  final String assistant;

  Map<String, dynamic> toJson() => <String, dynamic>{'user': user, 'assistant': assistant};

  static ExampleDialog fromJson(Map<String, dynamic> j) => ExampleDialog(
        user: j['user']?.toString() ?? '',
        assistant: j['assistant']?.toString() ?? '',
      );
}

/// 人设。
///
/// **可以为空** —— 用户没填就是没填，宿主不自作主张塞一个默认角色
/// （见 `docs/18` §6）。
class Persona {
  const Persona({
    this.systemPrompt = '',
    this.greeting,
    this.examples = const <ExampleDialog>[],
    this.worldBook,
    this.tags = const <String>[],
  });

  static const Persona empty = Persona();

  /// 角色设定提示词。空串表示不注入 system 消息。
  final String systemPrompt;

  /// 开场白（新建对话时作为第一条助手消息）。
  final String? greeting;

  /// 示例对话（few-shot）。
  final List<ExampleDialog> examples;

  /// 世界书：大段设定文本，附加在 system prompt 之后。
  final String? worldBook;

  final List<String> tags;

  bool get isEmpty =>
      systemPrompt.trim().isEmpty &&
      (worldBook?.trim().isEmpty ?? true) &&
      examples.isEmpty;

  /// 组装成最终的系统提示词。全空时返回空串 ——
  /// **宿主据此不注入任何 system 消息**，而不是塞一句"你是一个助手"。
  String buildSystemPrompt() {
    final parts = <String>[];
    if (systemPrompt.trim().isNotEmpty) parts.add(systemPrompt.trim());
    if (worldBook != null && worldBook!.trim().isNotEmpty) {
      parts.add('# 世界设定\n${worldBook!.trim()}');
    }
    return parts.join('\n\n');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'systemPrompt': systemPrompt,
        if (greeting != null) 'greeting': greeting,
        if (examples.isNotEmpty)
          'examples': examples.map((e) => e.toJson()).toList(growable: false),
        if (worldBook != null) 'worldBook': worldBook,
        if (tags.isNotEmpty) 'tags': tags,
      };

  static Persona fromJson(Map<String, dynamic>? json) {
    if (json == null) return Persona.empty;
    final rawExamples = json['examples'];
    final rawTags = json['tags'];
    return Persona(
      systemPrompt: json['systemPrompt']?.toString() ?? '',
      greeting: json['greeting']?.toString(),
      worldBook: json['worldBook']?.toString(),
      tags: rawTags is List
          ? rawTags.map((e) => '$e').toList(growable: false)
          : const <String>[],
      examples: rawExamples is List
          ? rawExamples
              .whereType<Map<String, dynamic>>()
              .map(ExampleDialog.fromJson)
              .toList(growable: false)
          : const <ExampleDialog>[],
    );
  }

  Persona copyWith({
    String? systemPrompt,
    String? greeting,
    List<ExampleDialog>? examples,
    String? worldBook,
    List<String>? tags,
    bool clearGreeting = false,
    bool clearWorldBook = false,
  }) =>
      Persona(
        systemPrompt: systemPrompt ?? this.systemPrompt,
        greeting: clearGreeting ? null : (greeting ?? this.greeting),
        examples: examples ?? this.examples,
        worldBook: clearWorldBook ? null : (worldBook ?? this.worldBook),
        tags: tags ?? this.tags,
      );
}

/// 智能体的模型配置。指向某个服务商下的某个模型 —— 见 `docs/18` §4。
class AgentModelConfig {
  const AgentModelConfig({
    this.providerId,
    this.modelId,
    this.temperature,
    this.maxTokens,
  });

  static const AgentModelConfig inherit = AgentModelConfig();

  /// 服务商 id；null = 用全局默认（列表里第一个可用的）。
  final String? providerId;

  /// 模型名；null = 用该服务商的默认模型。
  final String? modelId;

  final double? temperature;
  final int? maxTokens;

  bool get isEmpty => providerId == null && modelId == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (providerId != null) 'providerId': providerId,
        if (modelId != null) 'modelId': modelId,
        if (temperature != null) 'temperature': temperature,
        if (maxTokens != null) 'maxTokens': maxTokens,
      };

  static AgentModelConfig fromJson(Map<String, dynamic>? j) {
    if (j == null) return inherit;
    return AgentModelConfig(
      providerId: j['providerId']?.toString(),
      modelId: j['modelId']?.toString(),
      temperature: (j['temperature'] as num?)?.toDouble(),
      maxTokens: (j['maxTokens'] as num?)?.toInt(),
    );
  }

  AgentModelConfig copyWith({
    String? providerId,
    String? modelId,
    double? temperature,
    int? maxTokens,
    bool clearProvider = false,
    bool clearModel = false,
  }) =>
      AgentModelConfig(
        providerId: clearProvider ? null : (providerId ?? this.providerId),
        modelId: clearModel ? null : (modelId ?? this.modelId),
        temperature: temperature ?? this.temperature,
        maxTokens: maxTokens ?? this.maxTokens,
      );
}

// 记忆粒度（MemoryScope）现在定义在 plugin_core 里 ——
//
// 它是**插件契约的一部分**：插件实现 MemoryProvider 时要声明
// supportedScopes。只放在宿主内部的话，插件根本没法表达这件事。
// 这里通过 import 'package:plugin_core/plugin_core.dart' 使用它。

/// 记忆配置。**这是声明不是实现** —— 宿主提供层级，插件决定怎么记怎么取。
class MemoryConfig {
  const MemoryConfig({
    this.scope = MemoryScope.agent,
    this.enabled = true,
    this.providerPluginId,
    this.maxEntries,
  });

  static const MemoryConfig defaults = MemoryConfig();

  final MemoryScope scope;
  final bool enabled;

  /// 由哪个插件实现记忆（null = 用宿主内置的最朴素实现）。
  final String? providerPluginId;

  /// 条目上限（null = 不限）。防插件无限写记忆把库撑爆。
  final int? maxEntries;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'scope': scope.name,
        'enabled': enabled,
        if (providerPluginId != null) 'providerPluginId': providerPluginId,
        if (maxEntries != null) 'maxEntries': maxEntries,
      };

  static MemoryConfig fromJson(Map<String, dynamic>? j) {
    if (j == null) return defaults;
    return MemoryConfig(
      scope: MemoryScope.parse(j['scope']?.toString()),
      enabled: j['enabled'] != false,
      providerPluginId: j['providerPluginId']?.toString(),
      maxEntries: (j['maxEntries'] as num?)?.toInt(),
    );
  }
}

/// 智能体 —— 核心单位。
class Agent {
  Agent({
    required this.id,
    required this.name,
    this.avatarPath,
    this.persona = Persona.empty,
    this.model = AgentModelConfig.inherit,
    this.memory = MemoryConfig.defaults,
    required this.createdAt,
    required this.updatedAt,
    this.conversationCount = 0,
    this.memoryCount = 0,
  });

  final String id;
  String name;
  String? avatarPath;
  Persona persona;
  AgentModelConfig model;
  MemoryConfig memory;
  final DateTime createdAt;
  DateTime updatedAt;

  /// 冗余计数（列表页用，避免每次 COUNT）。
  int conversationCount;
  int memoryCount;

  bool get hasPersona => !persona.isEmpty;

  /// 头像占位用的首字。
  ///
  /// 用 `runes.first` 而不是 `[0]`：后者会把 emoji 或某些中文字截成半个码点，
  /// 渲染出一个乱码方块。
  String get initial {
    final t = name.trim();
    if (t.isEmpty) return '?';
    return String.fromCharCode(t.runes.first);
  }

  @override
  String toString() => 'Agent($id, $name)';
}

// ═══════════════════════════ 对话 ═══════════════════════════

enum ConversationStatus {
  active,
  archived;

  static ConversationStatus parse(String? raw) =>
      raw == 'archived' ? ConversationStatus.archived : ConversationStatus.active;
}

/// 对话（从属于智能体）。
class Conversation {
  Conversation({
    required this.id,
    required this.agentId,
    required this.title,
    this.status = ConversationStatus.active,
    required this.createdAt,
    required this.updatedAt,
    this.lastMessageAt,
    this.messageCount = 0,
  });

  final String id;
  final String agentId;
  String title;
  ConversationStatus status;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? lastMessageAt;
  int messageCount;

  DateTime get sortTime => lastMessageAt ?? updatedAt;
  bool get isArchived => status == ConversationStatus.archived;
}

// ═══════════════════════════ 记忆 ═══════════════════════════

/// 记忆类型。
///
/// `fact` / `summary` 是宿主认识的；其余**开放式** —— 插件自定义，
/// 宿主只当字符串存与取，这样加新类型不用改宿主。
enum MemoryType {
  fact,
  summary,
  vector,
  graph,
  custom;

  static MemoryType parse(String? raw) {
    for (final t in MemoryType.values) {
      if (t.name == raw) return t;
    }
    return MemoryType.custom;
  }

  String get label => switch (this) {
        MemoryType.fact => '事实',
        MemoryType.summary => '摘要',
        MemoryType.vector => '向量',
        MemoryType.graph => '图谱',
        MemoryType.custom => '自定义',
      };
}

/// 一条记忆。
class MemoryEntry {
  MemoryEntry({
    required this.id,
    required this.agentId,
    this.conversationId,
    this.type = MemoryType.fact,
    required this.content,
    this.sourceMessageIds = const <String>[],
    required this.createdAt,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String agentId;

  /// null = 智能体级（所有对话共享）；非 null = 只属于该对话。
  final String? conversationId;

  final MemoryType type;
  String content;

  /// 可追溯"这条记忆是从哪几句来的"。
  final List<String> sourceMessageIds;

  final DateTime createdAt;

  /// 插件私有数据，约定放在 `metadata.<pluginId>` 下。
  Map<String, dynamic> metadata;

  bool get isAgentLevel => conversationId == null;

  @override
  String toString() => 'MemoryEntry(${type.name}, ${content.length} 字符)';
}

// ═══════════════════════════ 服务商 ═══════════════════════════

/// 服务商。
class ModelProvider {
  ModelProvider({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
    required this.apiKey,
    this.isOfficial = false,
    this.sortOrder = 100,
    required this.createdAt,
    this.modelCount = 0,
  });

  final String id;
  String name;
  ProviderProtocol protocol;
  String baseUrl;

  /// ⚠ 当前存在 SQLite 里（见 `docs/18` §4.3 的说明与迁移路径）。
  String apiKey;

  /// 官方服务：置顶、不可删除。
  final bool isOfficial;

  int sortOrder;
  final DateTime createdAt;

  int modelCount;

  bool get isUsable => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  ProviderConfig toProviderConfig({String? defaultModel}) => ProviderConfig(
        protocol: protocol,
        baseUrl: baseUrl,
        apiKey: apiKey,
        defaultModel: defaultModel,
        displayName: name,
      );

  /// 打码后的 key，**只用于展示**。
  String get maskedKey {
    if (apiKey.isEmpty) return '（未填）';
    if (apiKey.length <= 8) return '***';
    return '${apiKey.substring(0, 4)}…${apiKey.substring(apiKey.length - 4)}';
  }

  @override
  String toString() => 'ModelProvider($id, $name)';
}

/// 某个服务商下的模型。
class ProviderModel {
  ProviderModel({
    required this.providerId,
    required this.id,
    this.displayName,
    this.contextWindow,
    this.discoveredAt,
    this.isManual = false,
  });

  final String providerId;

  /// 模型名（调用时传给 API 的那个）。
  final String id;

  String? displayName;
  int? contextWindow;

  /// 从 `/v1/models` 拉到的时间；null = 手动添加。
  DateTime? discoveredAt;

  /// 用户手动添加的（有些中转站的模型表不全）。刷新时**不删**。
  bool isManual;

  String get label => (displayName?.isNotEmpty ?? false) ? displayName! : id;

  @override
  String toString() => 'ProviderModel($providerId/$id)';
}

/// 一个模型 + 它来自哪个服务商。
///
/// 用户要求「选模型时显示哪个模型来自哪个服务商」—— 这就是那个视图对象。
class ModelChoice {
  const ModelChoice({required this.provider, required this.model});

  final ModelProvider provider;
  final ProviderModel model;

  String get providerName => provider.name;
  String get modelId => model.id;
  bool get isOfficial => provider.isOfficial;

  /// 唯一键：同一个模型名可能来自多个服务商，所以模型名不是全局唯一。
  String get key => '${provider.id}/${model.id}';
}

// ═══════════════════════════ 消息 ═══════════════════════════

enum MessageStatus {
  streaming,
  done,
  error,
  cancelled;

  static MessageStatus parse(String? raw) {
    for (final s in MessageStatus.values) {
      if (s.name == raw) return s;
    }
    return MessageStatus.done;
  }
}

/// 一条消息。
class StoredChatMessage {
  StoredChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    this.content,
    this.richContent,
    this.toolCalls = const <ToolCall>[],
    this.toolCallId,
    this.status = MessageStatus.done,
    this.errorCode,
    required this.seq,
    required this.createdAt,
    this.tokensPrompt,
    this.tokensCompletion,
    this.reasoning,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String conversationId;
  final ChatRole role;
  String? content;

  /// 富内容（插件通过 `message.update` 写入）。宿主不解释结构。
  Map<String, dynamic>? richContent;

  List<ToolCall> toolCalls;
  String? toolCallId;
  MessageStatus status;
  String? errorCode;
  final int seq;
  final DateTime createdAt;
  int? tokensPrompt;
  int? tokensCompletion;
  String? reasoning;

  /// 插件私有数据，约定放在 `metadata.<pluginId>` 下。
  Map<String, dynamic> metadata;

  bool get isUser => role == ChatRole.user;
  bool get isAssistant => role == ChatRole.assistant;
  bool get isStreaming => status == MessageStatus.streaming;
  bool get isEmptyBody =>
      (content == null || content!.trim().isEmpty) && toolCalls.isEmpty;

  ChatMessage toChatMessage() => ChatMessage(
        role: role,
        content: content,
        toolCalls: toolCalls,
        toolCallId: toolCallId,
      );

  @override
  String toString() =>
      'StoredChatMessage(${role.name} #$seq, ${content?.length ?? 0} 字符, ${status.name})';
}

// ═══════════════════════════ 工具 ═══════════════════════════

/// 生成 id。
///
/// 时间戳 + 随机后缀：单机单用户下够用，且**时间有序**（便于排序、调试时能看顺序）。
/// 正式版要跨设备同步时再换 UUIDv7。
final Random _random = Random();
String newId([String prefix = '']) {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = _random.nextInt(0xFFFFFF).toRadixString(36).padLeft(5, '0');
  return prefix.isEmpty ? '$ts$rand' : '${prefix}_$ts$rand';
}
