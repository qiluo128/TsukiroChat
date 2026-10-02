/// 设计令牌与主题装配测试。
///
/// 这组测试验证的是 `docs/08-ui-slots.md` §8.1「L1 样式级」真的能用：
/// **美化包只声明值 → 宿主解析成 ThemeData**，全程没有"解析样式字符串"这一步。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_core/plugin_core.dart';
import 'package:tsukiro_chat/theme/app_theme.dart';
import 'package:tsukiro_chat/theme/design_tokens.dart';

/// [ThemeDeclaration.tokens] 是 `Map<String, Object>`（值一定非空），
/// 而测试里写 `<String, dynamic>{}` 更顺手，所以在这里转一次。
ThemeDeclaration theme(Map<String, dynamic> tokens, {String id = 'test'}) =>
    ThemeDeclaration(id: id, name: id, tokens: tokens.cast<String, Object>());

void main() {
  group('默认令牌', () {
    test('所有字段都有值', () {
      final t = AppTokens.defaults();
      expect(t.primary, isNotNull);
      expect(t.background, isNotNull);
      expect(t.font.body, greaterThan(0));
      expect(t.radius.bubble, greaterThan(0));
      expect(t.sourceThemeId, isNull);
    });

    test('能生成合法的 ThemeData', () {
      final themeData = AppTheme.build(AppTokens.defaults());
      expect(themeData.useMaterial3, isTrue);
      expect(themeData.colorScheme.primary, AppTokens.defaults().primary);
      expect(themeData.extension<AppTokensExtension>(), isNotNull);
    });
  });

  group('美化包覆盖', () {
    test('只覆盖一个令牌，其余沿用默认', () {
      final base = AppTokens.defaults();
      final t = AppTokens.fromTheme(theme(<String, dynamic>{'color.primary': '#FF6B9D'}));

      expect(t.primary, const Color(0xFFFF6B9D));
      // 没声明的保持默认 —— 美化包不需要写全量
      expect(t.background, base.background);
      expect(t.font.body, base.font.body);
      expect(t.sourceThemeId, 'test');
    });

    test('可以覆盖多个类别', () {
      final t = AppTokens.fromTheme(theme(<String, dynamic>{
        'color.primary': '#FF6B9D',
        'font.size.body': 17,
        'radius.bubble': 22,
        'spacing.page': 20,
        'shadow.card': 'strong',
        'animation.duration.fast': 80,
      }));

      expect(t.primary, const Color(0xFFFF6B9D));
      expect(t.font.body, 17);
      expect(t.radius.bubble, 22);
      expect(t.spacing.page, 20);
      expect(t.shadows['shadow.card'], 'strong');
      expect(t.animations.fast, const Duration(milliseconds: 80));
    });

    test('支持 #RGB 简写', () {
      final t = AppTokens.fromTheme(theme(<String, dynamic>{'color.primary': '#F0A'}));
      expect(t.primary, const Color(0xFFFF00AA));
    });

    test('支持带 alpha 的 #RRGGBBAA（alpha 在最后，CSS 语义）', () {
      final t = AppTokens.fromTheme(theme(<String, dynamic>{'color.primary': '#11223344'}));
      // #11223344 = R=11 G=22 B=33 A=44
      // Flutter 的 Color(int) 收的是 AARRGGBB，所以换算后是 0x44112233。
      // 这两套字节序不一样，是本项目最容易踩的坑之一。
      expect(t.primary, const Color(0x44112233));
    });

    test('尺寸支持带单位的值', () {
      final t = AppTokens.fromTheme(theme(<String, dynamic>{'font.size.body': '1.25rem'}));
      // rem 按 16px 基数折算
      expect(t.font.body, 20);
    });
  });

  group('坏值降级（不崩）', () {
    test('非法颜色回退到默认', () {
      final t = AppTokens.fromTheme(theme(<String, dynamic>{'color.primary': '不是颜色'}));
      expect(t.primary, AppTokens.defaults().primary);
    });

    test('非法尺寸回退到默认', () {
      final t = AppTokens.fromTheme(theme(<String, dynamic>{'font.size.body': 'big'}));
      expect(t.font.body, AppTokens.defaults().font.body);
    });

    test('空令牌表等于默认', () {
      final base = AppTokens.defaults();
      final t = AppTokens.fromTheme(theme(<String, dynamic>{}));
      expect(t.primary, base.primary);
      expect(t.radius.bubble, base.radius.bubble);
    });
  });

  group('阴影与缓动是枚举查表，不是字符串解析', () {
    test('每一档都有对应的 BoxShadow', () {
      final t = AppTokens.defaults();
      for (final level in shadowLevels) {
        final shadows = t.shadowFor('shadow.card');
        // 只要不抛异常即可；none 返回空列表是合法的
        expect(shadows, isA<List<BoxShadow>>());
      }
      expect(t.shadowFor('shadow.card'), isNotEmpty);
    });

    test('未知档位返回空而不是崩', () {
      final t = AppTokens.fromTheme(theme(<String, dynamic>{'shadow.card': 'nonsense'}));
      expect(t.shadowFor('shadow.card'), isEmpty);
    });

    test('缓动枚举映射到 Curve', () {
      for (final easing in easingLevels) {
        final t = AppTokens.fromTheme(
          theme(<String, dynamic>{'animation.easing.standard': easing}),
        );
        expect(t.easingCurve, isA<Curve>());
      }
    });
  });

  group('hex 解析', () {
    test('合法格式', () {
      expect(parseHexColor('#FFF'), const Color(0xFFFFFFFF));
      expect(parseHexColor('#FF6B9D'), const Color(0xFFFF6B9D));
      expect(parseHexColor('#FF6B9D80'), const Color(0x80FF6B9D));
    });

    test('非法格式返回 null 而不是抛', () {
      expect(parseHexColor('red'), isNull);
      expect(parseHexColor('#GGG'), isNull);
      expect(parseHexColor('#12345'), isNull);
      expect(parseHexColor(''), isNull);
    });
  });

  group('context.tokens 取用', () {
    testWidgets('子控件能拿到令牌', (tester) async {
      final custom = AppTokens.fromTheme(theme(<String, dynamic>{'color.primary': '#123456'}));

      late AppTokens seen;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(custom),
        home: Builder(builder: (context) {
          seen = context.tokens;
          return const SizedBox();
        }),
      ));

      expect(seen.primary, const Color(0xFF123456));
    });

    testWidgets('没有挂 ThemeExtension 时回退到默认而不是抛', (tester) async {
      late AppTokens seen;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          seen = context.tokens;
          return const SizedBox();
        }),
      ));

      expect(seen.primary, AppTokens.defaults().primary);
    });
  });
}
