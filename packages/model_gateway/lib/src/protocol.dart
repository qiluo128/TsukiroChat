/// API 协议与供应商配置。
///
/// 三套协议的区别**只在线上格式**：请求体怎么拼、响应怎么解、模型表从哪拉。
/// 上层（Agent 循环、插件原语）看到的永远是同一套 [ModelRequest] / [ModelReply]。
library;

/// 支持的线协议。
enum ProviderProtocol {
  /// OpenAI 及其所有兼容实现（含绝大多数中转站）。
  ///
  /// 路径：`POST {base}/chat/completions`、`GET {base}/models`
  /// 鉴权：`Authorization: Bearer <key>`
  openai,

  /// Anthropic Messages API。
  ///
  /// 路径：`POST {base}/messages`
  /// 鉴权：`x-api-key: <key>` + `anthropic-version: <ver>`
  anthropic,

  /// Google Gemini（Generative Language API）。
  ///
  /// 路径：`POST {base}/models/{model}:generateContent`
  /// 鉴权：`?key=<key>` 查询参数 或 `x-goog-api-key` 头
  google;

  static ProviderProtocol parse(String? raw) {
    for (final p in ProviderProtocol.values) {
      if (p.name == raw) return p;
    }
    return ProviderProtocol.openai;
  }
}

/// 一个供应商端点。
class ProviderConfig {
  const ProviderConfig({
    required this.protocol,
    required this.baseUrl,
    required this.apiKey,
    this.defaultModel,
    this.anthropicVersion = '2023-06-01',
    this.extraHeaders = const <String, String>{},
    this.timeout = const Duration(seconds: 120),
    this.displayName,
  });

  /// 便捷构造：OpenAI 兼容中转站。
  factory ProviderConfig.openAiCompat({
    required String baseUrl,
    required String apiKey,
    String? defaultModel,
    String? displayName,
  }) =>
      ProviderConfig(
        protocol: ProviderProtocol.openai,
        baseUrl: baseUrl,
        apiKey: apiKey,
        defaultModel: defaultModel,
        displayName: displayName,
      );

  final ProviderProtocol protocol;

  /// 不带尾部斜杠的基地址（构造时会规范化）。
  final String baseUrl;

  /// **只在宿主内存里流转，永远不进日志、不进审计、不传给插件。**
  final String apiKey;

  /// 逻辑默认模型。用户没指定时用它。
  final String? defaultModel;

  /// Anthropic 要求的版本头。
  final String anthropicVersion;

  /// 额外请求头（某些中转站要求）。
  final Map<String, String> extraHeaders;

  final Duration timeout;

  /// 给用户看的名字（设置页用）。
  final String? displayName;

  /// 规范化后的基地址：去掉尾部斜杠。
  String get normalizedBaseUrl {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /// 是否能用于发起请求。
  bool get isUsable => normalizedBaseUrl.isNotEmpty && apiKey.isNotEmpty;

  /// 序列化。**注意这会带上 apiKey 原文。**
  ///
  /// 只用于本地持久化（设置页保存、Android 的 dev asset）。
  /// 任何会离开设备的场景（日志、审计、Bridge、上报）都不得使用它。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'protocol': protocol.name,
        'baseUrl': baseUrl,
        if (apiKey.isNotEmpty) 'apiKey': apiKey,
        if (defaultModel != null) 'defaultModel': defaultModel,
        if (displayName != null) 'displayName': displayName,
        if (anthropicVersion != '2023-06-01') 'anthropicVersion': anthropicVersion,
        if (extraHeaders.isNotEmpty) 'extraHeaders': extraHeaders,
        if (timeout != const Duration(seconds: 120)) 'timeoutMs': timeout.inMilliseconds,
      };

  /// 从 JSON 还原。字段缺失时用合理默认值，**不抛异常** ——
  /// 配置文件是用户手写的，一个拼错的字段不该让整个设置页打不开。
  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    final rawTimeout = json['timeoutMs'];
    final headers = json['extraHeaders'];
    return ProviderConfig(
      protocol: ProviderProtocol.parse(json['protocol']?.toString()),
      baseUrl: json['baseUrl']?.toString() ?? '',
      apiKey: json['apiKey']?.toString() ?? '',
      defaultModel: json['defaultModel']?.toString(),
      anthropicVersion: json['anthropicVersion']?.toString() ?? '2023-06-01',
      extraHeaders: headers is Map
          ? headers.map((k, v) => MapEntry('$k', '$v'))
          : const <String, String>{},
      timeout: rawTimeout is num
          ? Duration(milliseconds: rawTimeout.toInt())
          : const Duration(seconds: 120),
      displayName: json['displayName']?.toString(),
    );
  }

  /// 打码后的 key，**只用于日志**。
  String get maskedKey {
    if (apiKey.length <= 8) return '***';
    return '${apiKey.substring(0, 4)}…${apiKey.substring(apiKey.length - 4)}';
  }

  ProviderConfig copyWith({
    ProviderProtocol? protocol,
    String? baseUrl,
    String? apiKey,
    String? defaultModel,
    Map<String, String>? extraHeaders,
    Duration? timeout,
    String? displayName,
  }) =>
      ProviderConfig(
        protocol: protocol ?? this.protocol,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        defaultModel: defaultModel ?? this.defaultModel,
        anthropicVersion: anthropicVersion,
        extraHeaders: extraHeaders ?? this.extraHeaders,
        timeout: timeout ?? this.timeout,
        displayName: displayName ?? this.displayName,
      );

  @override
  String toString() =>
      'ProviderConfig(${protocol.name}, $normalizedBaseUrl, key=$maskedKey)';
}

/// 模型表里的一个模型。
class ModelInfo {
  const ModelInfo({
    required this.id,
    this.ownedBy,
    this.createdAt,
    this.displayName,
    this.contextWindow,
    this.raw = const <String, dynamic>{},
  });

  /// 传给 API 的模型名。
  final String id;

  final String? ownedBy;
  final DateTime? createdAt;

  /// 人类可读名（有些中转站会返回）。
  final String? displayName;

  final int? contextWindow;

  /// 原始条目。中转站常塞私有字段（价格、倍率等），保留不丢。
  final Map<String, dynamic> raw;

  static ModelInfo? fromOpenAi(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final created = json['created'];
    return ModelInfo(
      id: id,
      ownedBy: json['owned_by']?.toString(),
      createdAt: created is num
          ? DateTime.fromMillisecondsSinceEpoch(created.toInt() * 1000)
          : null,
      displayName: json['name']?.toString() ?? json['display_name']?.toString(),
      contextWindow: (json['context_window'] ?? json['context_length']) is num
          ? ((json['context_window'] ?? json['context_length']) as num).toInt()
          : null,
      raw: json,
    );
  }

  static ModelInfo? fromGoogle(Map<String, dynamic> json) {
    final name = json['name']?.toString();
    if (name == null || name.isEmpty) return null;
    // Google 返回的是 "models/gemini-1.5-pro"，去掉前缀才是调用时用的名字
    final id = name.startsWith('models/') ? name.substring(7) : name;
    return ModelInfo(
      id: id,
      displayName: json['displayName']?.toString(),
      contextWindow: json['inputTokenLimit'] is num
          ? (json['inputTokenLimit'] as num).toInt()
          : null,
      raw: json,
    );
  }

  @override
  String toString() => 'ModelInfo($id)';
}
