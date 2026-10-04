/// 设计令牌的宿主侧落地。
///
/// 这一层是 `docs/08-ui-slots.md` §8.1 「L1 样式级」的**执行端**：
/// 插件（美化包）只声明 `provides.theme.tokens` 里的一组**值**，
/// 由这里解析成 Flutter 的 `ThemeData`。
///
/// 关键点：**令牌是值不是 CSS**。所以这里做的是「查表 + 类型转换」，
/// 不存在"解析样式字符串"这种会引入注入面的步骤。
library;

import 'package:flutter/material.dart';
import 'package:plugin_core/plugin_core.dart';

/// 解析后的设计令牌。
///
/// 每个字段都有宿主默认值；美化包只覆盖它关心的那几个。
@immutable
class AppTokens {
  const AppTokens({
    required this.colors,
    required this.font,
    required this.radius,
    required this.spacing,
    required this.shadows,
    required this.animations,
    this.brightness = Brightness.light,
    this.sourceThemeId,
  });

  /// 宿主默认令牌 —— 没有美化包时用它。
  ///
  /// [brightness] 为 [Brightness.dark] 时给一套暗色底。
  ///
  /// **为什么暗色不用"把浅色反转"来实现**：反转出来的对比度和色相都不对 ——
  /// 深色背景上的纯白字会刺眼，主色也需要降低明度才不突兀。
  /// 所以这里是一套**独立挑选**的值。
  factory AppTokens.defaults({Brightness brightness = Brightness.light}) {
    if (brightness == Brightness.dark) return AppTokens._dark();
    return AppTokens._light();
  }

  factory AppTokens._light() => AppTokens(
        colors: const <String, Color>{
          'color.primary': Color(0xFF6366F1),
          'color.background': Color(0xFFF7F7FA),
          'color.surface': Color(0xFFFFFFFF),
          'color.text': Color(0xFF1F2430),
          'color.textMuted': Color(0xFF8A8F9C),
          'color.userBubble': Color(0xFFE4E7FF),
          'color.assistantBubble': Color(0xFFFFFFFF),
          'color.divider': Color(0xFFE8E8EE),
          'color.danger': Color(0xFFEF4444),
          'color.success': Color(0xFF10B981),
        },
        font: const FontTokens(
          family: null, // null = 用系统默认字体
          familyMono: null,
          body: 16,
          caption: 12.5,
          title: 17,
          lineHeight: 1.55,
          regular: 400,
          bold: 600,
        ),
        radius: const RadiusTokens(bubble: 18, card: 14, button: 22, input: 22),
        spacing: const SpacingTokens(page: 16, messageGap: 10, section: 20),
        shadows: const <String, String>{
          'shadow.card': 'soft',
          'shadow.fab': 'medium',
        },
        animations: const AnimationTokens(
          fast: Duration(milliseconds: 120),
          normal: Duration(milliseconds: 240),
          easing: 'standard',
        ),
        brightness: Brightness.light,
      );

  factory AppTokens._dark() => AppTokens(
        colors: const <String, Color>{
          // 主色降低明度：深色背景上原来的 #6366F1 太跳
          'color.primary': Color(0xFF818CF8),
          // 不是纯黑 —— 纯黑配白字对比过强，长时间看很累
          'color.background': Color(0xFF14161C),
          'color.surface': Color(0xFF1D2027),
          // 不是纯白 —— 深色底上的纯白会"发光"
          'color.text': Color(0xFFE6E8EE),
          'color.textMuted': Color(0xFF8B92A3),
          'color.userBubble': Color(0xFF2E3350),
          'color.assistantBubble': Color(0xFF1D2027),
          'color.divider': Color(0xFF2A2E38),
          // 深色底上饱和度要提一点才看得出是"红"
          'color.danger': Color(0xFFF87171),
          'color.success': Color(0xFF34D399),
        },
        font: const FontTokens(
          family: null,
          familyMono: null,
          body: 16,
          caption: 12.5,
          title: 17,
          // 深色底上字距和行高都要略放宽，否则显得挤
          lineHeight: 1.6,
          regular: 400,
          bold: 600,
        ),
        radius: const RadiusTokens(bubble: 18, card: 14, button: 22, input: 22),
        spacing: const SpacingTokens(page: 16, messageGap: 10, section: 20),
        shadows: const <String, String>{
          // 深色底上阴影几乎看不见，改用"发光"才有层次
          'shadow.card': 'none',
          'shadow.fab': 'glow',
        },
        animations: const AnimationTokens(
          fast: Duration(milliseconds: 120),
          normal: Duration(milliseconds: 240),
          easing: 'standard',
        ),
        brightness: Brightness.dark,
      );

