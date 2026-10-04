/// 聊天控制器测试。
///
/// 重点验证两件事：
///   1. **同一时间只允许一轮** —— 重复 send 抛 StateError
///   2. **取消时保留已收到的部分内容** —— 不是清空
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:model_gateway/model_gateway.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/models.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/providers/app_providers.dart';
import 'package:tsukiro_chat/providers/chat_controller.dart';

void main() {
  late _Env env;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async => env = await _Env.create());
  tearDown(() => env.dispose());

  test('并发发送被拒绝，取消后保留已收到的部分内容', () async {
    final conv = await env.repos.conversations.create(env.agent.id);
    final firstDeltaSeen = Completer<void>();

    final transport = _SlowStreamingTransport(
      onBeforeSecondDelta: () {
        if (!firstDeltaSeen.isCompleted) firstDeltaSeen.complete();
      },
    );
    final gateway = HttpModelGateway(
      config: ProviderConfig.openAiCompat(
        baseUrl: 'https://example.test/v1',
        apiKey: 'test-key',
        defaultModel: 'test-model',
      ),
      transport: transport,
    );
    addTearDown(gateway.close);

    final container = ProviderContainer(overrides: <Override>[
      reposProvider.overrideWith((ref) async => env.repos),
      gatewayForAgentProvider(env.agent.id).overrideWithValue(gateway),
    ]);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider);

    // 第一轮：等到收到第一段正文再继续
    final first = controller.send(conversationId: conv.id, text: '第一条');
    await firstDeltaSeen.future.timeout(const Duration(seconds: 5));

    // 第二轮必须被拒绝 —— 否则两轮会交错写同一个对话
    await expectLater(
      () => controller.send(conversationId: conv.id, text: '第二条'),
      throwsA(isA<StateError>()),
    );

    controller.cancel();
    await first;

    expect(container.read(sendingProvider), isFalse);
    expect(container.read(streamingBufferProvider), isNull);

    final messages = await env.repos.messages.list(conv.id);
    expect(messages, hasLength(2));
    expect(messages[0].role, ChatRole.user);
    expect(messages[1].status, MessageStatus.cancelled);

    // **关键**：取消时保留已经收到的部分，而不是清空
    expect(messages[1].content, '部分');
  });

  test('没有可用模型时给出可操作的错误', () async {
    final conv = await env.repos.conversations.create(env.agent.id);
    final container = ProviderContainer(overrides: <Override>[
      reposProvider.overrideWith((ref) async => env.repos),
      // 不覆盖网关 → 没有服务商可用 → 解析不出模型
      gatewayForAgentProvider(env.agent.id).overrideWithValue(null),
    ]);
    addTearDown(container.dispose);

    await expectLater(
      () => container.read(chatControllerProvider).send(
            conversationId: conv.id,
            text: '你好',
          ),
      throwsA(isA<StateError>()),
    );
  });

  test('智能体人设为空时不注入 system 消息', () async {
    final conv = await env.repos.conversations.create(env.agent.id);
    final transport = _CapturingTransport();
    final gateway = HttpModelGateway(
      config: ProviderConfig.openAiCompat(
        baseUrl: 'https://example.test/v1',
        apiKey: 'k',
        defaultModel: 'm',
      ),
      transport: transport,
    );
    addTearDown(gateway.close);

    final container = ProviderContainer(overrides: <Override>[
      reposProvider.overrideWith((ref) async => env.repos),
      gatewayForAgentProvider(env.agent.id).overrideWithValue(gateway),
    ]);
    addTearDown(container.dispose);

    // 人设为空的智能体（新建时就是空的）
    expect(env.agent.persona.isEmpty, isTrue);

    await container.read(chatControllerProvider).send(
          conversationId: conv.id,
          text: '你好',
        );

    final sent = transport.lastBody!;
    final messages = (sent['messages']! as List).cast<Map<String, dynamic>>();
    expect(
      messages.any((m) => m['role'] == 'system'),
      isFalse,
      reason: '没有设人设时不该替用户塞一句"你是一个助手"',
    );
  });
}

/// 测试环境：临时目录 + 数据库 + 一个智能体。
class _Env {
  _Env._(this.directory, this.database, this.repos, this.agent);

  final Directory directory;
  final AppDatabase database;
  final Repos repos;
  final Agent agent;

  static Future<_Env> create() async {
    final dir = await Directory.systemTemp.createTemp('tsukiro-controller-test-');
    final db = await AppDatabase.open(dir.path);
    final repos = Repos(db);
    final agent = await repos.agents.create(name: '测试智能体');
    return _Env._(dir, db, repos, agent);
  }

  Future<void> dispose() async {
    await database.close();
    await directory.delete(recursive: true);
  }
}

/// 分两段推送的假上游：第一段之后停住，等测试发信号。
class _SlowStreamingTransport implements HttpTransport {
  _SlowStreamingTransport({required this.onBeforeSecondDelta});

  final void Function() onBeforeSecondDelta;

  @override
  Future<HttpResponseData> send(HttpRequestSpec spec) =>
      Future<HttpResponseData>.error(
        UnsupportedError('这个测试只走流式'),
      );

  @override
  Future<StreamedResponse> sendStreaming(HttpRequestSpec spec) async =>
      StreamedResponse(statusCode: 200, bytes: _chunks());

  Stream<List<int>> _chunks() async* {
    yield _sse(<String, dynamic>{
      'choices': <Object?>[
        <String, dynamic>{'delta': <String, dynamic>{'content': '部分'}},
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    onBeforeSecondDelta();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    yield _sse(<String, dynamic>{
      'choices': <Object?>[
        <String, dynamic>{
          'delta': <String, dynamic>{'content': '后续'},
          'finish_reason': 'stop',
        },
      ],
    });
    yield utf8.encode('data: [DONE]\n\n');
  }

  List<int> _sse(Map<String, dynamic> value) => utf8.encode('data: ${jsonEncode(value)}\n\n');

  @override
  void close() {}
}

/// 记录请求体、立即回一句话的假上游。
class _CapturingTransport implements HttpTransport {
  Map<String, dynamic>? lastBody;

  @override
  Future<HttpResponseData> send(HttpRequestSpec spec) async {
    lastBody = spec.body is String
        ? jsonDecode(spec.body!) as Map<String, dynamic>
        : null;
    return HttpResponseData(
      statusCode: 200,
      body: jsonEncode(<String, dynamic>{
        'choices': <Object?>[
          <String, dynamic>{
            'message': <String, dynamic>{'role': 'assistant', 'content': '好'},
            'finish_reason': 'stop',
          },
        ],
      }),
    );
  }

  @override
  Future<StreamedResponse> sendStreaming(HttpRequestSpec spec) async {
    lastBody = spec.body is String
        ? jsonDecode(spec.body!) as Map<String, dynamic>
        : null;
    return StreamedResponse(
      statusCode: 200,
      bytes: Stream<List<int>>.fromIterable(<List<int>>[
        utf8.encode('data: ${jsonEncode(<String, dynamic>{
              'choices': <Object?>[
                <String, dynamic>{
                  'delta': <String, dynamic>{'content': '好'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n'),
        utf8.encode('data: [DONE]\n\n'),
      ]),
    );
  }

  @override
  void close() {}
}
