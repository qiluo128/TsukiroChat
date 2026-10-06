import 'package:test/test.dart';
import 'package:plugin_core/plugin_core.dart';

void main() {
  test('解析 web 和 flame Surface，并区分入口类型', () {
    final result = parseManifest(<String, dynamic>{
      'manifestVersion': 1,
      'id': 'dev.test.surface',
      'name': 'Surface',
      'version': '1.0.0',
      'provides': <String, dynamic>{
        'surfaces': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'editor',
            'kind': 'web',
            'slot': 'agent.sections',
            'entry': 'surfaces/editor.html',
            'capabilities': <String>['interaction', 'richText'],
          },
          <String, dynamic>{
            'id': 'game',
            'kind': 'flame',
            'slot': 'agent.sections',
            'gameType': 'demo.surface',
            'capabilities': <String>['interaction', 'animation'],
          },
        ],
      },
    });

    expect(result.isValid, isTrue, reason: result.issues.toString());
    final surfaces = result.manifest!.provides.surfaces;
    expect(surfaces, hasLength(2));
    expect(surfaces.first.isWeb, isTrue);
    expect(surfaces.last.isFlame, isTrue);
  });

  test('SurfaceRegistry 按插件注册、查询和注销', () {
    final manifest = parseManifest(<String, dynamic>{
      'manifestVersion': 1,
      'id': 'dev.test.surface',
      'name': 'Surface',
      'version': '1.0.0',
      'provides': <String, dynamic>{
        'surfaces': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'game',
            'kind': 'flame',
            'slot': 'agent.sections',
            'gameType': 'demo.surface',
          },
        ],
      },
    }).manifest!;
    final registry = SurfaceRegistry()..registerPlugin(manifest);
    expect(registry.find('dev.test.surface', 'game'), isNotNull);
    expect(registry.findByGameType('demo.surface'), isNotNull);
    expect(registry.unregisterPlugin('dev.test.surface'), 1);
    expect(registry.length, 0);
  });

  test('Surface 声明缺少 kind 入口时拒绝', () {
    final result = parseManifest(<String, dynamic>{
      'manifestVersion': 1,
      'id': 'dev.test.bad-surface',
      'name': 'Bad',
      'version': '1.0.0',
      'provides': <String, dynamic>{
        'surfaces': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'bad', 'kind': 'flame', 'slot': 'x'},
        ],
      },
    });
    expect(result.isValid, isFalse);
  });
}
