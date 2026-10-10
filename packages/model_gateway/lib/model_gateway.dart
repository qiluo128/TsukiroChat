/// Tsukiro Chat 多协议模型接入层。
///
/// 支持三套线协议：
///   - **OpenAI** 及其所有兼容实现（含绝大多数中转站）
///   - **Anthropic** Messages API
///   - **Google** Gemini Generative Language API
///
/// 还有一件事同样重要：**从供应商拉取模型表**。中转站的模型是动态的，
/// 把模型名写死在客户端迟早失效。
///
/// ## 用法
///
/// ```dart
/// final config = ProviderConfig.openAiCompat(
///   baseUrl: 'https://api.deepseek.com/v1',
///   apiKey: 'sk-...',
///   defaultModel: 'deepseek-chat',
/// );
/// final gateway = HttpModelGateway(config: config);
///
/// // 设置页的「测试连接」：只拉模型表，不花 token
/// final check = await gateway.check();
/// print(check);   // ConnectionCheck(ok, 6 个模型, 12ms)
///
/// // 带工具调用的流式对话
/// final reply = await gateway.completeStreaming(
///   ModelRequest(messages: [ChatMessage.user('现在几点')], tools: [...]),
///   onDelta: (d) => stdout.write(d.content ?? ''),
/// );
/// print(reply.toolCalls);
/// ```
library;

export 'src/adapter.dart';
export 'src/adapters/anthropic_adapter.dart';
export 'src/adapters/google_adapter.dart';
export 'src/adapters/openai_adapter.dart';
export 'src/errors.dart';
export 'src/gateway.dart';
export 'src/protocol.dart';
export 'src/sse.dart';
export 'src/transport.dart';
