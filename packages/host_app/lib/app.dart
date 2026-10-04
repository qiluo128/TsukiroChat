/// App 外壳：主题装配 + 路由。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/app_providers.dart';
import 'providers/theme_provider.dart';
import 'theme/app_theme.dart';
import 'theme/design_tokens.dart';
import 'ui/agent_list_page.dart';
import 'ui/settings/settings_page.dart';

/// 指定明暗下的设计令牌。
///
/// 用 `family` 按明暗分别缓存 —— 切主题时不用重新解析。
///
/// 接入美化包之后，这里改成「从已启用的主题插件取 [ThemeDeclaration]
/// → `AppTokens.fromTheme(theme, base: AppTokens.defaults(brightness: ...))`」，
/// **其余代码一行不用改** —— 所有控件都是通过 `context.tokens` 取值的。
final appTokensProvider = Provider.family<AppTokens, Brightness>(
  (ref, brightness) => AppTokens.defaults(brightness: brightness),
);

abstract final class Routes {
  static const String settings = '/settings';
}

class TsukiroApp extends ConsumerWidget {
  const TsukiroApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final light = ref.watch(appTokensProvider(Brightness.light));
    final dark = ref.watch(appTokensProvider(Brightness.dark));
    final preference =
        ref.watch(themePreferenceProvider).valueOrNull ?? ThemePreference.system;

    return MaterialApp(
      title: 'Tsukiro Chat',
      debugShowCheckedModeBanner: false,
      // 两套都给 Flutter，由 themeMode 决定用哪套 ——
      // `system` 时 Flutter 自己监听平台切换，比我们自己读亮度再重建可靠
      theme: AppTheme.build(light),
      darkTheme: AppTheme.build(dark),
      themeMode: preference.themeMode,
      locale: const Locale('zh', 'CN'),
      home: const _Bootstrap(),
      routes: <String, WidgetBuilder>{
        Routes.settings: (_) => const SettingsPage(),
      },
    );
  }
}

/// 启动闸门：等数据库与仓储就绪再进主界面。
///
/// 特意做成全屏 loading + 明确的错误页，而不是"边加载边显示半成品" ——
/// 首次启动要建库、做 v1→v2 迁移、读开发配置，让用户看到进度比看到闪烁的空白强。
class _Bootstrap extends ConsumerWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(reposProvider);

    return repos.when(
      loading: () => const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在启动…'),
            ],
          ),
        ),
      ),
      error: (e, _) => _StartupError(
        error: e,
        onRetry: () => ref.invalidate(reposProvider),
      ),
      data: (_) => const AgentListPage(),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(t.spacing.page.toDouble()),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 44, color: t.danger),
              const SizedBox(height: 12),
              Text('启动失败', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}
