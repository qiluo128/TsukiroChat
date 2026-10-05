/// App 外壳：主题装配 + 路由。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_core/plugin_core.dart';

import 'providers/app_providers.dart';
import 'providers/plugin_providers.dart';
import 'providers/theme_provider.dart';
import 'theme/app_theme.dart';
import 'theme/design_tokens.dart';
import 'plugin/host_services_impl.dart';
import 'plugin/plugin_host.dart';
import 'ui/agent_list_page.dart';
import 'ui/settings/settings_page.dart';

/// 指定明暗下的设计令牌。
///
/// **会叠加已启用美化包（L1）的令牌。**
///
/// 这一步以前完全没实现 —— 注释里写着"接入美化包之后改成…"，
/// 但代码一直只返回宿主默认值，所以主题插件装了也看不出任何变化。
///
/// 美化包改颜色但**不改明暗** —— 那是用户的偏好（见 `AppTokens.fromTheme`）。
final appTokensProvider = Provider.family<AppTokens, Brightness>((ref, brightness) {
  final base = AppTokens.defaults(brightness: brightness);

  final host = ref.watch(pluginHostValueProvider);
  // 插件启停会改变可用主题，跟着重建
  ref.watch(pluginHostRevisionProvider);
  if (host == null) return base;

  final available = host.availableThemes();
  if (available.isEmpty) return base;

  // 选择语义：
  //   null（没设置过）→ 自动用第一个。用户装了主题插件就该看到效果，
  //                     否则他会以为插件坏了（正是本次反馈的现象）
  //   ''            → 用户明确要求"不用插件主题"
  //   其它          → 按 id 找
  final selected = ref.watch(activeThemeProvider).valueOrNull;
  final ThemeDeclaration? chosen = selected == null
      ? available.first
      : (selected.isEmpty ? null : host.themeById(selected));
  if (chosen == null) return base;

  return AppTokens.fromTheme(chosen, base: base);
});

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
      // 插件要能弹提示，而它是在 widget 树之外被调用的（WebView 回调），
      // 拿不到 BuildContext —— 只能靠这个全局入口
      scaffoldMessengerKey: appMessengerKey,
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

/// App 外壳：主题装配 + 路由 + 插件宿主视图。
class _Shell extends ConsumerWidget {
  const _Shell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 在**外壳**里 watch，而不是在某个页面里 ——
    // 插件宿主必须随 App 一起活着。挂在聊天页上的话，
    // 用户一退出聊天，插件 WebView 就被销毁了。
    final host = ref.watch(pluginHostValueProvider);

    // **必须 watch 这个。**
    //
    // `initialize()` 返回时 `runtime` 还是 null（自动启动是后台跑的），
    // 运行时是在之后才创建的。不 watch 这个计数器的话，外壳不会重建，
    // `PluginHostView` 就一直是空的 —— WebView 永远不 attach，
    // 于是 `attachRuntime` 永远不被调用，插件停在"未启动"。
    ref.watch(pluginHostRevisionProvider);

    return Stack(
      children: <Widget>[
        child,
        // 1x1 的透明宿主：Android 平台视图要先 attach 才会跑 JS
        if (host != null) PluginHostView(host: host),
      ],
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

    // 插件宿主在后台初始化。**不阻塞启动** —— 插件起不来不该让 App 打不开，
    // 而且首次启动还要装演示插件，那要读好几个 asset。
    ref.watch(pluginHostProvider);

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
      data: (_) => const _Shell(child: AgentListPage()),
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
