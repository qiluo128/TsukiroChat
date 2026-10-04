/// 开发用配置的**种子**。
///
/// 注意：这里**不再提供人设** —— 用户明确要求 AI 不要有默认人设
/// （见 `docs/18-agent-and-memory.md` §6）。
///
/// 这个类的唯一用途：首次启动时把 `assets/dev-config.json` 里的服务商
/// 写进数据库，省得每次装包都要手填 Base URL 和 Key。写进去之后就归
/// 设置页管了，用户可以在「模型配置 → 配置 API」里改或删。
library;

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/services.dart' show rootBundle;
import 'package:model_gateway/model_gateway.dart';

import '../data/models.dart';

/// 从 asset 读到的开发用服务商。
class DevSeed {
  const DevSeed({this.provider, this.note});

  final DevConfigProvider? provider;
  final String? note;

  static const String primaryAsset = 'assets/dev-config.json';

  /// 读取。
  ///
  /// **不抛异常** —— 没有配置文件是完全正常的状态（用户自己加服务商），
  /// 不该让 App 起不来。
  static Future<DevSeed> load() async {
    try {
      final raw = await rootBundle.loadString(primaryAsset);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const DevSeed(note: '配置文件格式不正确');
      }

      final p = decoded['provider'];
      if (p is! Map<String, dynamic>) {
        return const DevSeed(note: '配置里没有 provider 段');
      }

      final config = ProviderConfig.fromJson(p);
      if (!config.isUsable) {
        return const DevSeed(note: '配置里没有可用的 apiKey');
      }

      return DevSeed(
        provider: DevConfigProvider(
          name: config.displayName ?? '开发配置',
          protocol: config.protocol,
          baseUrl: config.baseUrl,
          apiKey: config.apiKey,
          defaultModel: config.defaultModel,
        ),
      );
    } catch (e) {
      dev.log('没有读到 $primaryAsset（正常）: $e', name: 'dev-seed');
      return const DevSeed(note: '没有开发配置，请到「模型配置 → 配置 API」里添加服务商');
    }
  }
}

/// asset 里那一份服务商配置。
class DevConfigProvider {
  const DevConfigProvider({
    required this.name,
    required this.protocol,
    required this.baseUrl,
    required this.apiKey,
    this.defaultModel,
  });

  final String name;
  final ProviderProtocol protocol;
  final String baseUrl;
  final String apiKey;
  final String? defaultModel;

  ModelProvider toModelProvider() => ModelProvider(
        id: 'provider_devseed',
        name: name,
        protocol: protocol,
        baseUrl: baseUrl,
        apiKey: apiKey,
        sortOrder: 10,
        createdAt: DateTime.now(),
      );
}
