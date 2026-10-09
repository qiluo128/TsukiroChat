/// 运行期 UI 树的解析与限制。
///
/// 树是**插件给的**，所以每一条都要有上限：
/// 没有上限的递归结构就是一个 DoS 面。
library;

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  Map<String, dynamic> node(String type, [Map<String, dynamic> extra = const {}]) =>
      <String, dynamic>{'type': type, ...extra};

  group('基本解析', () {
    test('解析类型、文本、语义化属性', () {
      final n = UiNode.parse(node('text', <String, dynamic>{
        'id': 'g1',
        'text': '玫瑰',
        'subtitle': '2024-01-01',
        'emphasis': 'primary',
        'size': 'lg',
      }));

      expect(n.type, UiNodeType.text);
      expect(n.id, 'g1');
      expect(n.text, '玫瑰');
      expect(n.subtitle, '2024-01-01');
      expect(n.emphasis, UiEmphasis.primary);
      expect(n.size, UiSize.lg);
    });

    test('嵌套子节点', () {
      final n = UiNode.parse(node('grid', <String, dynamic>{
        'columns': 3,
        'children': <Map<String, dynamic>>[
          node('card', <String, dynamic>{'text': 'A'}),
          node('card', <String, dynamic>{'text': 'B'}),
        ],
      }));

      expect(n.children, hasLength(2));
      expect(n.columns, 3);
    });

    test('未知类型解析成 unknown，**不抛错**', () {
      // 插件用新版宿主的控件时，在旧宿主上应该是"这块显示不出来"，
      // 而不是整个窗口打不开
      final n = UiNode.parse(node('hologram'));
      expect(n.type, UiNodeType.unknown);
      expect(n.isUnknown, isTrue);
    });

    test('缺 type 抛错', () {
      expect(() => UiNode.parse(<String, dynamic>{'text': 'x'}),
          throwsA(isA<TsukiroException>()));
    });

    test('walk 遍历整棵树', () {
      final n = UiNode.parse(node('column', <String, dynamic>{
        'children': <Map<String, dynamic>>[
          node('row', <String, dynamic>{
            'children': <Map<String, dynamic>>[node('text'), node('icon')],
          }),
          node('text'),
        ],
      }));
      expect(n.walk().length, 5);
    });

    test('indexById 收集带 id 的节点', () {
      final n = UiNode.parse(node('column', <String, dynamic>{
        'children': <Map<String, dynamic>>[
          node('button', <String, dynamic>{'id': 'a'}),
          node('button', <String, dynamic>{'id': 'b'}),
          node('text'),
        ],
      }));
      expect(n.indexById().keys, unorderedEquals(<String>['a', 'b']));
    });
  });

  group('深度限制', () {
    test('超深抛错', () {
      var tree = node('text');
      for (var i = 0; i < UiNode.maxDepth + 3; i++) {
        tree = node('column', <String, dynamic>{
          'children': <Map<String, dynamic>>[tree],
        });
      }
      expect(() => UiNode.parse(tree), throwsA(isA<TsukiroException>()));
    });

    test('刚好在限制内的深度可以解析', () {
      var tree = node('text');
      for (var i = 0; i < UiNode.maxDepth - 1; i++) {
        tree = node('column', <String, dynamic>{
          'children': <Map<String, dynamic>>[tree],
        });
      }
      expect(() => UiNode.parse(tree), returnsNormally);
    });
  });

  group('数量限制', () {
    test('单个节点的子节点数有上限', () {
      expect(
        () => UiNode.parse(node('column', <String, dynamic>{
          'children': List<Map<String, dynamic>>.generate(
            UiNode.maxChildren + 1,
            (i) => node('text', <String, dynamic>{'text': '$i'}),
          ),
        })),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('**总节点数有上限** —— 只限深度是不够的', () {
      // 自查时实测到的：这个形状曾经能解析出 219,662 个节点，
      // 而 maxNodes 声明的是 400。深度和子节点数各自设限不够，
      // 两者**相乘**才是一棵树的大小。
      //
      // 深度 12 × 每层 60 个子节点会直接把内存打爆。
      Map<String, dynamic> wide(int depth) => <String, dynamic>{
            'type': 'column',
            'children': List<Map<String, dynamic>>.generate(
              depth == 0 ? 1 : 60,
              (i) => depth >= 3
                  ? <String, dynamic>{'type': 'text', 'text': 'x'}
                  : wide(depth + 1),
            ),
          };

      expect(() => UiNode.parse(wide(0)), throwsA(isA<TsukiroException>()));
    });

    test('刚好在节点数上限内可以解析', () {
      // maxNodes=400。60 个叶子 + 1 个根 = 61 个节点，远在限制内
      final tree = node('column', <String, dynamic>{
        'children': List<Map<String, dynamic>>.generate(
          60,
          (i) => node('text', <String, dynamic>{'text': '$i'}),
        ),
      });
      expect(() => UiNode.parse(tree), returnsNormally);
    });
    test('children 里混进非对象要报错', () {
      expect(
        () => UiNode.parse(node('column', <String, dynamic>{
          'children': <dynamic>['不是对象'],
        })),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('grid 的列数被夹到 1..8', () {
      expect(UiNode.parse(node('grid', <String, dynamic>{'columns': 99})).columns, 8);
      expect(UiNode.parse(node('grid', <String, dynamic>{'columns': 0})).columns, 1);
    });

    test('progress 被夹到 0..1', () {
      expect(UiNode.parse(node('progress', <String, dynamic>{'progress': 5})).progress, 1.0);
      expect(UiNode.parse(node('progress', <String, dynamic>{'progress': -3})).progress, 0.0);
    });

    test('文本超长抛错（不静默截断）', () {
      expect(
        () => UiNode.parse(node('text', <String, dynamic>{
          'text': 'x' * (UiNode.maxTextLength + 1),
        })),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('id 超长抛错', () {
      expect(
        () => UiNode.parse(node('text', <String, dynamic>{'id': 'x' * 200})),
        throwsA(isA<TsukiroException>()),
      );
    });
  });

  group('图片地址白名单', () {
    test('http / https 放行', () {
      expect(UiNode.parse(node('image', <String, dynamic>{'image': 'https://a.cn/x.png'})).image,
          'https://a.cn/x.png');
      expect(UiNode.parse(node('image', <String, dynamic>{'image': 'http://a.cn/x.png'})).image,
          'http://a.cn/x.png');
    });

    test('**file: 被拒绝** —— 那是读宿主私有文件的入口', () {
      expect(
        () => UiNode.parse(node('image', <String, dynamic>{'image': 'file:///etc/passwd'})),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('**data: 被拒绝** —— 一个 base64 就能塞满内存', () {
      expect(
        () => UiNode.parse(node('image', <String, dynamic>{
          'image': 'data:image/png;base64,AAAA',
        })),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('javascript: 被拒绝', () {
      expect(
        () => UiNode.parse(node('image', <String, dynamic>{'image': 'javascript:alert(1)'})),
        throwsA(isA<TsukiroException>()),
      );
    });

    test('超长 URL 被拒绝', () {
      expect(
        () => UiNode.parse(node('image', <String, dynamic>{
          'image': 'https://a.cn/${'x' * 3000}',
        })),
        throwsA(isA<TsukiroException>()),
      );
    });
  });

  group('语义化样式', () {
    test('**不接受任意颜色** —— 只接受语义级别', () {
      // 给颜色就等于给了一套 CSS，插件会开始写 #FF5722，
      // 然后深色模式下看不见。给语义，颜色由宿主按 token 决定。
      final n = UiNode.parse(node('text', <String, dynamic>{
        'color': '#FF5722',
        'emphasis': 'danger',
      }));
      expect(n.emphasis, UiEmphasis.danger);
      // color 字段根本不存在于模型里 —— 传了也没用
    });

    test('非法 emphasis / size / align 退回默认值，不抛错', () {
      final n = UiNode.parse(node('text', <String, dynamic>{
        'emphasis': 'sparkly',
        'size': 'gigantic',
        'align': 'diagonal',
      }));
      expect(n.emphasis, UiEmphasis.normal);
      expect(n.size, UiSize.md);
      expect(n.align, UiAlign.start);
    });
  });
}
