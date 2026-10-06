/// 工具模型：给「副任务」用的那个小模型。
///
/// ## 什么是工具模型
///
/// 应用里有一批**不面向用户、但也要调 LLM** 的杂活：
///   - 给对话生成标题
///   - 给长对话做摘要（记忆系统要用）
///   - 抽取标签
///   - 内容分类 / 安全判断
///
/// 这些活的特点：**短、快、要求低**。用用户主聊天的那个贵模型去干，
/// 既慢又费钱 —— 用户会看到"聊完一句，标题转半天"。
///
/// 所以单独配一个便宜的模型来干这些。
///
/// ## 默认走哪
///
/// 优先用用户显式配置的；没配就回退到**官方服务**。
/// 本期官方服务还没上线（见 `docs/18` §8），所以实际落到开发配置
/// 里那个服务商上 —— 也就是「用测试 key 顶上」。
///
/// 配置入口：设置 → 模型配置 → 高级 → 工具模型。
library;

import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_gateway/model_gateway.dart';
import 'package:plugin_core/plugin_core.dart';

import '../data/models.dart';
import '../providers/app_providers.dart';

/// 工具模型的配置。
class UtilityModelConfig {
  const UtilityModelConfig({this.providerId, this.modelId});

  static const UtilityModelConfig auto = UtilityModelConfig();

  final String? providerId;
  final String? modelId;

  /// 完全没配 —— 走自动回退。
  bool get isAuto => providerId == null && modelId == null;

  UtilityModelConfig copyWith({
    String? providerId,
    String? modelId,
    bool clear = false,
  }) =>
      clear
          ? auto
          : UtilityModelConfig(
              providerId: providerId ?? this.providerId,
              modelId: modelId ?? this.modelId,
            );

  @override
  String toString() => isAuto ? 'UtilityModelConfig(auto)' : 'UtilityModelConfig($providerId/$modelId)';
}

/// settings 表里的键。
abstract final class UtilityModelKeys {
  static const String providerId = 'utility.providerId';
  static const String modelId = 'utility.modelId';
}

/// 从设置里读工具模型配置。
final utilityModelConfigProvider = FutureProvider<UtilityModelConfig>((ref) async {
  final repos = await ref.watch(reposProvider.future);
  return UtilityModelConfig(
    providerId: await repos.settings.get(UtilityModelKeys.providerId),
    modelId: await repos.settings.get(UtilityModelKeys.modelId),
  );
});

/// 实际生效的工具模型（含回退）。
///
/// 回退顺序：
///   1. 用户配置的那个
///   2. **官方服务**（本期未上线，`isUsable` 为 false，会被跳过）
///   3. 任意可用服务商的第一个模型
///
/// 第 3 条是刻意的宽松：工具模型跑不起来时，标题生成这类功能会静默失败，
/// 用户根本不知道哪里错了。宁可借用主模型，也不要让功能悄悄坏掉。
final effectiveUtilityModelProvider = Provider<ResolvedModel?>((ref) {
  final config = ref.watch(utilityModelConfigProvider).valueOrNull;
  final providers = ref.watch(providerListProvider).valueOrNull;
  final choices = ref.watch(modelChoicesProvider).valueOrNull;
  if (providers == null || choices == null) return null;

  final usable = providers.where((p) => p.isUsable).toList(growable: false);
  if (usable.isEmpty) return null;

  ModelProvider? provider;
  if (config != null && !config.isAuto && config.providerId != null) {
    for (final p in usable) {
      if (p.id == config.providerId) {
        provider = p;
        break;
      }
    }
  }
  provider ??= usable.first;

  final own = choices.where((c) => c.provider.id == provider!.id).toList(growable: false);
  if (own.isEmpty) return null;

  final wanted = config?.modelId;
  final modelId = (wanted != null && own.any((c) => c.modelId == wanted))
      ? wanted
      : own.first.modelId;

  return ResolvedModel(provider: provider, modelId: modelId);
});

/// 工具模型网关。
final utilityGatewayProvider = Provider<HttpModelGateway?>((ref) {
  final resolved = ref.watch(effectiveUtilityModelProvider);
  if (resolved == null) return null;
  final gateway = HttpModelGateway(config: resolved.config);
  ref.onDispose(gateway.close);
  return gateway;
});

/// 副任务服务。
///
/// 所有方法**失败都不抛**，返回 null 让调用方保持原样 ——
/// 标题生成失败不该让聊天报错。
class UtilityModelService {
  UtilityModelService(this._gateway);