  /// 从美化包的 [ThemeDeclaration] 派生。
  ///
  /// **只覆盖它声明了的令牌**，其余沿用默认 —— 所以美化包不需要写全量，
  /// 写一个 `color.primary` 也是一个合法主题。
  factory AppTokens.fromTheme(ThemeDeclaration theme, {AppTokens? base}) {
    final defaults = base ?? AppTokens.defaults();
    final tokens = theme.tokens;
    Color? color(String key) {
      final raw = tokens[key];
      if (raw is! String) return null;
      return parseHexColor(raw);
    }

    num size(String key, num fallback) {
      final raw = tokens[key];
      if (raw is num) return raw;
      if (raw is String) {
        final m = RegExp(r'^(-?\d+(?:\.\d+)?)(px|rem|em|%)?$').firstMatch(raw.trim());
        if (m != null) {
          final v = double.tryParse(m.group(1)!);
          if (v != null) {
            // rem/em 按 16px 基数折算；% 不适用于尺寸，忽略
            if (m.group(2) == 'rem' || m.group(2) == 'em') return v * 16;
            return v;
          }
        }
      }
      return fallback;
    }

    Duration duration(String key, Duration fallback) {
      final raw = tokens[key];
      if (raw is num) return Duration(milliseconds: raw.toInt());
      return fallback;
    }

    final mergedColors = <String, Color>{...defaults.colors};
    for (final key in defaults.colors.keys) {
      final c = color(key);
      if (c != null) mergedColors[key] = c;
    }

    final mergedShadows = <String, String>{...defaults.shadows};
    for (final key in defaults.shadows.keys) {
      final raw = tokens[key];
      if (raw is String) mergedShadows[key] = raw;
    }

    return AppTokens(
      colors: mergedColors,
      font: FontTokens(
        family: tokens['font.family']?.toString() ?? defaults.font.family,
        familyMono: tokens['font.familyMono']?.toString() ?? defaults.font.familyMono,
        body: size('font.size.body', defaults.font.body),
        caption: size('font.size.caption', defaults.font.caption),
        title: size('font.size.title', defaults.font.title),
        lineHeight: size('font.lineHeight', defaults.font.lineHeight),
        regular: size('font.weight.regular', defaults.font.regular),
        bold: size('font.weight.bold', defaults.font.bold),
      ),
      radius: RadiusTokens(
        bubble: size('radius.bubble', defaults.radius.bubble),
        card: size('radius.card', defaults.radius.card),
        button: size('radius.button', defaults.radius.button),
        input: size('radius.input', defaults.radius.input),
      ),
      spacing: SpacingTokens(
        page: size('spacing.page', defaults.spacing.page),
        messageGap: size('spacing.messageGap', defaults.spacing.messageGap),
        section: size('spacing.section', defaults.spacing.section),
      ),
      shadows: mergedShadows,
      animations: AnimationTokens(
        fast: duration('animation.duration.fast', defaults.animations.fast),
        normal: duration('animation.duration.normal', defaults.animations.normal),
        easing: tokens['animation.easing.standard']?.toString() ?? defaults.animations.easing,
      ),
      // 明暗沿用 base：美化包改颜色，但不改用户选的明暗偏好
      brightness: defaults.brightness,
      sourceThemeId: theme.id,
    );
  }

  final Map<String, Color> colors;
  final FontTokens font;
  final RadiusTokens radius;
  final SpacingTokens spacing;
  final Map<String, String> shadows;
  final AnimationTokens animations;

  /// 明暗模式。美化包**可以**覆盖颜色，但不改变明暗 ——
  /// 那是用户的偏好，不该被插件决定。
  final Brightness brightness;

  /// 来自哪个美化包；null = 宿主默认。
  final String? sourceThemeId;

  bool get isDark => brightness == Brightness.dark;

