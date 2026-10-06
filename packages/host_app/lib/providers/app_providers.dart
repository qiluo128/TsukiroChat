/// 全局 provider。
///
/// 分层：
///   基础设施（数据库、仓储）→ 数据（智能体/对话/消息/服务商）→ 派生（模型解析）→ 界面状态
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_gateway/model_gateway.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plugin_core/plugin_core.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../data/repositories.dart';
import '../services/app_config.dart';

// ═══════════════════════════ 基础设施 ═══════════════════════════

/// 数据库目录。抽成 provider 是为了测试能换临时目录。
final databaseDirectoryProvider = FutureProvider<String>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  return dir.path;
});

/// 应用数据库。
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final dir = await ref.watch(databaseDirectoryProvider.future);
  final db = await AppDatabase.open(dir);
  ref.onDispose(db.close);
  return db;
});

/// 仓储集合。
final reposProvider = FutureProvider<Repos>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final repos = Repos(db);
  await repos.bootstrap();
  await _seedDevProvider(repos);
  return repos;
});

/// 首次启动时把 `assets/dev-config.json` 里的服务商写进库，只写一次。
///
/// 这是**开发便利**，不是产品逻辑：省得每次装包都手填 Base URL 和 Key。
/// 写进去之后就归设置页管了。
Future<void> _seedDevProvider(Repos repos) async {
  final seed = await DevSeed.load();
  final provider = seed.provider;
  if (provider == null) {
    await repos.settings.set('devSeedApplied', '1');
    return;
  }

  // 旧版本只看 devSeedApplied 标记：如果首次启动时配置缺失，
  // 后来补上配置也永远不会恢复，最终工具模型一直不可用。
  // 现在只有在 seed provider、凭据和默认模型都仍然存在时才跳过。
  final existing = await repos.providers.get('provider_devseed');
  final models = await repos.providers.modelsOf('provider_devseed');
  final hasDefault = provider.defaultModel == null ||
      models.any((model) => model.id == provider.defaultModel);
  if (await repos.settings.get('devSeedApplied') == '1' &&
      existing != null &&
      existing.isUsable &&
      hasDefault) {
    return;
  }

  final row = provider.toModelProvider();
  await repos.providers.upsert(row);
  if (provider.defaultModel != null) {
    await repos.providers.addManualModel(row.id, provider.defaultModel!);
  }
  await repos.settings.set('devSeedApplied', '1');
}

// ═══════════════════════════ 智能体 ═══════════════════════════

final agentListProvider = FutureProvider<List<Agent>>((ref) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.agents.list();
});

final agentProvider = FutureProvider.family<Agent?, String>((ref, id) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.agents.get(id);
});

// ═══════════════════════════ 对话 ═══════════════════════════

/// 对话列表的查询参数。
typedef ConversationQuery = ({String agentId, ConversationStatus status});

final conversationListProvider =
    FutureProvider.family<List<Conversation>, ConversationQuery>((ref, arg) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.conversations.listByAgent(arg.agentId, status: arg.status);
});

final conversationProvider =
    FutureProvider.family<Conversation?, String>((ref, id) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.conversations.get(id);
});

final messagesProvider =
    FutureProvider.family<List<StoredChatMessage>, String>((ref, conversationId) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.messages.list(conversationId);
});

// ═══════════════════════════ 服务商与模型 ═══════════════════════════

final providerListProvider = FutureProvider<List<ModelProvider>>((ref) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.providers.list();
});

final providerModelsProvider =
    FutureProvider.family<List<ProviderModel>, String>((ref, providerId) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.providers.modelsOf(providerId);
});

/// 所有「服务商 + 模型」组合 —— 「选模型时显示来自哪个服务商」用的就是它。
final modelChoicesProvider = FutureProvider<List<ModelChoice>>((ref) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.providers.allChoices(onlyUsable: true);
});

/// 记忆条数（智能体详情页用）。
final memoryCountProvider = FutureProvider.family<int, String>((ref, agentId) async {
  final repos = await ref.watch(reposProvider.future);
  return repos.memories.countOf(agentId);
});

// ═══════════════════════════ 模型解析 ═══════════════════════════

/// 某个智能体解析后的模型。
class ResolvedModel {
  const ResolvedModel({required this.provider, required this.modelId});

  final ModelProvider provider;
  final String modelId;

  ProviderConfig get config => provider.toProviderConfig(defaultModel: modelId);

  String get label => '${provider.name} · $modelId';
}

/// 解析规则（按优先级）：
///   1. 智能体指定了 `providerId` + `modelId`
///   2. 智能体只指定了 `providerId` → 用该服务商的第一个模型
///   3. 智能体没指定 → 用第一个可用服务商 + 它的第一个模型
///
/// **刻意不做"全局默认模型"这类隐式状态** —— 智能体上写死的就是写死的，
/// 改一个智能体不该影响另一个。
final resolvedModelProvider = Provider.family<ResolvedModel?, String>((ref, agentId) {
  final agent = ref.watch(agentProvider(agentId)).valueOrNull;
  final providers = ref.watch(providerListProvider).valueOrNull;
  final choices = ref.watch(modelChoicesProvider).valueOrNull;
  if (providers == null || choices == null) return null;

  final usable = providers.where((p) => p.isUsable).toList(growable: false);
  if (usable.isEmpty) return null;

  ModelProvider? provider;
  final wantedProvider = agent?.model.providerId;
  if (wantedProvider != null) {
    for (final p in usable) {
      if (p.id == wantedProvider) {
        provider = p;
        break;
      }
    }
  }
  provider ??= usable.first;

  final own = choices.where((c) => c.provider.id == provider!.id).toList(growable: false);
  if (own.isEmpty) return null;

  final wantedModel = agent?.model.modelId;
  final modelId = (wantedModel != null && own.any((c) => c.modelId == wantedModel))
      ? wantedModel
      : own.first.modelId;

  return ResolvedModel(provider: provider, modelId: modelId);
});

/// 某个智能体的模型网关。
///
/// **全 app 唯一的模型出口** —— 聊天与（未来的）插件 `model.chat` 都走它，
/// 限流、计费、审计才能集中在一处。
final gatewayForAgentProvider =
    Provider.family<HttpModelGateway?, String>((ref, agentId) {
  final resolved = ref.watch(resolvedModelProvider(agentId));
  if (resolved == null) return null;

  final gateway = HttpModelGateway(config: resolved.config);
  ref.onDispose(gateway.close);
  return gateway;
});

// ═══════════════════════════ 插件基础设施（暂空） ═══════════════════════════
//
// 还没有插件运行时，所以这三个是空的。但**必须是真实对象**而不是临时 new ——
// 插件系统接入时只往里注册，调用方一行不改。

final gatekeeperProvider = Provider<Gatekeeper>((ref) => Gatekeeper());

final toolRegistryProvider = Provider<ToolRegistry>((ref) => ToolRegistry());

final hookBusProvider = Provider<HookBus>((ref) {
  return HookBus(dispatcher: (registration, context) async => null);
});

/// 供「关于」页显示数据库位置（排障用）。
Future<String> debugDatabasePath() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}${Platform.pathSeparator}${AppDatabase.fileName}';
}
