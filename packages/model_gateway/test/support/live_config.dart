/// 真实 API 测试的配置加载。
///
/// 优先级：**环境变量 > `dev/dev-config.json` > 无（跳过测试）**。
///
/// 为什么要有文件这一层：Android 上没有"环境变量"这个概念。把配置放成一份 JSON，
/// 本地测试与后续 App 可以读同一个文件（App 侧把它放进 assets 即可），
/// 不必为两个场景维护两套配置方式。
///
/// 文件被 gitignore 掉了 —— 仓库是 public，真 key 提交上去等于公开。
library;

import 'dart:convert';
import 'dart:io';

import 'package:model_gateway/model_gateway.dart';
import 'package:path/path.dart' as p;

/// 加载结果。
class LiveConfig {
  const LiveConfig({required this.provider, required this.source});

  final ProviderConfig provider;

  /// 从哪来的（打码后可用于日志）：`env` 或具体文件路径。
  final String source;

  /// 供打印的摘要，**不含 key 原文**。
  String get summary =>
      '${provider.protocol.name} @ ${provider.normalizedBaseUrl} '
      '(key=${provider.maskedKey}, model=${provider.defaultModel ?? "未指定"}) '
      '[来源: $source]';
}

/// 仓库根目录（测试的工作目录是包根：packages/model_gateway）。
String get repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

/// 加载真实 API 配置；都没有时返回 null（调用方据此跳过测试）。
LiveConfig? loadLiveConfig() {
  // ① 环境变量优先 —— CI 上用不同的 key 时不需要改文件
  final envBase = Platform.environment['TSUKIRO_LIVE_BASE'];
  final envKey = Platform.environment['TSUKIRO_LIVE_KEY'];
  if (envBase != null && envBase.isNotEmpty && envKey != null && envKey.isNotEmpty) {
    return LiveConfig(
      source: 'env',
      provider: ProviderConfig(
        protocol: ProviderProtocol.parse(Platform.environment['TSUKIRO_LIVE_PROTOCOL']),
        baseUrl: envBase,
        apiKey: envKey,
        defaultModel: Platform.environment['TSUKIRO_LIVE_MODEL'],
        displayName: Platform.environment['TSUKIRO_LIVE_NAME'],
      ),
    );
  }

  // ② 本地配置文件
  for (final candidate in <String>[
    Platform.environment['TSUKIRO_DEV_CONFIG'] ?? '',
    p.join(repoRoot, 'dev', 'dev-config.json'),
  ]) {
    if (candidate.isEmpty) continue;
    final file = File(candidate);
    if (!file.existsSync()) continue;

    final parsed = _tryParse(file);
    if (parsed == null) continue;

    final provider = parsed['provider'];
    if (provider is! Map<String, dynamic>) continue;

    final config = ProviderConfig.fromJson(provider);
    if (!config.isUsable) continue;

    return LiveConfig(provider: config, source: candidate);
  }

  return null;
}

Map<String, dynamic>? _tryParse(File file) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    // 配置文件手写容易出错，但一个坏文件不该让测试报错 ——
    // 当作"没有配置"，让测试跳过，并在 stderr 提示一下
    stderr.writeln('! 解析 ${file.path} 失败，已忽略');
    return null;
  }
}
