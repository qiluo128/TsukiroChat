/// 常见的模型服务商预设。
///
/// ## 为什么要有预设
///
/// 接入一个服务商要填三样东西：协议、baseUrl、模型名。
/// 而 baseUrl 是**最容易填错**的一项 —— 少一个 `/v1`、多个斜杠、
/// 用了文档站的地址，表现都是"连不上"，而用户不知道错在哪。
///
/// 预设把这三样一次填好，用户只需要贴一个 API Key。
///
/// **不做成"只能用预设"**：中转站、自建、局域网部署都很常见，
/// 所以预设是起点，不是白名单。
library;

import 'package:model_gateway/model_gateway.dart';

class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.protocol = ProviderProtocol.openai,
    this.defaultModel,
    this.keyHint,
    this.note,
  });

  final String id;

  /// 显示名。
  final String name;

  /// 接口地址。**必须是能直接用的完整前缀**（含版本段）。
  final String baseUrl;

  final ProviderProtocol protocol;

  /// 建议的默认模型。有些服务商模型名会变，所以标"建议"而不是"必须"。
  final String? defaultModel;

  /// API Key 去哪申请。
  final String? keyHint;

  /// 一句话说明，比如"国内直连"。
  final String? note;
}

/// 内置预设。
///
/// 排序：**国内可直连的放前面** —— 目标用户在国内，
/// 放在后面的等于让每个人先踩一次"连不上"。
const List<ProviderPreset> providerPresets = <ProviderPreset>[
  ProviderPreset(
    id: 'deepseek',
    name: 'DeepSeek 官方',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    keyHint: 'platform.deepseek.com',
    note: '国内直连，价格低',
  ),
  ProviderPreset(
    id: 'siliconflow',
    name: '硅基流动',
    baseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'deepseek-ai/DeepSeek-V3',
    keyHint: 'cloud.siliconflow.cn',
    note: '国内直连，模型多',
  ),
  ProviderPreset(
    id: 'moonshot',
    name: '月之暗面 Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
    keyHint: 'platform.moonshot.cn',
    note: '国内直连，长上下文',
  ),
  ProviderPreset(
    id: 'zhipu',
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4-flash',
    keyHint: 'open.bigmodel.cn',
    note: '国内直连',
  ),
  ProviderPreset(
    id: 'dashscope',
    name: '阿里云百炼（通义）',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    keyHint: 'bailian.console.aliyun.com',
    note: '国内直连',
  ),
  ProviderPreset(
    id: 'volcengine',
    name: '火山方舟（豆包）',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    keyHint: 'console.volcengine.com/ark',
    note: '国内直连',
  ),
  ProviderPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    keyHint: 'openrouter.ai/keys',
    note: '需要网络代理，模型最全',
  ),
  ProviderPreset(
    id: 'openai',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
    keyHint: 'platform.openai.com',
    note: '需要网络代理',
  ),
  ProviderPreset(
    id: 'anthropic',
    name: 'Anthropic Claude',
    baseUrl: 'https://api.anthropic.com/v1',
    protocol: ProviderProtocol.anthropic,
    defaultModel: 'claude-sonnet-4-20250514',
    keyHint: 'console.anthropic.com',
    note: '需要网络代理',
  ),
  ProviderPreset(
    id: 'gemini',
    name: 'Google Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    protocol: ProviderProtocol.google,
    defaultModel: 'gemini-2.0-flash',
    keyHint: 'aistudio.google.com',
    note: '需要网络代理',
  ),
];

/// 从已填的 baseUrl 反查预设 —— 用来在界面上高亮"你现在用的是哪个"。
///
/// 只比较主机名，不比完整路径：用户可能在预设基础上改了版本段，
/// 那仍然是同一个服务商。
ProviderPreset? presetForUrl(String? baseUrl) {
  final raw = (baseUrl ?? '').trim();
  if (raw.isEmpty) return null;
  final host = Uri.tryParse(raw)?.host;
  if (host == null || host.isEmpty) return null;
  for (final p in providerPresets) {
    if (Uri.tryParse(p.baseUrl)?.host == host) return p;
  }
  return null;
}
