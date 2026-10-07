/// 空正文诊断的测试。
///
/// 守的是一条经验：**空正文有好几种原因，报错要说清是哪一种**。
/// 全糊成「返回了空内容」的话，用户只会反复重试 ——
/// 而重试永远不会让 token 预算变大。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:tsukiro_chat/services/model_diagnostics.dart';

ModelReply reply({
  String text = '',
  String? reasoning,
  String? finishReason,
  int promptTokens = 0,
  int completionTokens = 0,
  Map<String, dynamic> extra = const <String, dynamic>{},
  List<ToolCall> toolCalls = const <ToolCall>[],
}) =>
    ModelReply(
      text: text,
      reasoning: reasoning,
      finishReason: finishReason,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      extra: extra,
      toolCalls: toolCalls,
    );

void main() {
  group('什么算空正文', () {
    test('有正文 → 不算空', () {
      expect(isEmptyReply(reply(text: '你好')), isFalse);
      expect(isEmptyReply(reply(text: '  你好  ')), isFalse);
    });

    test('纯空白 → 算空', () {
      expect(isEmptyReply(reply(text: '   \n\t ')), isTrue);
    });

    test('**只有工具调用、没有正文 → 不算空**', () {
      // 模型决定"先调工具再说"是正常行为。
      // 只看正文是否为空的话，这条会被误判成失败。
      expect(
        isEmptyReply(reply(toolCalls: <ToolCall>[
          const ToolCall(id: 't1', name: 'check_time', arguments: <String, dynamic>{}),
        ])),
        isFalse,
      );
    });
  });

  group('诊断消息', () {
    test('有思维链时，指出是预算被思维链吃光了（最常见的一种）', () {
      final msg = describeEmptyReply(
        reply(
          reasoning: '让我想想……' * 20,
          finishReason: 'length',
          completionTokens: 120,
        ),
        where: '打招呼',
        requestedMaxTokens: 120,
      );

      expect(msg, contains('打招呼'));
      expect(msg, contains('思维链'));
      expect(msg, contains('120'), reason: '要带上当初要的预算，否则用户不知道该调多少');
      expect(msg, contains('2000'), reason: '要给出可操作的建议值');
      // 这条最要紧：告诉用户"不是模型坏了，是预算给少了"
      expect(msg, contains('吃光'));
    });

    test('没有思维链但 finish_reason=length → 说预算不够，且给出预算值', () {
      final msg = describeEmptyReply(
        reply(finishReason: 'length', completionTokens: 50),
        where: '打招呼',
        requestedMaxTokens: 50,
      );
      expect(msg, contains('预算'));
      expect(msg, contains('length'));
      expect(msg, contains('50'));
      // 与"有思维链"那条的区别：这条不能断言思维链**有内容**，
      // 只是提醒预算在写的过程中就用完了
      expect(msg, contains('请调大'));
    });

    test('正常结束但正文空 → 让用户换个说法，而不是让他调预算', () {
      final msg = describeEmptyReply(
        reply(finishReason: 'stop'),
        where: 'agent.model.chat',
      );
      expect(msg, contains('空串'));
      expect(msg, contains('换个说法'));
      // 这种时候让用户去调 maxTokens 是误导
      expect(msg, isNot(contains('调大')));
    });

    test('带出 token 用量与上游附加字段', () {
      final msg = describeEmptyReply(
        reply(
          reasoning: '思考中',
          promptTokens: 800,
          completionTokens: 120,
          extra: <String, dynamic>{
            'cost_cny': 0.0012,
            'trace_id': 'abc',
            'billing_pending': true,
          },
        ),
        where: '打招呼',
        requestedMaxTokens: 120,
      );

      expect(msg, contains('120 tokens'));
      expect(msg, contains('800 tokens'));
      // 中转站的字段里常藏着上游真正的说法，不能丢
      expect(msg, contains('cost_cny'));
      expect(msg, contains('trace_id'));
    });

    test('没有任何线索时也能给出话，不返回空串', () {
      final msg = describeEmptyReply(reply(), where: '某处');
      expect(msg, isNotEmpty);
      expect(msg, contains('某处'));
    });
  });
}