  final HttpModelGateway? _gateway;
  String? _lastFailure;

  bool get isAvailable => _gateway != null;
  String? get lastFailure => _lastFailure;

  /// 通用的一次性调用。
  Future<String?> complete(
    String prompt, {
    String? system,
    int maxTokens = 256,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final gateway = _gateway;
    if (gateway == null) {
      _lastFailure = '没有可用的工具模型';
      return null;
    }

    try {
      _lastFailure = null;
      final reply = await gateway
          .complete(ModelRequest(
            messages: <ChatMessage>[
              if (system != null && system.trim().isNotEmpty) ChatMessage.system(system),
              ChatMessage.user(prompt),
            ],
            maxTokens: maxTokens,
          ))
          .timeout(timeout);
      // ModelReply.text 是非空的 String（空回复就是空串）
      final text = reply.text.trim();
      return text.isEmpty ? null : text;
    } on TimeoutException {
      _lastFailure = '工具模型请求超时';
      dev.log('工具模型超时（${timeout.inSeconds}s）', name: 'utility');
      return null;
    } catch (e) {
      _lastFailure = '工具模型请求失败，请检查 API 配置或网络';
      // 副任务失败是**正常情况**（限流、余额不足…），
      // 记一条日志就够了，不要往界面上弹原始异常
      dev.log('工具模型调用失败: $e', name: 'utility');
      return null;
    }
  }

  /// 给对话生成标题。
  ///
  /// 返回 null 表示"生成不出来" —— 调用方应保留原样，而不是改成空标题。
  Future<String?> generateTitle({
    required String userText,
    String? assistantText,
  }) async {
    final snippet = StringBuffer('用户：$userText');
    if (assistantText != null && assistantText.trim().isNotEmpty) {
      final trimmed = assistantText.trim();
      snippet.write('\n助手：${trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed}');
    }

    final raw = await complete(
      '$snippet',
      system: '给下面这段对话起一个标题。要求：\n'
          '1. 不超过 12 个字\n'
          '2. 直接输出标题，不要引号、不要句号、不要"标题："前缀\n'
          '3. 用对话里提到的具体内容，不要写"关于…的讨论"这种空话',
      maxTokens: 64,
      timeout: const Duration(seconds: 15),
    );
    if (raw == null) return null;

    return cleanTitle(raw);
  }

  /// 把模型的输出清理成一个能当标题用的字符串。
  ///
  /// 模型经常不听话：带引号、带「标题：」、带换行、超长。
  /// 这些清理**必须在宿主做**，不能指望提示词 —— 换个模型就不灵了。
  static String? cleanTitle(String raw) {
    var t = raw.trim();

    // 只取第一行（有的模型会输出「标题：xxx\n理由：yyy」）
    final newline = t.indexOf(RegExp(r'[\r\n]'));
    if (newline > 0) t = t.substring(0, newline).trim();

    // 去掉常见前缀
    t = t.replaceFirst(RegExp(r'^(标题|题目|Title)\s*[:：]\s*', caseSensitive: false), '');

    const quotes = <String>['"', "'", '「', '」', '『', '』', '“', '”', '‘', '’', '《', '》'];

    // **反复剥到稳定**，因为标点和引号会互相遮挡。
    //
    // 例如 `标题：「周末计划」。`：
    //   先剥引号 → 结尾是 `。` 不是引号，那个 `」` 剥不掉
    //   再剥标点 → 剩下 `周末计划」`
    // 单趟处理必然漏掉。多跑几轮才能收敛。
    var previous = '';
    while (previous != t) {
      previous = t;

      // 结尾标点
      t = t.replaceFirst(RegExp(r'[。.!！?？、,，;；:：]+$'), '').trim();

      // 首尾引号
      while (t.isNotEmpty && quotes.contains(t[0])) {
        t = t.substring(1).trim();
      }
      while (t.isNotEmpty && quotes.contains(t[t.length - 1])) {
        t = t.substring(0, t.length - 1).trim();
      }
    }

    if (t.isEmpty) return null;
    // 硬截断兜底（提示词说了 12 字，但模型不一定听）
    if (t.length > 20) t = '${t.substring(0, 20)}…';
    return t;
  }
}

final utilityModelServiceProvider = Provider<UtilityModelService>((ref) {
  return UtilityModelService(ref.watch(utilityGatewayProvider));
});
