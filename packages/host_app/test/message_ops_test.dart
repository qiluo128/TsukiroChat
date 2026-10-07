/// 消息操作（撤回/编辑/重说）与它们发出的钩子。
///
/// 核心要证明的是：**撤回之前，插件拿得到被删的内容**。
/// after 的时候内容已经没了 —— 所以 before 那一次是插件保住它的唯一时机。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tsukiro_chat/data/database.dart';
import 'package:tsukiro_chat/data/models.dart';
import 'package:tsukiro_chat/data/repositories.dart';
import 'package:tsukiro_chat/providers/app_providers.dart';
import 'package:tsukiro_chat/providers/chat_controller.dart';
import 'package:tsukiro_chat/providers/plugin_providers.dart';

/// 记录钩子调用的假总线。
class RecordingHookBus {
  final List<(HookPhase, MessageOpPayload)> calls = <(HookPhase, MessageOpPayload)>[];

  HookBus build() {
    final bus = HookBus(
      dispatcher: (registration, context) async {
        final payload = MessageOpPayload.fromVars(context.vars);
        if (payload != null) calls.add((registration.phase, payload));
        return null;
      },
    );

    // **必须注册** —— HookBus 只派发给注册过的相位。
    // 没有注册时 dispatcher 根本不会被调用（这是对的：
    // 宿主每次撤回都去问一遍没有任何插件关心的相位是浪费）。
    for (final phase in const <HookPhase>[
      HookPhase.beforeMessageRetract,
      HookPhase.afterMessageRetract,
      HookPhase.beforeMessageEdit,
      HookPhase.afterMessageEdit,
      HookPhase.beforeRegenerate,
      HookPhase.afterRegenerate,
    ]) {
      bus.register(HookRegistration(
        id: 'h-${phase.name}',
        pluginId: 'dev.test.recorder',
        phase: phase,
        handler: 'hooks/record.js',
      ));
    }
    return bus;
  }
}

void main() {
  late Directory dir;
  late AppDatabase db;
  late Repos repos;
  late Agent agent;
  late Conversation conv;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsukiro-msgops-');
    db = await AppDatabase.open(dir.path);
    repos = Repos(db);
    agent = await repos.agents.create(name: 'A');
    conv = await repos.conversations.create(agent.id);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  /// 造一轮：用户问 + 助手答。
  Future<(StoredChatMessage user, StoredChatMessage assistant)> seedTurn(
    String question,
    String answer,
  ) async {
    final turn = await repos.messages.prepareTurn(conv.id, userText: question);
    await repos.messages.update(turn.assistantMessageId,
        content: answer, status: MessageStatus.done);
    final all = await repos.messages.list(conv.id);
    return (all[all.length - 2], all.last);
  }

  ProviderContainer makeContainer(RecordingHookBus recorder) {
    final container = ProviderContainer(overrides: <Override>[
      reposProvider.overrideWith((ref) async => repos),
      hookBusProvider.overrideWithValue(recorder.build()),
      // 不需要真模型：撤回路径根本不调它
      gatewayForAgentProvider(agent.id).overrideWithValue(null),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  group('撤回', () {
    test('撤回用户消息会连同它的回复一起删掉', () async {
      final (user, _) = await seedTurn('你好', '你好，有什么事？');
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      final n = await controller.retract(conversationId: conv.id, messageId: user.id);

      expect(n, 2, reason: '用户消息和它的回复都该消失');
      expect(await repos.messages.list(conv.id), isEmpty);
    });

    test('撤回前发钩子，**内容还在**；撤回后只给条数', () async {
      final (user, _) = await seedTurn('这句话很重要', '收到');
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      await controller.retract(conversationId: conv.id, messageId: user.id);

      expect(recorder.calls, hasLength(2));
      final (beforePhase, before) = recorder.calls[0];
      final (afterPhase, after) = recorder.calls[1];

      expect(beforePhase, HookPhase.beforeMessageRetract);
      expect(afterPhase, HookPhase.afterMessageRetract);

      // 这条是整件事的关键：撤回是不可逆的，
      // 插件只有 before 那一次机会把内容抄走
      expect(before.content, '这句话很重要');
      expect(before.op, 'retract');

      // after 时内容已经没了
      expect(after.content, isNull);
      expect(after.deletedCount, 2);
    });

    test('撤回助手回复只删那一条', () async {
      final (_, assistant) = await seedTurn('你好', '回复');
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      final n = await controller.retract(conversationId: conv.id, messageId: assistant.id);

      expect(n, 1);
      final left = await repos.messages.list(conv.id);
      expect(left, hasLength(1));
      expect(left.single.content, '你好');
    });

    test('撤回不存在的消息返回 0，不抛', () async {
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      final n = await controller.retract(conversationId: conv.id, messageId: 'nope');
      expect(n, 0);
      expect(recorder.calls, isEmpty);
    });
  });

  group('编辑', () {
    test('拒绝非用户消息', () async {
      final (_, assistant) = await seedTurn('你好', '回复');
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      await expectLater(
        () => controller.edit(
          conversationId: conv.id,
          messageId: assistant.id,
          newText: '改一下',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('拒绝空文本', () async {
      final (user, _) = await seedTurn('你好', '回复');
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      await expectLater(
        () => controller.edit(conversationId: conv.id, messageId: user.id, newText: '   '),
        throwsA(isA<StateError>()),
      );
    });

    test('钩子同时拿到原文与改后的文本', () async {
      final (user, _) = await seedTurn('原文', '回复');
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      try {
        await controller.edit(
          conversationId: conv.id,
          messageId: user.id,
          newText: '改后的文本',
        );
      } catch (_) {
        // 没有可用模型，_send 会抛 —— 但钩子已经发过了，
        // 这里关心的是钩子载荷
      }

      final before = recorder.calls
          .firstWhere((c) => c.$1 == HookPhase.beforeMessageEdit)
          .$2;
      expect(before.content, '原文');
      expect(before.newText, '改后的文本',
          reason: '插件要能做版本历史，就得同时拿到前后两个版本');
    });
  });

  group('重说', () {
    test('没有助手回复时明确报错', () async {
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      await expectLater(
        () => controller.regenerate(conv.id),
        throwsA(predicate((e) => '$e'.contains('没有可以重说的回复'))),
      );
    });

    test('钩子拿到即将被丢弃的那条回复', () async {
      await seedTurn('你好', '这是要丢掉的那条');
      final recorder = RecordingHookBus();
      final controller = makeContainer(recorder).read(chatControllerProvider);

      try {
        await controller.regenerate(conv.id);
      } catch (_) {
        // 同样：模型不可用会抛，但钩子已发
      }

      final before = recorder.calls
          .firstWhere((c) => c.$1 == HookPhase.beforeRegenerate)
          .$2;
      expect(before.content, '这是要丢掉的那条');
      expect(before.op, 'regenerate');
    });
  });
}
