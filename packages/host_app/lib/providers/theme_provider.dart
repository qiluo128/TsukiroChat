/// 明暗模式偏好。
///
/// 偏好存在 settings 表里，跟着数据库走 —— 不需要额外的存储依赖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';

/// 用户的选择。
enum ThemePreference {
  system,
  light,
  dark;

  static ThemePreference parse(String? raw) {
    for (final p in ThemePreference.values) {
      if (p.name == raw) return p;
    }
    return ThemePreference.system;
  }

  String get label => switch (this) {
        ThemePreference.system => '跟随系统',
        ThemePreference.light => '浅色',
        ThemePreference.dark => '深色',
      };

  /// 交给 Flutter 去决定。
  ///
  /// **`system` 直接用 [ThemeMode.system]，不自己读平台亮度** ——
  /// 自己读的话还得监听平台变化并重建，而 Flutter 本来就管这件事。
  ThemeMode get themeMode => switch (this) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      };
}

abstract final class ThemeKeys {
  static const String preference = 'theme.preference';

  /// 生效的美化包 id。
  ///
  /// 未设置 = 自动（用第一个可用的）；空串 = 明确要求不用插件主题。
  static const String activeTheme = 'theme.active';
}

/// 生效的美化包 id。
class ActiveThemeNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final repos = await ref.watch(reposProvider.future);
    return repos.settings.get(ThemeKeys.activeTheme);
  }

  /// 选定一个美化包（传 null 表示回到自动）。
  Future<void> select(String? themeId) async {
    state = AsyncData(themeId);
    final repos = await ref.read(reposProvider.future);
    await repos.settings.set(ThemeKeys.activeTheme, themeId ?? '');
  }
}

final activeThemeProvider =
    AsyncNotifierProvider<ActiveThemeNotifier, String?>(ActiveThemeNotifier.new);

class ThemePreferenceNotifier extends AsyncNotifier<ThemePreference> {
  @override
  Future<ThemePreference> build() async {
    final repos = await ref.watch(reposProvider.future);
    return ThemePreference.parse(await repos.settings.get(ThemeKeys.preference));
  }

  /// 切换。
  ///
  /// **先改内存状态再落库** —— 主题切换是即时反馈，
  /// 等一次磁盘写会让按钮有一瞬间的迟滞感。
  Future<void> set(ThemePreference preference) async {
    state = AsyncData(preference);
    final repos = await ref.read(reposProvider.future);
    await repos.settings.set(ThemeKeys.preference, preference.name);
  }
}

final themePreferenceProvider =
    AsyncNotifierProvider<ThemePreferenceNotifier, ThemePreference>(
  ThemePreferenceNotifier.new,
);
