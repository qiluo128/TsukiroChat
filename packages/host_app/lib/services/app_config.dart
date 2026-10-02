/// 应用配置。
///
/// Demo 阶段从 `assets/dev-config.json` 读（模板见 `dev/dev-config.example.json`）。
/// 正式版会变成：网关下发 + 用户 Token，客户端不再有上游 Key。
///
/// **这个类持有的 apiKey 绝不能进日志、审计、Bridge 或任何持久化** ——
/// 只有 [ProviderConfig] 内部用它发请求。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:model_gateway/model_gateway.dart';

/// 人设配置。
class PersonaConfig {
  const PersonaConfig({
    required this.name,
    required this.systemPrompt,
    this.greeting,
    this.avatarAsset,
  });

  final String name;
  final String systemPrompt;
  final String? greeting;
  final String? avatarAsset;
}

/// 一份可用的应用配置。
class AppConfig {
  const AppConfig({
    required this.persona,
    this.provider,
    this.sourceAsset,
    this.loadNote,
  });

  /// 人设（Demo 内置一个，不做导入 —— 见 docs/12 §1）。
  final PersonaConfig persona;

  /// 模型供应商；为 null 表示没配置，界面要引导用户去设置页。
  final ProviderConfig? provider;

  /// 从哪个 asset 读到的（诊断用）。
  final String? sourceAsset;

  /// 加载过程中的提示（缺文件 / 格式问题）。
  final String? loadNote;

  /// 是否可以直接聊天。
  bool get isReady => provider?.isUsable ?? false;

  /// 打码后的摘要，**可安全展示**。
  String get summary {
    final p = provider;
    if (p == null) return '未配置模型';
    return '${p.displayName ?? p.protocol.name} · ${p.defaultModel ?? "未指定模型"}';
  }

  static const String primaryAsset = 'assets/dev-config.json';
  static const String fallbackAsset = 'assets/dev-config.example.json';

  /// 从 assets 加载。**不会抛异常** —— 配置缺失时返回一份"未配置"的对象，
  /// 让界面能正常打开并引导用户，而不是白屏。
  static Future<AppConfig> load() async {
    for (final asset in <String>[primaryAsset, fallbackAsset]) {
      try {
        final raw = await rootBundle.loadString(asset);
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;

        final providerJson = decoded['provider'];
        ProviderConfig? provider;
        if (providerJson is Map<String, dynamic>) {
          final candidate = ProviderConfig.fromJson(providerJson);
          provider = candidate.isUsable ? candidate : null;
        }

        return AppConfig(
          provider: provider,
          sourceAsset: asset,
          persona: _personaFrom(decoded['persona']),
          loadNote: provider == null
              ? '配置里没有可用的 apiKey，请到设置页填写'
              : null,
        );
      } catch (_) {
        // 这个 asset 不存在或格式坏了，试下一个
        continue;
      }
    }

    return AppConfig(
      persona: _personaFrom(null),
      loadNote: '没有找到任何配置（assets/dev-config.json）',
    );
  }

  static PersonaConfig _personaFrom(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return PersonaConfig(
        name: raw['name']?.toString() ?? '雪',
        systemPrompt: raw['systemPrompt']?.toString() ?? _defaultPrompt,
        greeting: raw['greeting']?.toString(),
        avatarAsset: raw['avatarAsset']?.toString(),
      );
    }
    return const PersonaConfig(name: '雪', systemPrompt: _defaultPrompt, greeting: '……又是你。有事说事。');
  }

  static const String _defaultPrompt =
      '你是雪，一个冷淡但心软的学姐。说话简短，不主动热情，但该帮的忙会帮。'
      '不要用颜文字，不要过度解释。';

  AppConfig copyWith({ProviderConfig? provider, bool clearProvider = false}) => AppConfig(
        persona: persona,
        provider: clearProvider ? null : (provider ?? this.provider),
        sourceAsset: sourceAsset,
        loadNote: loadNote,
      );
}
