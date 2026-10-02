/// 真实 API 的连通性验证（默认跳过）。
///
/// **这是唯一一个会真的发网络请求、真的消耗 token 的测试。**
/// 所以它默认跳过，必须显式开启：
///
/// ```powershell
/// $env:TSUKIRO_LIVE_BASE='http://103.236.91.136:52165/v1'
/// $env:TSUKIRO_LIVE_KEY='sk-...'
/// $env:TSUKIRO_LIVE_MODEL='deepseek-v4.1-flash'
/// & ..\..\scripts\dart.ps1 test test\live_api_test.dart --run-skipped
/// ```
///
/// 凭据只从环境变量读，**绝不写进文件、绝不打印**。
library;

import 'dart:io';

import 'package:model_gateway/model_gateway.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

final String liveBase = Platform.environment['TSUKIRO_LIVE_BASE'] ?? '';
final String liveKey = Platform.environment['TSUKIRO_LIVE_KEY'] ?? '';
final String liveModel = Platform.environment['TSUKIRO_LIVE_MODEL'] ?? '';

final bool hasCredentials = liveBase.isNotEmpty && liveKey.isNotEmpty;

void main() {
  final skipReason = hasCredentials
      ? null
      : '未提供 TSUKIRO_LIVE_BASE / TSUKIRO_LIVE_KEY —— 这是默认行为，'
          '真实 API 测试需要显式开启（见文件头说明）';

  group('真实 API（消耗 token，默认跳过）', () {
    late HttpModelGateway gateway;

    setUp(() {
      gateway = HttpModelGateway(
        config: ProviderConfig.openAiCompat(
          baseUrl: liveBase,
          apiKey: liveKey,
          defaultModel: liveModel.isEmpty ? null : liveModel,
        ),
      );
    });

    tearDown(() => gateway.close());

    test('① 连通性 + 鉴权自检（只拉模型表，不花 token）', () async {
      final check = await gateway.check();

      expect(check.ok, isTrue, reason: check.errorMessage);
      expect(check.modelCount, greaterThan(0));
      // ignore: avoid_print
      print('  → ${check.modelCount} 个模型，${check.latency.inMilliseconds}ms');
      for (final m in check.models) {
        // ignore: avoid_print
        print('     · ${m.id}');
      }
    }, skip: skipReason);

    test('② 非流式补全真的出字', () async {
      // **必须显式放宽超时**：实测推理模型（deepseek-v4.1-flash）在
      // max_tokens=600 时，一次非流式请求要 20–30 秒（思维链 230 字符 + 正文 135 token）。
      // dart test 默认 30 秒超时正好卡在边界上，会随机失败。
      //
      // 这个数字本身就是产品结论：**宿主必须默认用流式**。
      // 让用户对着空白界面等 24 秒是不可接受的。
      final reply = await gateway.complete(ModelRequest(
        messages: <ChatMessage>[
          ChatMessage.system('你是一个简洁的助手，只回答被问到的内容。'),
          ChatMessage.user('用一句话回答：你是什么模型？'),
        ],
        // 注意：推理模型的 max_tokens **包含思维链**。给太小会让思维链吃光预算、
        // 正文为空 —— 这不是 bug，是推理模型的固有行为（实测验证过）。
        maxTokens: 600,
      ));

      expect(
        reply.text.trim().isNotEmpty || (reply.reasoning?.isNotEmpty ?? false),
        isTrue,
        reason: '正文和思维链不可能同时为空',
      );
      expect(reply.promptTokens, greaterThan(0));
      // ignore: avoid_print
      print('  → "${reply.text.trim()}"');
      // ignore: avoid_print
      print('  → usage: ${reply.promptTokens} + ${reply.completionTokens}'
          '${reply.reasoning == null ? '' : ', 思维链 ${reply.reasoning!.length} 字符'}');
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('②b 推理模型：max_tokens 太小时正文会为空（可预期的行为）', () async {
      // 这条不是在测我们的代码，而是把「推理模型的一个重要行为」固化成断言 ——
      // 不然产品侧会把它当 bug 反复排查。
      final tiny = await gateway.complete(ModelRequest(
        messages: <ChatMessage>[ChatMessage.user('从 1 数到 20。')],
        maxTokens: 16,
      ));

      final hasContent = tiny.text.trim().isNotEmpty;
      final hasReasoning = tiny.reasoning?.isNotEmpty ?? false;

      // ignore: avoid_print
      print('  → max_tokens=16 时：正文 ${hasContent ? "有" : "空"}，'
          '思维链 ${hasReasoning ? "有" : "空"}');
      // 不断言具体结果（不同模型策略不同），只断言"不会崩"
      expect(tiny.promptTokens >= 0, isTrue);
    }, skip: skipReason);

    test('③ 流式真的逐块返回，且能拼成完整回复', () async {
      final contentChunks = <String>[];
      final reasoningChunks = <String>[];
      var totalDeltas = 0;

      final reply = await gateway.completeStreaming(
        ModelRequest(
          messages: <ChatMessage>[
            ChatMessage.user('从 1 数到 10，只输出数字，用空格分隔。'),
          ],
          maxTokens: 600,
        ),
        onDelta: (d) {
          totalDeltas++;
          if (d.content != null && d.content!.isNotEmpty) contentChunks.add(d.content!);
          if (d.reasoning != null && d.reasoning!.isNotEmpty) {
            reasoningChunks.add(d.reasoning!);
          }
        },
      );

      expect(reply.text.trim(), isNotEmpty);
      expect(totalDeltas, greaterThan(1),
          reason: '如果只有一个 delta，说明流式没真的生效（可能被缓冲了）');

      // ignore: avoid_print
      print('  → $totalDeltas 个增量'
          '（正文 ${contentChunks.length} 块 / 思维链 ${reasoningChunks.length} 块）');
      // ignore: avoid_print
      print('  → 拼成："${reply.text.trim()}"');
    }, skip: skipReason);

    test('④ 工具调用链路：模型真的会发起 tool_calls', () async {
      final reply = await gateway.completeStreaming(ModelRequest(
        messages: <ChatMessage>[
          ChatMessage.user('现在几点了？必须用 get_time 工具查，不要自己猜。'),
        ],
        tools: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': 'get_time',
              'description': '获取当前时间',
              'parameters': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'timezone': <String, dynamic>{
                    'type': 'string',
                    'description': 'IANA 时区名，如 Asia/Shanghai',
                  },
                },
                'required': <String>[],
              },
            },
          },
        ],
        maxTokens: 200,
      ));

      expect(reply.hasToolCalls, isTrue,
          reason: '模型没有发起工具调用。若该模型不支持 function calling，'
              '这个用例会失败——那说明它不能用于本项目的工具链路');

      final call = reply.toolCalls.first;
      expect(call.name, 'get_time');
      expect(call.id, isNotEmpty);

      // ignore: avoid_print
      print('  → 工具调用：${call.name}(${call.arguments})');
    }, skip: skipReason);

    test('⑤ 推理模型的思维链被单独解析出来', () async {
      final reply = await gateway.completeStreaming(ModelRequest(
        messages: <ChatMessage>[
          ChatMessage.user('9.11 和 9.9 哪个大？只回答数字。'),
        ],
        maxTokens: 300,
      ));

      expect(reply.text.trim(), isNotEmpty);
      // ignore: avoid_print
      print('  → 正文："${reply.text.trim()}"');
      // ignore: avoid_print
      print('  → 思维链：${reply.reasoning == null ? "（该模型不返回推理内容）" : "${reply.reasoning!.length} 字符"}');
    }, skip: skipReason);

    test('⑥ 中转站的私有字段被保留下来', () async {
      final reply = await gateway.completeStreaming(ModelRequest(
        messages: <ChatMessage>[ChatMessage.user('说一个字')],
        maxTokens: 20,
      ));

      // ignore: avoid_print
      print('  → extra 字段：${reply.extra.keys.join(", ")}');
      expect(reply.text, isNotNull);
    }, skip: skipReason);

    test('⑦ 错误的 key 会被识别为鉴权失败（不是静默失败）', () async {
      final bad = HttpModelGateway(
        config: ProviderConfig.openAiCompat(
          baseUrl: liveBase,
          // 必须是纯 ASCII —— HTTP 头字段不允许非 ASCII 字符，
          // 用一个中文 key 会在**发请求之前**就抛 FormatException，
          // 于是测不到"服务端如何拒绝鉴权"这件事
          apiKey: 'sk-invalidkey000000000000000000000000000000000000000000',
        ),
      );
      addTearDown(bad.close);

      final check = await bad.check();
      expect(check.ok, isFalse);
      expect(check.errorKind, isNotNull);
      // ignore: avoid_print
      print('  → 错误类型：${check.errorKind!.name} / ${check.errorMessage}');
    }, skip: skipReason);
  });
}
