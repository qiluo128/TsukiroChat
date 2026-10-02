import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

/// 仓库根目录（packages/plugin_core/test → ../../..）
final String repoRoot = p.normalize(p.join(Directory.current.path, '..', '..'));

/// 在内存里造一个 zip。
Uint8List buildZip(Map<String, String> files, {Map<String, int> modes = const <String, int>{}}) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    final f = ArchiveFile(name, bytes.length, bytes);
    final mode = modes[name];
    if (mode != null) f.mode = mode;
    archive.addFile(f);
  });
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw StateError('ZipEncoder 返回 null');
  return Uint8List.fromList(encoded);
}

/// 把磁盘上的插件目录打成 zip（用于真实插件的端到端测试）。
Uint8List zipDirectory(String pluginName) {
  final dir = Directory(p.join(repoRoot, 'plugins', pluginName));
  if (!dir.existsSync()) {
    throw StateError('找不到插件目录: ${dir.path}');
  }
  final archive = Archive();
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final rel = p.relative(entity.path, from: dir.path).replaceAll(p.separator, '/');
    final bytes = entity.readAsBytesSync();
    archive.addFile(ArchiveFile(rel, bytes.length, bytes));
  }
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw StateError('ZipEncoder 返回 null');
  return Uint8List.fromList(encoded);
}

const reader = ZipReader();

