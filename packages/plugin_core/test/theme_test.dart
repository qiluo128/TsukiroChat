/// 设计令牌（L1 美化包）测试。
///
/// 关键断言：**令牌是「值」不是「CSS」** —— 任何注入尝试都必须在安装时报错，
/// 而不是"过滤掉"。见 `docs/08-ui-slots.md` §8.1。
library;

import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> manifestWithTheme(Object theme) => <String, dynamic>{
      'manifestVersion': 1,
      'id': 'dev.tsukiro.sakura',
      'name': '樱花美化包',
      'version': '1.0.0',
      'runtime': <String, dynamic>{'main': 'index.js'},
      'provides': <String, dynamic>{'theme': theme},
    };

void main() {
  group('令牌目录', () {
    test('覆盖七组令牌', () {
      final prefixes = tokenCatalog.keys.map((k) => k.split('.').first).toSet();
      expect(prefixes, containsAll(<String>[
        'color', 'font', 'radius', 'spacing', 'shadow', 'animation', 'icon',
      ]));
    });

    test('每个令牌都有说明与类型', () {
      for (final spec in tokenCatalog.values) {
        expect(spec.description.trim(), isNotEmpty, reason: spec.name);
      }
    });

    test('阴影与缓动是枚举，不是自由字符串', () {
      expect(tokenCatalog['shadow.card']!.kind, TokenKind.shadow);
      expect(tokenCatalog['shadow.card']!.enumValues, shadowLevels);
      expect(tokenCatalog['animation.easing.standard']!.kind, TokenKind.easing);
    });
  });

  group('合法主题', () {
    test('可以只覆盖一部分令牌（继承宿主默认）', () {
      final m = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'sakura',
        'name': '樱花',
        'tokens': <String, dynamic>{'color.primary': '#FF6B9D'},
      })).manifest!;

      expect(m.themes, hasLength(1));
      expect(m.themes.single.get<String>('color.primary'), '#FF6B9D');
      expect(m.themes.single.tokens.length, 1);
    });

    test('接受单个对象或数组两种写法', () {
      final single = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'radius.card': 12},
      }));
      expect(single.isValid, isTrue, reason: single.issues.join('; '));

      final multiple = parseManifest(manifestWithTheme(<dynamic>[
        <String, dynamic>{'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'radius.card': 12}},
        <String, dynamic>{'id': 'b', 'name': 'B', 'tokens': <String, dynamic>{'radius.card': 20}},
      ]));
      expect(multiple.isValid, isTrue, reason: multiple.issues.join('; '));
      expect(multiple.manifest!.themes, hasLength(2));
    });

    test('各类令牌的合法取值', () {
      final m = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'full',
        'name': '全量',
        'tokens': <String, dynamic>{
          'color.primary': '#FF6B9D',
          'color.text': '#333333CC', // 带 alpha
          'font.size.body': 16,
          'font.lineHeight': 1.5,
          'font.weight.bold': 700,
          'radius.bubble': '18px',
          'shadow.card': 'soft',
          'animation.duration.fast': 120,
          'animation.easing.standard': 'decelerate',
          'icon.send': 'lucide:send',
          'font.family': 'NotoSansSC',
        },
      })).manifest!;

      final t = m.themes.single;
      expect(t.get<num>('font.size.body'), 16);
      expect(t.get<String>('shadow.card'), 'soft');
      expect(t.get<num>('animation.duration.fast'), 120);
    });

    test('纯美化包被识别出来（安装流程可以给更简洁的确认）', () {
      final m = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'color.primary': '#000000'},
      })).manifest!;
      expect(m.isThemeOnly, isTrue);
    });

    test('带工具的插件不算纯美化包', () {
      final json = manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'color.primary': '#000000'},
      });
      (json['provides']! as Map<String, dynamic>)['tools'] = <dynamic>[
        <String, dynamic>{'name': 't', 'description': 'x', 'handler': 'h.js'},
      ];
      final m = parseManifest(json).manifest!;
      expect(m.isThemeOnly, isFalse);
    });
  });

  group('注入必须被拦下', () {
    test('未知令牌名被拒，并给出最接近的候选', () {
      final r = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a',
        'name': 'A',
        'tokens': <String, dynamic>{'color.primry': '#FF6B9D'}, // 少个 a
      }));

      expect(r.isValid, isFalse);
      final msg = r.issues.first.message;
      expect(msg, contains('未知令牌'));
      expect(msg, contains('color.primary'), reason: '拼错的人需要的是提示，不是"未知令牌"四个字');
    });

    test('颜色里藏 CSS 被拒', () {
      for (final evil in <String>[
        'url(https://evil.example.com/x.png)',
        'red; background: url(x)',
        '#fff}body{display:none',
        'expression(alert(1))',
        '@import "evil.css"',
        'javascript:alert(1)',
      ]) {
        final r = parseManifest(manifestWithTheme(<String, dynamic>{
          'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'color.primary': evil},
        }));
        expect(r.isValid, isFalse, reason: '应拒绝: $evil');
      }
    });

    test('颜色格式非法被拒', () {
      for (final bad in <String>['red', '#GGGGGG', 'rgb(1,2,3)', '#12345']) {
        final r = parseManifest(manifestWithTheme(<String, dynamic>{
          'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'color.primary': bad},
        }));
        expect(r.isValid, isFalse, reason: '应拒绝: $bad');
      }
    });

    test('阴影/缓动只接受枚举，不接受 CSS 串', () {
      final r = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a',
        'name': 'A',
        'tokens': <String, dynamic>{
          'shadow.card': '0 2px 8px rgba(0,0,0,.2)', // 看着像，但不是枚举
        },
      }));
      expect(r.isValid, isFalse);
      // 消息里列出的是**合法取值**，不是令牌名 —— 断言要照着实际文案写，
      // 否则测的是"我以为的提示语"而不是"给用户看的提示语"
      expect(r.issues.first.message, contains('soft'));
      expect(r.issues.first.path, contains('shadow.card'));
    });

    test('时长超出合理范围被拒', () {
      final r = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A',
        'tokens': <String, dynamic>{'animation.duration.fast': 999999},
      }));
      expect(r.isValid, isFalse);
      expect(r.issues.first.message, contains('5000'));
    });

    test('字重必须是整百', () {
      final ok = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'font.weight.bold': 700},
      }));
      expect(ok.isValid, isTrue, reason: ok.issues.join('; '));

      final bad = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'font.weight.bold': 650},
      }));
      expect(bad.isValid, isFalse);
    });

    test('字体路径不能穿越或绝对', () {
      for (final bad in <String>['../../etc/passwd', '/system/fonts/x.ttf', r'C:\x.ttf']) {
        final r = parseManifest(manifestWithTheme(<String, dynamic>{
          'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'font.family': bad},
        }));
        expect(r.isValid, isFalse, reason: '应拒绝: $bad');
      }
    });

    test('类型不符被拒', () {
      final cases = <String, Object>{
        'color.primary': 123, // 颜色必须是字符串
        'font.size.body': 'big', // 尺寸不接受任意词
        'font.weight.bold': 'bold', // 字重必须是数字
        'shadow.card': true,
      };
      cases.forEach((token, value) {
        final r = parseManifest(manifestWithTheme(<String, dynamic>{
          'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{token: value},
        }));
        expect(r.isValid, isFalse, reason: '$token = $value 应被拒');
      });
    });
  });

  group('结构校验', () {
    test('缺 id / name 被拒', () {
      final noId = parseManifest(manifestWithTheme(<String, dynamic>{
        'name': 'A', 'tokens': <String, dynamic>{'color.primary': '#000'},
      }));
      expect(noId.isValid, isFalse);

      final noName = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'tokens': <String, dynamic>{'color.primary': '#000'},
      }));
      expect(noName.isValid, isFalse);
      expect(noName.issues.first.message, contains('给用户看的'));
    });

    test('缺 tokens 被拒', () {
      final r = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A',
      }));
      expect(r.isValid, isFalse);
    });

    test('同一插件内主题 id 重复被拒', () {
      final r = parseManifest(manifestWithTheme(<dynamic>[
        <String, dynamic>{'id': 'same', 'name': 'A', 'tokens': <String, dynamic>{'radius.card': 1}},
        <String, dynamic>{'id': 'same', 'name': 'B', 'tokens': <String, dynamic>{'radius.card': 2}},
      ]));
      expect(r.isValid, isFalse);
      expect(r.issues.first.message, contains('重复'));
    });

    test('一次报出全部令牌问题（不是遇错即停）', () {
      final r = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a',
        'name': 'A',
        'tokens': <String, dynamic>{
          'color.primry': '#000', // 拼错
          'color.secondary': '#111', // 未知
          'radius.card': 'big', // 类型错
        },
      }));
      expect(r.issues.length, greaterThanOrEqualTo(3));
    });
  });

  group('主题不是预留段', () {
    test('theme 被解析为强类型，不留在 rawReserved', () {
      final m = parseManifest(manifestWithTheme(<String, dynamic>{
        'id': 'a', 'name': 'A', 'tokens': <String, dynamic>{'color.primary': '#000'},
      })).manifest!;
      expect(m.provides.rawReserved.containsKey('theme'), isFalse);
      expect(m.themes, isNotEmpty);
    });

    test('一个只有主题 + 图片的包能完整走通（零代码插件）', () {
      // 这是 L1 的核心场景：圈内人设/美化创作者不写代码
      final json = <String, dynamic>{
        'manifestVersion': 1,
        'id': 'dev.tsukiro.sakura',
        'name': '樱花美化包',
        'version': '1.0.0',
        'description': '粉粉的樱花配色',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'theme': <String, dynamic>{
            'id': 'sakura',
            'name': '樱花',
            'tokens': <String, dynamic>{
              'color.primary': '#FF6B9D',
              'color.userBubble': '#FFE3EE',
              'radius.bubble': 18,
              'shadow.card': 'soft',
            },
          },
        },
      };

      final r = parseManifest(json);
      expect(r.isValid, isTrue, reason: r.issues.map((e) => e.toString()).join('; '));
      expect(r.manifest!.isThemeOnly, isTrue);
      expect(r.manifest!.permissions, isEmpty, reason: '纯美化包不该申请任何权限');

      // 重新序列化一轮，确认往返稳定
      final again = parseManifest(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(again.isValid, isTrue);
      expect(again.manifest!.themes.single.tokens, r.manifest!.themes.single.tokens);
    });
  });
}
