/// 全局 provider。
///
/// 分层：
///   - 基础设施（数据库、配置、模型网关）—— 异步初始化，用 `AsyncValue` 暴露
///   - 仓储
///   - 界面状态（会话列表、当前会话的消息）
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_gateway/model_gateway.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../services/app_config.dart';

// ─────────────────────────── 基础设施 ───────────────────────────

/// 数据库目录。
///
/// 抽成 provider 是为了测试能换成临时目录。
final databaseDirectoryProvider = FutureProvider<String>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  return dir.path;
});

/// 应用数据库。
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final dir = await ref.watch(databaseDirectoryProvider.future);
  final db = await AppDatabase.open(dir);

  // 上一次进程被杀时正在流式输出的消息，标成中断 ——
  // 否则界面上会永远显示"正在输入"。
  final repo = ChatRepository(db);
  final fixed = await repo.failStaleStreamingMessages();
  if (fixed > 0) {
    debugPrint('[db] 修复了 $fixed 条被中断的流式消息');
  }

  ref.onDispose(db.close);
  return db;
});

/// 仓储。
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final db = ref.watch(databaseProvider).valueOrNull;
  if (db == null) {
    // 数据库还没打开时给一个会在调用时报错的替身，
    // 好过让每个界面都写一堆 null 判断
    return _UnavailableRepository();
  }
  return ChatRepository(db);
});

/// 应用配置（人设 + 模型供应商）。
///
/// 可在设置页覆盖 —— 覆盖后 provider 会重建，模型网关跟着换。
final appConfigProvider = FutureProvider<AppConfig>((ref) async {
  return AppConfig.load();
});

/// 用户临时改过的供应商配置（设置页保存后生效，覆盖 asset 里的）。
final providerOverrideProvider = StateProvider<ProviderConfig?>((ref) => null);

/// 当前生效的供应商配置。
final effectiveProviderProvider = Provider<ProviderConfig?>((ref) {
  final override = ref.watch(providerOverrideProvider);
  if (override != null) return override;
  return ref.watch(appConfigProvider).valueOrNull?.provider;
});

/// 模型网关。
///
/// **这是全 app 唯一的模型出口** —— 聊天页和（未来的）插件 `model.chat` 原语
/// 都走它，因此限流、计费、审计才能集中在一处。
final modelGatewayProvider = Provider<HttpModelGateway?>((ref) {
  final config = ref.watch(effectiveProviderProvider);
  if (config == null || !config.isUsable) return null;

  final gateway = HttpModelGateway(config: config);
  ref.onDispose(gateway.close);
  return gateway;
});

/// 人设（可能被用户改）。
final personaProvider = Provider<PersonaConfig>((ref) {
  return ref.watch(appConfigProvider).valueOrNull?.persona ??
      const PersonaConfig(name: '雪', systemPrompt: '你是一个简洁的助手。');
});

// ─────────────────────────── 会话 ───────────────────────────

/// 会话列表。
final sessionListProvider = FutureProvider<List<ChatSession>>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ChatRepository(db).listSessions();
});

/// 当前打开的会话 id。
final currentSessionIdProvider = StateProvider<String?>((ref) => null);

/// 当前会话的消息。
///
/// 用 `family` 按 sessionId 缓存，切换会话时各自保留滚动位置与数据。
final messagesProvider =
    FutureProvider.family<List<StoredChatMessage>, String>((ref, sessionId) async {
  final db = await ref.watch(databaseProvider.future);
  return ChatRepository(db).listMessages(sessionId);
});

// ─────────────────────────── 辅助 ───────────────────────────

/// 数据库未就绪时的替身。
///
/// 所有方法都抛 —— **刻意不静默返回空**：如果用户在这个窗口期发消息，
/// 应该看到明确的错误，而不是"发出去了但没存下来"。
class _UnavailableRepository implements ChatRepository {
  Never _notReady() => throw StateError('数据库尚未就绪');

  @override
  dynamic noSuchMethod(Invocation invocation) => _notReady();
}

/// 供界面展示的数据库目录（调试用）。
Future<String> debugDatabasePath() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}${Platform.pathSeparator}${AppDatabase.fileName}';
}