void main() {
  group('正常 zip', () {
    test('解析并读取文件', () {
      final archive = reader.read(buildZip(<String, String>{
        'manifest.json': '{"a":1}',
        'index.js': 'console.log(1)',
      }));
      expect(archive.inspection.isSafe, isTrue,
          reason: archive.inspection.issues.join('; '));
      expect(archive.readText('manifest.json'), '{"a":1}');
      expect(archive.readText('index.js'), 'console.log(1)');
      expect(archive.readBytes('manifest.json'), isNotNull);
    });

    test('readText 对不存在的文件返回 null', () {
      final archive = reader.read(buildZip(<String, String>{'manifest.json': '{}'}));
      expect(archive.readText('nope.js'), isNull);
    });

    test('readJson 解析成功', () {
      final archive = reader.read(buildZip(<String, String>{
        'manifest.json': '{"id":"a.b","n":1}',
      }));
      expect(archive.readJson('manifest.json'), <String, dynamic>{'id': 'a.b', 'n': 1});
    });

    test('readJson 对非法 JSON 抛 INVALID_MANIFEST', () {
      final archive = reader.read(buildZip(<String, String>{'manifest.json': '{坏}'}));
      expect(
        () => archive.readJson('manifest.json'),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.invalidManifest,
        )),
      );
    });

    test('readJson 对顶层非对象抛 INVALID_MANIFEST', () {
      final archive = reader.read(buildZip(<String, String>{'manifest.json': '[]'}));
      expect(() => archive.readJson('manifest.json'),
          throwsA(isA<TsukiroException>()));
    });

    test('单层顶层目录布局', () {
      final archive = reader.read(buildZip(<String, String>{
        'time-plugin-1.0.0/manifest.json': '{}',
        'time-plugin-1.0.0/index.js': 'x',
      }));
      expect(archive.inspection.isSafe, isTrue,
          reason: archive.inspection.issues.join('; '));
      expect(archive.readText('manifest.json'), '{}');
      expect(archive.readText('index.js'), 'x');
    });

    test('paths 列出插件根下的文件', () {
      final archive = reader.read(buildZip(<String, String>{
        'manifest.json': '{}',
        'handlers/get_time.js': 'x',
      }));
      expect(archive.paths, containsAll(<String>['manifest.json', 'handlers/get_time.js']));
    });
  });

  group('Zip Slip —— 真实 zip', () {
    test('含 ../evil.txt 的包被拒，且恶意内容不被读进内存', () {
      final archive = reader.read(buildZip(<String, String>{
        'manifest.json': '{}',
        'index.js': 'x',
        '../evil-traversal.txt': '如果你在沙箱外看到这个文件，说明防护没生效',
      }));

      expect(archive.inspection.isSafe, isFalse);
      expect(
        archive.inspection.fatalIssues.map((i) => i.path),
        contains('../evil-traversal.txt'),
      );
      // 关键：恶意条目不得出现在可读文件里
      expect(archive.paths, isNot(contains('../evil-traversal.txt')));
      expect(archive.readText('../evil-traversal.txt'), isNull);
    });

    test('深层穿越与绝对路径同样被拒', () {
      for (final evil in <String>['../../etc/passwd', '/etc/shadow', 'a/../../b']) {
        final archive = reader.read(buildZip(<String, String>{
          'manifest.json': '{}',
          evil: 'x',
        }));
        expect(archive.inspection.isSafe, isFalse, reason: evil);
      }
    });

    test('合法文件仍然可读（拒绝恶意条目不影响其余）', () {
      final archive = reader.read(buildZip(<String, String>{
        'manifest.json': '{"ok":true}',
        'index.js': 'good',
        '../evil.txt': 'bad',
      }));
      expect(archive.readText('index.js'), 'good');
      expect(archive.readJson('manifest.json'), <String, dynamic>{'ok': true});
    });
  });

  group('符号链接 —— 真实 zip', () {
    test('mode 为符号链接的条目被拒', () {
      final archive = reader.read(buildZip(
        <String, String>{'manifest.json': '{}', 'link': '/etc/passwd'},
        modes: <String, int>{'link': 0xA1FF}, // 0xA000 = symlink
      ));
      expect(archive.inspection.isSafe, isFalse);
      expect(
        archive.inspection.fatalIssues.map((i) => i.message),
        contains(contains('符号链接')),
      );
    });
  });

  group('畸形输入', () {
    test('不是 zip 的字节流抛 INVALID_PACKAGE', () {
      expect(
        () => reader.read(Uint8List.fromList(utf8.encode('这不是 zip'))),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.invalidPackage,
        )),
      );
    });

    test('空字节流抛 INVALID_PACKAGE', () {
      expect(() => reader.read(Uint8List(0)), throwsA(isA<TsukiroException>()));
    });

    test('截断的 zip 抛 INVALID_PACKAGE 而不是崩溃', () {
      final full = buildZip(<String, String>{'manifest.json': '{"a":1}', 'index.js': 'x'});
      final truncated = Uint8List.sublistView(full, 0, full.length ~/ 2);
      expect(
        () => reader.read(Uint8List.fromList(truncated)),
        throwsA(isA<TsukiroException>()),
      );
    });
  });

  group('真实插件端到端：zip → 检查 → 解析 manifest → 注册', () {
    for (final name in <String>['time-plugin', 'translate-button', 'mini-game']) {
      test('$name 全链路通过', () {
        // 1. 打成 zip
        final bytes = zipDirectory(name);

        // 2. 包检查
        final archive = reader.read(bytes);
        expect(
          archive.inspection.isSafe,
          isTrue,
          reason: archive.inspection.issues.join('\n  '),
        );
        expect(archive.inspection.manifestPath, 'manifest.json');

        // 3. 解析 manifest
        final json = archive.readJson('manifest.json');
        expect(json, isNotNull);
        final parsed = parseManifest(json!);
        expect(parsed.isValid, isTrue, reason: parsed.issues.join('\n  '));
        final manifest = parsed.manifest!;

        // 4. 声明的文件确实都在包里
        // 入口文件必须真的在包里（零代码插件没有入口，跳过这一项）
        final runtime = manifest.runtime;
        if (runtime != null) {
          expect(archive.paths, contains(runtime.main), reason: '入口文件缺失');
        }
        for (final tool in manifest.tools) {
          expect(archive.paths, contains(tool.handler),
              reason: '工具 ${tool.name} 的 handler 缺失');
        }
        for (final page in manifest.pages) {
          expect(archive.paths, contains(page.entry),
              reason: '页面 ${page.id} 的 entry 缺失');
        }
        if (manifest.icon != null) {
          expect(archive.paths, contains(manifest.icon), reason: '图标缺失');
        }

        // 5. 权限注册 + 工具注册
        final gk = Gatekeeper();
        final unknown = gk.registerPlugin(manifest.id, manifest.permissionNames);
        expect(unknown, isEmpty, reason: 'manifest 不应声明未知权限');
        gk.grantAll(manifest.id, manifest.permissionNames);

        final tools = ToolRegistry();
        expect(tools.registerPlugin(manifest), isEmpty);

        // 6. 工具能导出成 OpenAI 格式
        final exported = tools.toOpenAiTools(gatekeeper: gk);
        expect(exported.length, manifest.tools.length);
      });
    }

    test('被篡改的插件包（注入 ../）在安装前就被拦住', () {
      // 模拟：正常包 + 一个恶意条目
      final good = zipDirectory('time-plugin');
      final archive = Archive();
      for (final f in ZipDecoder().decodeBytes(good, verify: false).files) {
        archive.addFile(f);
      }
      final evil = utf8.encode('pwned');
      archive.addFile(ArchiveFile('../evil-traversal.txt', evil.length, evil));
      final tampered = Uint8List.fromList(ZipEncoder().encode(archive)!);

      final result = reader.read(tampered);
      expect(result.inspection.isSafe, isFalse);
      expect(
        result.inspection.fatalIssues.map((i) => i.path),
        contains('../evil-traversal.txt'),
      );
    });
  });
}
