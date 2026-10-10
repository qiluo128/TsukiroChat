/// 校验仓库里所有插件的清单与代码可加载性。
///
/// **为什么值得单独一个测试**：清单写错（权限名不对、插槽名拼错、
/// handler 路径不存在）在构建时不会报错，装到手机上也是**静默**失败 ——
/// 插件就是"不出现"。这类问题应该在 CI 里就拦住。
///
/// 测试直接从仓库根的 `plugins/` 读，与 `assets/demo_plugins/` 无关 ——
/// 那份是构建产物，而且只有被选中的几个。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:tsukiro_chat/plugin/plugin_bundle.dart';

/// 从 `packages/host_app/test/` 往上找到仓库根。
Directory repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    if (Directory(p.join(dir.path, 'plugins')).existsSync()) return dir;
    dir = dir.parent;
  }
  throw StateError('找不到仓库根（向上找了 5 层都没有 plugins/）');
}

void main() {
  late List<Directory> pluginDirs;

  setUpAll(() {
    final root = repoRoot();
    pluginDirs = Directory(p.join(root.path, 'plugins'))
        .listSync()
        .whereType<Directory>()
        .toList(growable: false);
  });

  test('至少能找到几个插件', () {
    expect(pluginDirs, isNotEmpty);
  });

  group('每个插件的清单', () {
    test('全部合法', () {
      final failures = <String>[];

      for (final dir in pluginDirs) {
        final name = p.basename(dir.path);
        final file = File(p.join(dir.path, 'manifest.json'));
        if (!file.existsSync()) {
          failures.add('$name: 没有 manifest.json');
          continue;
        }
        final parsed = parseManifestJson(file.readAsStringSync());
        if (!parsed.isValid) {
          failures.add('$name:\n    ${parsed.issues.join('\n    ')}');
        }
      }

      expect(failures, isEmpty, reason: '清单有问题：\n${failures.join('\n')}');
    });

    test('声明的权限都是权限目录里认识的', () {
      final unknown = <String>[];

      for (final dir in pluginDirs) {
        final file = File(p.join(dir.path, 'manifest.json'));
        if (!file.existsSync()) continue;
        final parsed = parseManifestJson(file.readAsStringSync());
        if (!parsed.isValid) continue;

        for (final declared in parsed.manifest!.permissions) {
          // 声明即上限：插件能声明的必须是目录里认识的名字，
          // 否则门禁会按「未知权限」拒绝，而插件作者会以为声明成功了
          if (!isKnownPermission(declared.name)) {
            unknown.add('${p.basename(dir.path)}: ${declared.name}');
          }
        }
      }

      expect(unknown, isEmpty,
          reason: '这些权限名不在目录里，调用时会被门禁拒：\n  ${unknown.join('\n  ')}');
    });

    test('插槽名格式合法（**不是**必须在基线清单里）', () {
      // 这条测试原来断言「插槽名必须在 knownSlots 里」，那是白名单时代的
      // 语义。两轮前改成了「knownSlots 只是基线，格式对就收」——
      // 因为插槽不该是内核的白名单：加一个挂载位置应该是"界面里多写一行"，
      // 而不是"改内核 + 改这份清单"。
      //
      // 所以现在校验的是**格式**。knownSlots 仍然保留，供自省和文档用。
      final malformed = <String>[];

      for (final dir in pluginDirs) {
        final file = File(p.join(dir.path, 'manifest.json'));
        if (!file.existsSync()) continue;
        final parsed = parseManifestJson(file.readAsStringSync());
        if (!parsed.isValid) continue;

        void checkUi(List<UiDeclaration> list) {
          for (final ui in list) {
            if (!SlotRegistry.isWellFormedSlot(ui.slot)) {
              malformed.add('${p.basename(dir.path)}: ${ui.slot}');
            }
            checkUi(ui.children);
          }
        }

        checkUi(parsed.manifest!.provides.ui);
      }

      // 格式非法的插槽会被注册表**丢弃**（只有格式对但界面没声明的才会
      // 先收下、等界面声明）。所以这里判失败。
      expect(malformed, isEmpty,
          reason: '这些插槽名格式不合法，注册表会直接丢掉：\n  ${malformed.join('\n  ')}');
    });
  });

  group('每个插件的代码', () {
    test('能完整加载（handler 文件都在、ES module 能转换）', () async {
      final failures = <String>[];

      for (final dir in pluginDirs) {
        final name = p.basename(dir.path);
        try {
          final bundle = await loadBundleFromDirectory(dir.path);
          if (bundle.manifest.isZeroCode) continue;

          // 转换一遍 —— 这一步会暴露 `import` 语句、坏语法定位之类的问题
          toScriptExpression(bundle.entrySource, label: '$name/index.js');
          for (final entry in bundle.handlerSources.entries) {
            toScriptExpression(entry.value, label: '$name/${entry.key}');
          }
        } catch (e) {
          failures.add('$name: $e');
        }
      }

      expect(failures, isEmpty, reason: '加载失败：\n${failures.join('\n')}');
    });

    test('入口里没用到未声明的原语', () async {
      // 只做静态粗筛：找出 `tsukiro.<domain>.<action>(` 形式的调用，
      // 看域名是否在声明的权限里。
      //
      // **不做精确判断** —— 真正的把关是运行时的门禁。
      // 这个测试的价值在于「写代码时就能发现漏声明」，而不是替代门禁。
      final suspicious = <String>[];

      for (final dir in pluginDirs) {
        final name = p.basename(dir.path);
        final indexFile = File(p.join(dir.path, 'index.js'));
        if (!indexFile.existsSync()) continue;

        final parsed = parseManifestJson(
          File(p.join(dir.path, 'manifest.json')).readAsStringSync(),
        );
        if (!parsed.isValid) continue;

        final declared = parsed.manifest!.permissions.map((d) => d.name).toSet();
        final source = indexFile.readAsStringSync();

        // tsukiro.sys.time( / tsukiro.ui.toast(
        for (final m in RegExp(r'tsukiro\.([a-z]+)\.([a-zA-Z_]+)\s*\(')
            .allMatches(source)) {
          final primitive = '${m.group(1)}.${m.group(2)}';
          if (primitive.startsWith('lifecycle.') ||
              primitive.startsWith('event.') ||
              primitive.startsWith('log.') ||
              primitive.startsWith('__')) {
            continue;
          }
          final required = requiredPermissionFor(primitive);
          if (required == null) continue; // 无需权限
          if (!declared.contains(required)) {
            suspicious.add('$name: 调了 $primitive（需要 $required），但只声明了 $declared');
          }
        }
      }

      expect(suspicious, isEmpty, reason: suspicious.join('\n'));
    });
  });

  group('status-panel（演示 UI 渲染用）', () {
    test('声明了三个不同插槽的控件', () {
      final dir = pluginDirs.firstWhere(
        (d) => p.basename(d.path) == 'status-panel',
        orElse: () => throw StateError('找不到 status-panel 插件'),
      );
      final parsed = parseManifestJson(
        File(p.join(dir.path, 'manifest.json')).readAsStringSync(),
      );
      expect(parsed.isValid, isTrue, reason: parsed.issues.join('；'));

      final slots = parsed.manifest!.provides.ui.map((u) => u.slot).toSet();
      expect(slots, containsAll(<String>['chat.toolbar', 'agent.actions', 'agent.sections']));

      // 覆盖到多种控件类型，才能验证渲染器不是只支持按钮
      final types = <String>{};
      void collect(List<UiDeclaration> list) {
        for (final u in list) {
          types.add(u.type);
          collect(u.children);
        }
      }

      collect(parsed.manifest!.provides.ui);
      expect(types, containsAll(<String>['button', 'section', 'text', 'toggle']));
    });

    test('按钮的 onClick 事件名与 index.js 里注册的对得上', () {
      final dir = pluginDirs.firstWhere((d) => p.basename(d.path) == 'status-panel');
      final parsed = parseManifestJson(
        File(p.join(dir.path, 'manifest.json')).readAsStringSync(),
      );
      final source = File(p.join(dir.path, 'index.js')).readAsStringSync();

      final events = <String>[];
      void collect(List<UiDeclaration> list) {
        for (final u in list) {
          if (u.onClickEvent != null) events.add(u.onClickEvent!);
          collect(u.children);
        }
      }

      collect(parsed.manifest!.provides.ui);
      expect(events, isNotEmpty);

      for (final e in events) {
        expect(source, contains("tsukiro.event.on('$e'"),
            reason: '清单里声明了事件 $e，但 index.js 里没有监听它 —— 点了会毫无反应');
      }
    });
  });

  test('manifest.json 都是合法 JSON 且带 UTF-8 中文', () {
    for (final dir in pluginDirs) {
      final file = File(p.join(dir.path, 'manifest.json'));
      if (!file.existsSync()) continue;
      // jsonDecode 对损坏的编码会抛
      final decoded = jsonDecode(file.readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
    }
  });
}