  Color get primary => colors['color.primary']!;
  Color get background => colors['color.background']!;
  Color get surface => colors['color.surface']!;
  Color get text => colors['color.text']!;
  Color get textMuted => colors['color.textMuted']!;
  Color get userBubble => colors['color.userBubble']!;
  Color get assistantBubble => colors['color.assistantBubble']!;
  Color get divider => colors['color.divider']!;
  Color get danger => colors['color.danger']!;
  Color get success => colors['color.success']!;

  /// 阴影档位 → 具体 BoxShadow 列表。
  ///
  /// **档位是枚举不是 CSS 串**，所以这里是"查表"而不是"解析" ——
  /// 美化包无法通过这个字段注入任意样式。
  List<BoxShadow> shadowFor(String token) {
    switch (shadows[token] ?? 'none') {
      case 'none':
        return const <BoxShadow>[];
      case 'soft':
        return <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ];
      case 'medium':
        return <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ];
      case 'strong':
        return <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ];
      case 'glow':
        return <BoxShadow>[
          BoxShadow(
            color: colors['color.primary']!.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ];
      default:
        return const <BoxShadow>[];
    }
  }

  Curve get easingCurve {
    switch (animations.easing) {
      case 'linear':
        return Curves.linear;
      case 'decelerate':
        return Curves.decelerate;
      case 'accelerate':
        return Curves.easeIn;
      case 'spring':
        return Curves.easeOutBack;
      case 'standard':
      default:
        return Curves.easeInOut;
    }
  }

  AppTokens copyWith({Map<String, Color>? colors, FontTokens? font, RadiusTokens? radius}) =>
      AppTokens(
        colors: colors ?? this.colors,
        font: font ?? this.font,
        radius: radius ?? this.radius,
        spacing: spacing,
        shadows: shadows,
        animations: animations,
        brightness: brightness,
        sourceThemeId: sourceThemeId,
      );
}

@immutable
class FontTokens {
  const FontTokens({
    required this.family,
    required this.familyMono,
    required this.body,
    required this.caption,
    required this.title,
    required this.lineHeight,
    required this.regular,
    required this.bold,
  });

  final String? family;
  final String? familyMono;
  final num body;
  final num caption;
  final num title;
  final num lineHeight;
  final num regular;
  final num bold;
}

@immutable
class RadiusTokens {
  const RadiusTokens({
    required this.bubble,
    required this.card,
    required this.button,
    required this.input,
  });

  final num bubble;
  final num card;
  final num button;
  final num input;
}

@immutable
class SpacingTokens {
  const SpacingTokens({
    required this.page,
    required this.messageGap,
    required this.section,
  });

  final num page;
  final num messageGap;
  final num section;
}

@immutable
class AnimationTokens {
  const AnimationTokens({
    required this.fast,
    required this.normal,
    required this.easing,
  });

  final Duration fast;
  final Duration normal;
  final String easing;
}

/// 解析 `#RGB` / `#RRGGBB` / `#RRGGBBAA`。
///
/// **注意字节序**：CSS 风格的十六进制是 `RRGGBBAA`（alpha 在**最后**），
/// 而 Flutter 的 `Color(int)` 收的是 `AARRGGBB`（alpha 在**最前**）。
/// 直接把 8 位串丢给 `Color()` 会让 alpha 和 red 串位 —— 颜色"看着差不多但不对"，
/// 极难排查。这里显式换一次序。
///
/// 解析不出来返回 null，由调用方回退默认值 —— 美化包已经过 `TokenValidator`
/// 校验，理论上走不到这里；但宿主不该因为一个坏值就崩掉。
Color? parseHexColor(String hex) {
  var s = hex.trim();
  if (!s.startsWith('#')) return null;
  s = s.substring(1);

  if (s.length == 3) {
    // #RGB → #RRGGBB
    s = s.split('').map((c) => '$c$c').join();
  }

  if (s.length == 6) {
    // RRGGBB：补一个不透明的 alpha。**这里不能换序** ——
    // 直接拼成 8 位再当 RRGGBBAA 解，会把中间两位误当成 alpha。
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  if (s.length == 8) {
    // RRGGBBAA → AARRGGBB（换序）
    final rgb = s.substring(0, 6);
    final alpha = s.substring(6, 8);
    final v = int.tryParse('$alpha$rgb', radix: 16);
    return v == null ? null : Color(v);
  }

  return null;
}
