/// 把设计令牌变成 Flutter 的 [ThemeData]。
///
/// 用 [ThemeExtension] 挂载令牌，控件里可以 `AppTokens.of(context)` 直接取，
/// 不需要到处传 `AppTokens` 参数，也不会在换肤时漏掉某个控件。
library;

import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// 把 [AppTokens] 挂到 ThemeData 上。
class AppTokensExtension extends ThemeExtension<AppTokensExtension> {
  const AppTokensExtension(this.tokens);

  final AppTokens tokens;

  @override
  AppTokensExtension copyWith({AppTokens? tokens}) =>
      AppTokensExtension(tokens ?? this.tokens);

  @override
  AppTokensExtension lerp(ThemeExtension<AppTokensExtension>? other, double t) {
    // 令牌不做插值：换肤是瞬时切换，中间态没有意义，插值反而会造出
    // 半透明的奇怪颜色。直接返回目标值。
    if (other is AppTokensExtension) return other;
    return this;
  }
}

/// 便捷访问。
extension AppTokensContext on BuildContext {
  /// 当前生效的设计令牌。
  ///
  /// ThemeData 里一定挂了它（[AppTheme.build] 保证），所以这里兜底返回默认值
  /// 而不是抛异常 —— 比起"某个控件因为拿不到主题就白屏"，
  /// 用默认样式渲染出来更容易排查。
  AppTokens get tokens =>
      Theme.of(this).extension<AppTokensExtension>()?.tokens ?? AppTokens.defaults();
}

/// 主题构建。
abstract final class AppTheme {
  /// 从令牌构建主题。
  ///
  /// 明暗**由令牌自己带**（`tokens.brightness`），不单独传参 ——
  /// 两处各说各话时会出现"暗色令牌配浅色 ColorScheme"这种脏组合。
  static ThemeData build(AppTokens t) {
    final brightness = t.brightness;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: t.primary,
      brightness: brightness,
    ).copyWith(
      primary: t.primary,
      surface: t.surface,
      onSurface: t.text,
      error: t.danger,
      outlineVariant: t.divider,
    );

    final textTheme = _textTheme(t, colorScheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: t.background,
      textTheme: textTheme,
      fontFamily: t.font.family,

      appBarTheme: AppBarTheme(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium,
        iconTheme: IconThemeData(color: t.text, size: 22),
      ),

      dividerTheme: DividerThemeData(color: t.divider, thickness: 0.6, space: 1),

      cardTheme: CardThemeData(
        color: t.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radius.card.toDouble()),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        hintStyle: textTheme.bodyMedium?.copyWith(color: t.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radius.input.toDouble()),
          borderSide: BorderSide(color: t.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radius.input.toDouble()),
          borderSide: BorderSide(color: t.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radius.input.toDouble()),
          borderSide: BorderSide(color: t.primary, width: 1.5),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(t.radius.button.toDouble()),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: t.primary),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: t.textMuted,
        textColor: t.text,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: t.text,
        contentTextStyle: TextStyle(color: t.surface, fontSize: t.font.body.toDouble()),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(color: t.primary),

      extensions: <ThemeExtension<dynamic>>[AppTokensExtension(t)],
    );
  }

  /// 令牌驱动的文字样式。
  ///
  /// 注意 [TextTheme] 的字段名（bodyLarge/bodyMedium…）是 Material 的叫法，
  /// 与我们的令牌不是一一对应。这里做一次显式映射，避免"改了 body 令牌
  /// 结果某个控件没变"这种问题。
  static TextTheme _textTheme(AppTokens t, ColorScheme scheme) {
    final body = t.font.body.toDouble();
    final caption = t.font.caption.toDouble();
    final title = t.font.title.toDouble();
    final height = t.font.lineHeight.toDouble();
    final regular = FontWeight.values[
        ((t.font.regular.toInt() / 100).round() - 1).clamp(0, FontWeight.values.length - 1)];
    final bold = FontWeight.values[
        ((t.font.bold.toInt() / 100).round() - 1).clamp(0, FontWeight.values.length - 1)];

    TextStyle s(double size, FontWeight w, {Color? color, double? h}) => TextStyle(
          fontSize: size,
          fontWeight: w,
          color: color ?? t.text,
          height: h,
          fontFamily: t.font.family,
        );

    return TextTheme(
      titleLarge: s(title + 3, bold),
      titleMedium: s(title, bold),
      titleSmall: s(title - 2, bold),
      bodyLarge: s(body, regular, h: height),
      bodyMedium: s(body, regular, h: height),
      bodySmall: s(caption, regular, color: t.textMuted, h: height),
      labelLarge: s(body - 1, bold),
      labelSmall: s(caption - 1, regular, color: t.textMuted),
    );
  }
}
