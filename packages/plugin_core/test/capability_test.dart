/// 能力市场：插件提供能力、别的插件调用。
///
/// 这个文件守的是**插件之间那道边界** —— 不能直连、要过权限、
/// 要能分辨失败原因、要挡得住互相递归。
library;

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  CapabilityDeclaration decl(String name, [String handler = 'h.js']) =>
      CapabilityDeclaration(name: name, description: '$name 的说明', handler: handler);

  CapabilityRegistry registryWith(Map<String, List<CapabilityDeclaration>> providers) {
    final r = CapabilityRegistry();
    providers.forEach((id, list) {
      r.registerProvider(id, providerVersion: '1.0.0', providerName: '插件 $id', declarations: list);
    });
    return r;
  }

  group('注册表', () {
    test('按 (提供方, 名字) 寻址', () {
      final r = registryWith(<String, List<CapabilityDeclaration>>{
        'dev.a.vector': <CapabilityDeclaration>[decl('vector.search')],
      });

      expect(r.find('dev.a.vector', 'vector.search'), isNotNull);
      expect(r.find('dev.a.vector', 'vector.nope'), isNull);
      expect(r.find('dev.other', 'vector.search'), isNull);
    });

    test('**两个插件可以提供同名能力** —— 不强制全局唯一', () {
      // 一个本地、一个云端，都叫 text.summarize 是合理的。
      // 硬要唯一反而逼提供方起怪名字。
      final r = registryWith(<String, List<CapabilityDeclaration>>{
        'dev.a.local': <CapabilityDeclaration>[decl('text.summarize')],
        'dev.b.cloud': <CapabilityDeclaration>[decl('text.summarize')],
      });

      expect(r.findByName('text.summarize'), hasLength(2));
      expect(r.find('dev.a.local', 'text.summarize'), isNotNull);
      expect(r.find('dev.b.cloud', 'text.summarize'), isNotNull);
    });

    test('权限名用冒号分隔提供方与能力名', () {
      final r = registryWith(<String, List<CapabilityDeclaration>>{
        'dev.a.vector': <CapabilityDeclaration>[decl('vector.search')],
      });

      // 能力名自己就带点（vector.search），用点会让"哪部分是提供方"
      // 变得要靠猜
      expect(r.all.single.permission, 'capability:dev.a.vector:vector.search');
    });

    test('重复注册同一提供方会替换（升级场景）', () {
      final r = registryWith(<String, List<CapabilityDeclaration>>{
        'dev.a': <CapabilityDeclaration>[decl('one'), decl('two')],
      });
      r.registerProvider('dev.a',
          providerVersion: '2.0.0',
          providerName: '插件 dev.a',
          declarations: <CapabilityDeclaration>[decl('three')]);

      expect(r.all, hasLength(1));
      expect(r.find('dev.a', 'one'), isNull);
      expect(r.find('dev.a', 'three'), isNotNull);
    });

    test('注销把该提供方的能力全清掉', () {
      final r = registryWith(<String, List<CapabilityDeclaration>>{
        'dev.a': <CapabilityDeclaration>[decl('one'), decl('two')],
        'dev.b': <CapabilityDeclaration>[decl('three')],
      });
      expect(r.unregisterProvider('dev.a'), 2);
      expect(r.all, hasLength(1));
      expect(r.providerCount, 1);
    });
  });

  group('声明解析', () {
    test('需要 name 与 handler', () {
      expect(CapabilityDeclaration.parse(<String, dynamic>{'name': 'x'}), isNull);
      expect(CapabilityDeclaration.parse(<String, dynamic>{'handler': 'h.js'}), isNull);
      expect(
        CapabilityDeclaration.parse(<String, dynamic>{'name': 'x', 'handler': 'h.js'}),
        isNotNull,
      );
    });

    test('畸形条目让清单校验失败，并指出是哪一条', () {
      final m = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'capabilities': <dynamic>[
            <String, dynamic>{'name': 'good.one', 'handler': 'h1.js'},
            <String, dynamic>{'name': 'bad'}, // 缺 handler
            <String, dynamic>{'name': 'good.two', 'handler': 'h2.js'},
          ],
        },
      });

      // **不静默少提供一个能力。**
      //
      // 少给一个的话，调用方拿到的是「找不到能力」，
      // 而真正的原因（清单里某一条写错了）在几层之外。
      // 畸形声明是打包错误，该在安装时就告诉作者。
      expect(m.manifest, isNull);
      expect(m.issues.any((i) => i.path == 'provides.capabilities[1]'), isTrue,
          reason: '要能定位到是哪一条坏了');
    });

    test('同一插件内能力名重复被拒绝', () {
      final m = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'provides': <String, dynamic>{
          'capabilities': <dynamic>[
            <String, dynamic>{'name': 'dup', 'handler': 'h1.js'},
            <String, dynamic>{'name': 'dup', 'handler': 'h2.js'},
          ],
        },
      });

      expect(m.manifest, isNull);
      expect(m.issues.any((i) => i.message.contains('重复')), isTrue);
    });
  });

  group('调用请求', () {
    test('缺 name 抛错', () {
      expect(() => CapabilityRequest.parse(<String, dynamic>{'provider': 'a'}),
          throwsA(isA<TsukiroException>()));
    });

    test('只给 name 时 provider 为空 —— 由宿主去挑', () {
      final r = CapabilityRequest.parse(<String, dynamic>{
        'name': 'vector.search',
        'args': <String, dynamic>{'q': 'x'},
      });
      expect(r.providerId, isEmpty);
      expect(r.args['q'], 'x');
    });
  });

  group('结果', () {
    test('成功带值', () {
      final ok = CapabilityResult.success(<String, dynamic>{'rows': <dynamic>[]});
      expect(ok.ok, isTrue);
      expect(ok.toJson()['value'], isNotNull);
    });

    test('失败带可分辨的错误码 —— 调用方要知道是哪种失败', () {
      final fail = CapabilityResult.failure('permissionDenied', '没权限');
      expect(fail.ok, isFalse);
      expect((fail.toJson()['error'] as Map)['code'], 'permissionDenied');
    });
  });

  group('递归', () {
    test('深度上限存在且是个小数字', () {
      // 两个互相调用的插件会一直转下去，而且是跨 WebView 的递归，
      // 从堆栈上看不出来。所以必须有显式上限。
      expect(maxCapabilityDepth, greaterThan(0));
      expect(maxCapabilityDepth, lessThanOrEqualTo(8));
    });
  });
}
