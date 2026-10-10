import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

/// 仓库根目录（packages/plugin_core/test → ../../..）
final String repoRoot = p.normalize(p.join(Directory.current.path, '..', '..'));

String readPluginManifest(String pluginDir) {
  final file = File(p.join(repoRoot, 'plugins', pluginDir, 'manifest.json'));
  if (!file.existsSync()) {
    throw StateError('找不到插件 manifest: ${file.path}（当前目录 ${Directory.current.path}）');
  }
  return file.readAsStringSync();
}

void main() {
  group('真实插件 manifest（仓库内三个测试插件）', () {
    for (final name in <String>[
      'time-plugin',
      'translate-button',
      'mini-game',
    ]) {
      test('$name 能解析且无问题', () {
        final result = parseManifestJson(readPluginManifest(name));
        if (!result.isValid) {
          fail('解析失败: ${result.issues.join("\n  ")}');
        }
        final m = result.manifest!;
        expect(m.manifestVersion, 1);
        expect(m.id, startsWith('dev.tsukiro.'));
        expect(m.name, isNotEmpty);
        expect(m.version, '1.0.0');
      });
    }

    test('time-plugin 的工具声明完整', () {
      final m = parseManifestJson(readPluginManifest('time-plugin')).manifest!;
      expect(m.tools, hasLength(1));
      final tool = m.tools.single;
      expect(tool.name, 'get_time');
      expect(tool.handler, 'handlers/get_time.js');
      expect(tool.permissions, <String>['sys.time']);
      expect(tool.timeoutMs, 5000);
      // parameters 是完整 JSON Schema，属性保留
      expect(tool.parameters['type'], 'object');
      final props = tool.parameters['properties'] as Map<String, dynamic>;
      expect(props.keys, containsAll(<String>['timezone', 'format']));
    });

    test('translate-button 的插槽与配置解析正确', () {
      final m = parseManifestJson(readPluginManifest('translate-button')).manifest!;
      expect(m.ui, hasLength(1));
      final btn = m.ui.single;
      expect(btn.slot, 'chat.toolbar');
      expect(btn.id, 'translate');
      expect(btn.type, 'button');
      expect(btn.onClickEvent, 'translate.clicked');
      expect(btn.when, <String, dynamic>{'hasMessages': true, 'isStreaming': false});
      expect(btn.permissions, <String>['model.chat', 'sys.clipboard.write']);
      expect(m.config?.section?.slot, 'settings.sections');
    });

    test('mini-game 的页面声明解析正确', () {
      final m = parseManifestJson(readPluginManifest('mini-game')).manifest!;
      expect(m.pages, hasLength(1));
      final page = m.pages.single;
      expect(page.id, 'game');
      expect(page.entry, 'pages/game.html');
      expect(page.presentation, 'window');
      expect(page.width, 440);
      expect(page.height, 580);
      expect(page.bridge, isTrue);
    });

    test('confirm 级权限被正确识别（用于安装弹窗高亮）', () {
      final m = JsonEncoder.withIndent(' ').convert(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'dev.tsukiro.risky',
        'name': '高风险示例',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'permissions': <String>['sys.time', 'screen.capture', 'a11y'],
      });
      final manifest = parseManifestJson(m).manifest!;
      final confirm = manifest.confirmLevelPermissions.map((e) => e.name).toList();
      expect(confirm, containsAll(<String>['screen.capture', 'a11y']));
      expect(confirm, isNot(contains('sys.time')));
      expect(manifest.forbiddenPermissions, isEmpty);
    });
  });

  group('必填字段校验', () {
    Map<String, dynamic> base() => <String, dynamic>{
          'manifestVersion': 1,
          'id': 'dev.tsukiro.demo',
          'name': '演示',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
        };

    test('完整 manifest 通过', () {
      expect(parseManifest(base()).isValid, isTrue);
    });

    for (final field in <String>['manifestVersion', 'id', 'name', 'version']) {
      test('缺少 $field 被拒', () {
        final json = base()..remove(field);
        final r = parseManifest(json);
        expect(r.isValid, isFalse);
        expect(r.issues.map((e) => e.path), contains(field));
      });
    }

    test('省略 runtime 对纯声明式插件合法（L1 零代码）', () {
      final json = base()..remove('runtime');
      final r = parseManifest(json);
      expect(r.isValid, isTrue, reason: r.issues.map((e) => e.toString()).join('; '));
      expect(r.manifest!.isZeroCode, isTrue);
    });

    test('声明了需要代码的能力却没有 runtime 被拒', () {
      for (final entry in <String, Object>{
        'tools': <dynamic>[
          <String, dynamic>{'name': 't', 'description': 'x', 'handler': 'h.js'},
        ],
        'ui': <dynamic>[
          // **带 onClick** —— 有回调就得有人接，这才需要 runtime。
          // 只是画出来的东西（图形、粒子、模糊）不需要，
          // 见下一条测试。
          <String, dynamic>{
            'slot': 'chat.toolbar',
            'id': 't',
            'type': 'button',
            'label': 'T',
            'onClick': <String, dynamic>{'event': 'x'},
          },
        ],
        'pages': <dynamic>[
          <String, dynamic>{'id': 'p', 'title': 'P', 'entry': 'a.html'},
        ],
      }.entries) {
        final json = base()..remove('runtime');
        json['provides'] = <String, dynamic>{entry.key: entry.value};
        final r = parseManifest(json);
        expect(r.isValid, isFalse, reason: '${entry.key} 应要求 runtime');
        expect(r.issues.map((e) => e.path), contains('runtime'));
        expect(r.issues.first.message, contains(entry.key));
      }
    });

    test('runtime 缺少 main 被拒', () {
      final json = base()..['runtime'] = <String, dynamic>{};
      final r = parseManifest(json);
      expect(r.isValid, isFalse);
      expect(r.issues.map((e) => e.path), contains('runtime.main'));
    });

    test('**纯画面元素的 ui 不需要 runtime**', () {
      // 零代码插件（美化包）加一层飘落花瓣：它只是被画出来，
      // 没有回调，所以不需要谁来接。
      // 老规则「声明了 ui 就必须有 runtime」会把它挡在门外，
      // 而作者被迫提供一个里面一行有用代码都没有的 runtime。
      final json = base()..remove('runtime');
      json['provides'] = <String, dynamic>{
        'ui': <dynamic>[
          <String, dynamic>{
            'slot': 'home.background',
            'id': 'petals',
            'type': 'particle',
            'config': <String, dynamic>{'particle': 'petal'},
          },
        ],
      };
      final r = parseManifest(json);
      expect(r.isValid, isTrue, reason: r.issues.map((e) => e.message).join('; '));
    });

    test('非对象顶层被拒', () {
      expect(parseManifestJson('[]').isValid, isFalse);
      expect(parseManifestJson('"字符串"').isValid, isFalse);
    });

    test('非法 JSON 被拒且带明确信息', () {
      final r = parseManifestJson('{ 不是 json }');
      expect(r.isValid, isFalse);
      expect(r.issues.first.message, contains('JSON'));
    });

    test('manifestVersion 高于宿主支持被拒', () {
      final json = base()..['manifestVersion'] = 999;
      final r = parseManifest(json);
      expect(r.isValid, isFalse);
      expect(r.issues.first.message, contains('升级宿主'));
    });
  });

  group('id 格式', () {
    Map<String, dynamic> withId(String id) => <String, dynamic>{
          'manifestVersion': 1,
          'id': id,
          'name': 'x',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
        };

    test('合法 id', () {
      for (final id in <String>[
        'dev.tsukiro.time',
        'com.example.my-plugin',
        'a.b',
        'io.github.user_1.plugin-2',
      ]) {
        expect(parseManifest(withId(id)).isValid, isTrue, reason: id);
      }
    });

    test('非法 id 被拒', () {
      for (final id in <String>[
        'Dev.Tsukiro.Time', // 大写
        'time', // 单段
        'dev..time', // 连续点
        'dev. tsukiro', // 空格
        '.dev.time', // 起始点
        'dev.time.', // 结尾点
        '1dev.time', // 数字开头
      ]) {
        expect(parseManifest(withId(id)).isValid, isFalse, reason: '应拒绝: $id');
      }
    });
  });

  group('version 语义化', () {
    test('合法版本', () {
      for (final v in <String>['1.0.0', '0.1.0', '1.0.0-beta', '2.3.4-rc.1']) {
        final r = parseManifest(<String, dynamic>{
          'manifestVersion': 1,
          'id': 'a.b',
          'name': 'x',
          'version': v,
          'runtime': <String, dynamic>{'main': 'index.js'},
        });
        expect(r.isValid, isTrue, reason: v);
      }
    });

    test('非法版本被拒', () {
      for (final v in <String>['1.0', 'v1.0.0', 'x', '']) {
        final r = parseManifest(<String, dynamic>{
          'manifestVersion': 1,
          'id': 'a.b',
          'name': 'x',
          'version': v,
          'runtime': <String, dynamic>{'main': 'index.js'},
        });
        expect(r.isValid, isFalse, reason: '应拒绝: "$v"');
      }
    });
  });

  group('权限声明', () {
    Map<String, dynamic> withPerms(Object perms) => <String, dynamic>{
          'manifestVersion': 1,
          'id': 'a.b',
          'name': 'x',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
          'permissions': perms,
        };

    test('字符串简写', () {
      final m = parseManifest(withPerms(<String>['sys.time'])).manifest!;
      expect(m.permissionNames, <String>['sys.time']);
      expect(m.permissions.single.reason, isNull);
    });

    test('对象写法带 reason', () {
      final m = parseManifest(withPerms(<dynamic>[
        <String, dynamic>{'name': 'sys.time', 'reason': '用于回答时间问题'},
      ])).manifest!;
      expect(m.permissions.single.reason, '用于回答时间问题');
    });

    test('两种写法混用', () {
      final m = parseManifest(withPerms(<dynamic>[
        'sys.time',
        <String, dynamic>{'name': 'ui', 'reason': '弹提示'},
      ])).manifest!;
      expect(m.permissionNames, <String>['sys.time', 'ui']);
    });

    test('未知权限名被拒（防拼错静默失效）', () {
      final r = parseManifest(withPerms(<String>['sys.tim']));
      expect(r.isValid, isFalse);
      expect(r.issues.first.message, contains('未知权限'));
    });

    test('重复权限被拒', () {
      final r = parseManifest(withPerms(<String>['sys.time', 'sys.time']));
      expect(r.isValid, isFalse);
      expect(r.issues.first.message, contains('重复'));
    });

    test('缺少 name 的对象项被拒', () {
      final r = parseManifest(withPerms(<dynamic>[
        <String, dynamic>{'reason': '没说是什么权限'},
      ]));
      expect(r.isValid, isFalse);
    });
  });

  group('工具声明', () {
    Map<String, dynamic> withTools(Object tools) => <String, dynamic>{
          'manifestVersion': 1,
          'id': 'a.b',
          'name': 'x',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
          'provides': <String, dynamic>{'tools': tools},
        };

    test('工具名必须是 snake_case', () {
      for (final name in <String>['getTime', 'get-time', 'Get_Time', 'get time', '1get']) {
        final r = parseManifest(withTools(<dynamic>[
          <String, dynamic>{
            'name': name,
            'description': 'x',
            'handler': 'h.js',
          },
        ]));
        expect(r.isValid, isFalse, reason: '应拒绝工具名: $name');
      }
    });

    test('description 不能为空（它决定模型能否正确调用）', () {
      final r = parseManifest(withTools(<dynamic>[
        <String, dynamic>{'name': 'ok_name', 'description': '  ', 'handler': 'h.js'},
      ]));
      expect(r.isValid, isFalse);
      expect(r.issues.first.path, 'provides.tools[0].description');
    });

    test('handler 不能是绝对路径或含 ..', () {
      for (final h in <String>['/etc/passwd', '../evil.js', 'a/../../b.js']) {
        final r = parseManifest(withTools(<dynamic>[
          <String, dynamic>{'name': 'ok_name', 'description': 'x', 'handler': h},
        ]));
        expect(r.isValid, isFalse, reason: '应拒绝 handler: $h');
      }
    });

    test('同一插件内工具重名被拒', () {
      final r = parseManifest(withTools(<dynamic>[
        <String, dynamic>{'name': 'same', 'description': 'x', 'handler': 'a.js'},
        <String, dynamic>{'name': 'same', 'description': 'y', 'handler': 'b.js'},
      ]));
      expect(r.isValid, isFalse);
      expect(r.issues.first.message, contains('重复'));
    });

    test('timeoutMs 被夹到上限 60s', () {
      final m = parseManifest(withTools(<dynamic>[
        <String, dynamic>{
          'name': 'slow',
          'description': 'x',
          'handler': 'h.js',
          'timeoutMs': 999999,
        },
      ])).manifest!;
      expect(m.tools.single.timeoutMs, 60000);
    });
  });

  group('parameters 简写展开', () {
    test('简单类型映射并全部标为 required', () {
      final errors = <ManifestIssue>[];
      final schema = expandParameterShorthand(
        <String, dynamic>{'limit': 'number', 'keyword': 'string'},
        errors,
        'p',
      )!;
      expect(errors, isEmpty);
      expect(schema['type'], 'object');
      expect(schema['required'], <String>['limit', 'keyword']);
      final props = schema['properties'] as Map<String, dynamic>;
      expect((props['limit'] as Map<String, dynamic>)['type'], 'number');
      expect((props['keyword'] as Map<String, dynamic>)['type'], 'string');
    });

    test('已经是完整 JSON Schema 时原样返回', () {
      final errors = <ManifestIssue>[];
      final full = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'a': <String, dynamic>{'type': 'string'},
        },
        'required': <String>[],
      };
      expect(expandParameterShorthand(full, errors, 'p'), same(full));
      expect(errors, isEmpty);
    });

    test('混合写法：值为 schema 片段', () {
      final errors = <ManifestIssue>[];
      final schema = expandParameterShorthand(
        <String, dynamic>{
          'tz': <String, dynamic>{'type': 'string', 'description': '时区'},
        },
        errors,
        'p',
      )!;
      final props = schema['properties'] as Map<String, dynamic>;
      expect((props['tz'] as Map<String, dynamic>)['description'], '时区');
    });

    test('null 展开为空参数对象', () {
      final errors = <ManifestIssue>[];
      final schema = expandParameterShorthand(null, errors, 'p')!;
      expect(schema['properties'], isEmpty);
      expect(errors, isEmpty);
    });

    test('未知简写类型报错', () {
      final errors = <ManifestIssue>[];
      expandParameterShorthand(<String, dynamic>{'x': 'notatype'}, errors, 'p');
      expect(errors, hasLength(1));
    });
  });

  group('网络白名单', () {
    Map<String, dynamic> withNetwork(Object network) => <String, dynamic>{
          'manifestVersion': 1,
          'id': 'a.b',
          'name': 'x',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
          'network': network,
        };

    test('合法白名单', () {
      final m = parseManifest(withNetwork(<String, dynamic>{
        'allow': <String>['https://api.example.com'],
      })).manifest!;
      expect(m.network!.allow, <String>['https://api.example.com']);
      expect(m.network!.isDisabled, isFalse);
    });

    test('不声明 network = 完全禁止网络', () {
      final m = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
      }).manifest!;
      expect(m.network, isNull);
    });

    test('空 allow 视为禁用', () {
      final m = parseManifest(withNetwork(<String, dynamic>{
        'allow': <String>[],
      })).manifest!;
      expect(m.network!.isDisabled, isTrue);
    });

    test('不带 scheme 的条目被拒', () {
      final r = parseManifest(withNetwork(<String, dynamic>{
        'allow': <String>['api.example.com'],
      }));
      expect(r.isValid, isFalse);
    });

    test('非法 scheme 被拒', () {
      final r = parseManifest(withNetwork(<String, dynamic>{
        'allow': <String>['file:///etc/passwd'],
      }));
      expect(r.isValid, isFalse);
    });

    test('maxRequestsPerMinute 只能被夹到宿主上限内', () {
      final m = parseManifest(withNetwork(<String, dynamic>{
        'allow': <String>['https://a.com'],
        'maxRequestsPerMinute': 100000,
      })).manifest!;
      expect(m.network!.maxRequestsPerMinute, 600);
    });
  });

  group('UI 与页面声明', () {
    Map<String, dynamic> withProvides(Map<String, dynamic> provides) => <String, dynamic>{
          'manifestVersion': 1,
          'id': 'a.b',
          'name': 'x',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
          'provides': provides,
        };

    test('未知控件类型被拒', () {
      final r = parseManifest(withProvides(<String, dynamic>{
        'ui': <dynamic>[
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 'x', 'type': '不存在的类型', 'label': 'x'},
        ],
      }));
      expect(r.isValid, isFalse);
    });

    test('divider 不需要 label', () {
      final r = parseManifest(withProvides(<String, dynamic>{
        'ui': <dynamic>[
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 'sep', 'type': 'divider'},
        ],
      }));
      expect(r.isValid, isTrue, reason: r.issues.join(','));
    });

    test('非 divider 缺 label 被拒', () {
      final r = parseManifest(withProvides(<String, dynamic>{
        'ui': <dynamic>[
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 'x', 'type': 'button'},
        ],
      }));
      expect(r.isValid, isFalse);
    });

    test('同插槽内 id 重复被拒', () {
      final r = parseManifest(withProvides(<String, dynamic>{
        'ui': <dynamic>[
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 'same', 'type': 'button', 'label': 'a'},
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 'same', 'type': 'button', 'label': 'b'},
        ],
      }));
      expect(r.isValid, isFalse);
    });

    test('不同插槽可用同一个 id', () {
      final r = parseManifest(withProvides(<String, dynamic>{
        'ui': <dynamic>[
          <String, dynamic>{'slot': 'chat.toolbar', 'id': 'same', 'type': 'button', 'label': 'a'},
          <String, dynamic>{'slot': 'chat.header', 'id': 'same', 'type': 'button', 'label': 'b'},
        ],
      }));
      expect(r.isValid, isTrue, reason: r.issues.join(','));
    });

    test('页面 entry 必须是 .html', () {
      final r = parseManifest(withProvides(<String, dynamic>{
        'pages': <dynamic>[
          <String, dynamic>{'id': 'p', 'title': 't', 'entry': 'pages/x.js'},
        ],
      }));
      expect(r.isValid, isFalse);
    });

    test('未知 presentation 被拒', () {
      final r = parseManifest(withProvides(<String, dynamic>{
        'pages': <dynamic>[
          <String, dynamic>{'id': 'p', 'title': 't', 'entry': 'a.html', 'presentation': '悬浮'},
        ],
      }));
      expect(r.isValid, isFalse);
    });

    test('预留段（overlays/skills/personas/mcp/memory/layout/replaces/data）原样保留', () {
      final m = parseManifest(withProvides(<String, dynamic>{
        'overlays': <dynamic>[
          <String, dynamic>{'id': 'ball', 'entry': 'pages/ball.html'},
        ],
        'skills': <dynamic>[
          <String, dynamic>{'id': 'polite'},
        ],
        'personas': <dynamic>[
          <String, dynamic>{'id': 'yuki'},
        ],
        'mcp': <String, dynamic>{'servers': <dynamic>[]},
        'memory': <String, dynamic>{'provider': 'memory/index.js'},
        'layout': <String, dynamic>{'mode': 'compact'},
        'replaces': <String, dynamic>{
          'ui': <dynamic>['chat.main'],
        },
        'data': <String, dynamic>{'messages': true},
      })).manifest!;
      expect(m.provides.rawReserved.keys, containsAll(<String>[
        'overlays', 'skills', 'personas', 'mcp', 'memory',
        'layout', 'replaces', 'data',
      ]));
      // 预留段虽然不执行，但要有明确的访问器
      expect(m.provides.layout!['mode'], 'compact');
      expect(m.provides.declaresLayout, isTrue);
      expect(m.provides.declaresReplacements, isTrue);
      expect(m.provides.replaces!['ui'], <dynamic>['chat.main']);
    });

    test('theme 不再是原始保留段，而是强类型', () {
      final m = parseManifest(withProvides(<String, dynamic>{
        'theme': <String, dynamic>{
          'id': 'sakura',
          'name': '樱花',
          'tokens': <String, dynamic>{'color.primary': '#FF6B9D'},
        },
      })).manifest!;
      expect(m.provides.rawReserved.containsKey('theme'), isFalse);
      expect(m.themes, hasLength(1));
      expect(m.themes.single.id, 'sakura');
    });

    test('harness 字段放行且不产生注册项', () {
      final r = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': 'a.b',
        'name': 'x',
        'version': '1.0.0',
        'runtime': <String, dynamic>{'main': 'index.js'},
        'harness': <String, dynamic>{
          'runtime': 'harness/index.js',
          'steps': <dynamic>[
            <String, dynamic>{'id': 'pre-think', 'replace': 'beforeModelCall'},
          ],
        },
      });
      expect(r.isValid, isTrue, reason: r.issues.join(','));
      expect(r.manifest!.harness, isNotNull);
      // L7 预留，本阶段不产生任何注册项
      expect(r.manifest!.tools, isEmpty);
      expect(r.manifest!.ui, isEmpty);
      expect(r.manifest!.pages, isEmpty);
    });
  });

  group('宿主兼容性', () {
    PluginManifest build({String? minHostVersion, String? hostApi}) =>
        parseManifest(<String, dynamic>{
          'manifestVersion': 1,
          'id': 'a.b',
          'name': 'x',
          'version': '1.0.0',
          'runtime': <String, dynamic>{'main': 'index.js'},
          if (minHostVersion != null) 'minHostVersion': minHostVersion,
          if (hostApi != null) 'hostApi': hostApi,
        }).manifest!;

    test('无要求时总是兼容', () {
      expect(checkHostCompatibility(build(), '0.1.0'), isNull);
    });

    test('宿主版本偏低被拒', () {
      final msg = checkHostCompatibility(build(minHostVersion: '0.2.0'), '0.1.0');
      expect(msg, isNotNull);
      expect(msg, contains('0.2.0'));
    });

    test('宿主版本达标通过', () {
      expect(checkHostCompatibility(build(minHostVersion: '0.1.0'), '0.1.0'), isNull);
      expect(checkHostCompatibility(build(minHostVersion: '0.1.0'), '1.0.0'), isNull);
    });

    test('hostApi major 不匹配被拒', () {
      final msg = checkHostCompatibility(build(hostApi: '^2.0.0'), '1.0.0');
      expect(msg, isNotNull);
    });

    test('hostApi 匹配通过', () {
      expect(checkHostCompatibility(build(hostApi: '^1.0.0'), '1.3.2'), isNull);
    });
  });

  group('错误收集', () {
    test('一次性返回全部问题，而不是只报第一个', () {
      final r = parseManifest(<String, dynamic>{
        'manifestVersion': 1,
        'id': '非法 ID',
        'name': 'x',
        'version': 'bad',
        'runtime': <String, dynamic>{'main': '/abs/path.js'},
        'permissions': <String>['瞎写'],
      });
      expect(r.issues.length, greaterThanOrEqualTo(4),
          reason: '安装流程要一次告诉作者所有问题，逐个试错是折磨');
    });
  });
}
