import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

PackageEntry file(String path, {int size = 100}) =>
    PackageEntry(path: path, size: size);

PackageEntry dir(String path) =>
    PackageEntry(path: path, size: 0, isDirectory: true);

const inspector = PackageInspector();

PackageInspection inspect(List<PackageEntry> entries, {int? archiveByteSize}) =>
    inspector.inspect(entries, archiveByteSize: archiveByteSize);

void main() {
  group('正常包', () {
    test('manifest 在根目录', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file('index.js'),
        file('handlers/get_time.js'),
      ]);
      expect(r.isSafe, isTrue, reason: r.issues.join('; '));
      expect(r.pluginRootPrefix, '');
      expect(r.manifestPath, 'manifest.json');
      expect(r.files, containsAll(<String>['manifest.json', 'index.js', 'handlers/get_time.js']));
      expect(r.has('handlers/get_time.js'), isTrue);
    });

    test('manifest 在唯一顶层目录下（GitHub Release 常见布局）', () {
      final r = inspect(<PackageEntry>[
        dir('time-plugin-1.0.0/'),
        file('time-plugin-1.0.0/manifest.json'),
        file('time-plugin-1.0.0/index.js'),
      ]);
      expect(r.isSafe, isTrue, reason: r.issues.join('; '));
      expect(r.pluginRootPrefix, 'time-plugin-1.0.0/');
      expect(r.manifestPath, 'manifest.json');
      expect(r.files, containsAll(<String>['manifest.json', 'index.js']));
      expect(r.has('index.js'), isTrue);
    });

    test('目录条目不参与体积统计', () {
      final r = inspect(<PackageEntry>[
        dir('assets/'),
        file('manifest.json', size: 1000),
      ]);
      expect(r.totalBytes, 1000);
    });

    test('反斜杠分隔符被接受并规范化', () {
      final r = inspect(<PackageEntry>[
        file(r'manifest.json'),
        file(r'handlers\get_time.js'),
      ]);
      expect(r.isSafe, isTrue, reason: r.issues.join('; '));
      expect(r.has('handlers/get_time.js'), isTrue);
    });
  });

  group('Zip Slip —— 必须拒绝', () {
    test('../ 前置', () {
      final r = inspect(<PackageEntry>[file('manifest.json'), file('../evil.txt')]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.map((i) => i.path), contains('../evil.txt'));
      expect(r.fatalIssues.first.message, contains('Zip Slip'));
    });

    test('深层 ../../', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file('../../../../etc/passwd'),
      ]);
      expect(r.isSafe, isFalse);
    });

    test('藏在中间 a/../../b', () {
      // 规范化后是 ../b，但即使规范化后落在内部也不接受 ——
      // 不同解压实现对 `a/../..` 的处理并不一致，这正是 Zip Slip 的成因
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file('a/../../b.txt'),
      ]);
      expect(r.isSafe, isFalse);
    });

    test('Windows 反斜杠穿越 ..\\..\\x', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file(r'..\..\windows\system32\evil.dll'),
      ]);
      expect(r.isSafe, isFalse);
    });

    test('绝对路径', () {
      final r = inspect(<PackageEntry>[file('manifest.json'), file('/etc/passwd')]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.map((i) => i.message), contains(contains('绝对路径')));
    });

    test('Windows 盘符路径', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file(r'C:\Windows\System32\evil.txt'),
      ]);
      expect(r.isSafe, isFalse);
    });

    test('UNC 路径', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file(r'\\server\share\evil.txt'),
      ]);
      expect(r.isSafe, isFalse);
    });

    test('HOME 展开路径', () {
      final r = inspect(<PackageEntry>[file('manifest.json'), file('~/.ssh/id_rsa')]);
      expect(r.isSafe, isFalse);
    });

    test('NUL 字节', () {
      final r = inspect(<PackageEntry>[file('manifest.json'), file('a\u0000b.txt')]);
      expect(r.isSafe, isFalse);
    });

    test('即使没有 manifest，Zip Slip 也单独报出来', () {
      final r = inspect(<PackageEntry>[file('../evil.txt')]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.map((i) => i.path), contains('../evil.txt'));
    });
  });

  group('符号链接 —— 必须拒绝', () {
    test('symlink 条目', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        const PackageEntry(path: 'link', size: 10, isSymlink: true),
      ]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.first.message, contains('符号链接'));
    });
  });

  group('原生二进制 —— 必须拒绝', () {
    for (final name in <String>[
      'lib/native.so',
      'lib/native.dll',
      'lib/native.dylib',
      'bin/tool.exe',
      'addon.node',
      'run.bat',
      'run.ps1',
      'run.sh',
      'app.apk',
      'lib.jar',
    ]) {
      test('拒绝 $name', () {
        final r = inspect(<PackageEntry>[file('manifest.json'), file(name)]);
        expect(r.isSafe, isFalse, reason: '$name 应被拒绝');
        expect(r.fatalIssues.first.message, contains('禁止的文件类型'));
      });
    }

    test('大小写不敏感', () {
      final r = inspect(<PackageEntry>[file('manifest.json'), file('LIB/NATIVE.SO')]);
      expect(r.isSafe, isFalse);
    });

    test('普通扩展名不受影响', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file('index.js'),
        file('pages/game.html'),
        file('assets/icon.svg'),
        file('README.md'),
      ]);
      expect(r.isSafe, isTrue, reason: r.issues.join('; '));
    });
  });

  group('禁止的目录', () {
    for (final d in <String>['node_modules', '.git', '__MACOSX']) {
      test('拒绝 $d/', () {
        final r = inspect(<PackageEntry>[
          file('manifest.json'),
          file('$d/pkg/index.js'),
        ]);
        expect(r.isSafe, isFalse);
        expect(r.fatalIssues.first.message, contains(d));
      });
    }
  });

  group('体积限制', () {
    test('单文件超 10MB 被拒', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file('big.bin', size: 11 * 1024 * 1024),
      ]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.first.message, contains('单文件超限'));
    });

    test('恰好 10MB 通过', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file('big.bin', size: 10 * 1024 * 1024),
      ]);
      expect(r.isSafe, isTrue, reason: r.issues.join('; '));
    });

    test('解压后总体积超 50MB 被拒', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        for (var i = 0; i < 6; i++) file('part$i.bin', size: 9 * 1024 * 1024),
      ]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.map((i) => i.message), contains(contains('总体积超限')));
    });

    test('zip bomb：压缩比异常被拒', () {
      // 解压后 40MB，压缩包只有 10KB → 4000:1
      final r = inspect(
        <PackageEntry>[
          file('manifest.json'),
          for (var i = 0; i < 5; i++) file('part$i.bin', size: 8 * 1024 * 1024),
        ],
        archiveByteSize: 10 * 1024,
      );
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.map((i) => i.message), contains(contains('zip bomb')));
    });

    test('小体积高压缩比不算 bomb（小包本来就压得狠）', () {
      final r = inspect(
        <PackageEntry>[file('manifest.json', size: 200), file('a.js', size: 4000)],
        archiveByteSize: 100,
      );
      expect(r.isSafe, isTrue, reason: r.issues.join('; '));
    });

    test('不给 archiveByteSize 时跳过 bomb 检查', () {
      final r = inspect(<PackageEntry>[
        file('manifest.json'),
        file('a.bin', size: 40 * 1024 * 1024),
      ]);
      expect(r.fatalIssues.map((i) => i.message), isNot(contains(contains('zip bomb'))));
    });
  });

  group('manifest 位置', () {
    test('根本没有 manifest.json', () {
      final r = inspect(<PackageEntry>[file('index.js')]);
      expect(r.isSafe, isFalse);
      expect(r.manifestPath, isNull);
      expect(r.fatalIssues.first.message, contains('manifest.json'));
    });

    test('真正的两层目录被拒', () {
      final r = inspect(<PackageEntry>[
        file('a/b/manifest.json'),
        file('a/b/index.js'),
      ]);
      expect(r.isSafe, isFalse);
      expect(r.manifestPath, isNull);
      expect(r.fatalIssues.first.message, contains('顶层目录'));
    });

    test('单层顶层目录名是 src 也接受（与任意目录名不可区分）', () {
      final r = inspect(<PackageEntry>[
        file('src/manifest.json'),
        file('src/index.js'),
      ]);
      expect(r.isSafe, isTrue, reason: r.issues.join('; '));
      expect(r.manifestPath, 'manifest.json');
      expect(r.has('index.js'), isTrue);
    });

    test('两个顶层目录被拒', () {
      final r = inspect(<PackageEntry>[
        file('a/manifest.json'),
        file('b/manifest.json'),
      ]);
      expect(r.isSafe, isFalse);
      expect(r.manifestPath, isNull);
    });

    test('唯一顶层目录但缺 manifest.json', () {
      final r = inspect(<PackageEntry>[file('time-plugin/index.js')]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.first.message, contains('没有 manifest.json'));
    });

    test('根目录有散落文件时即使有单个目录也不接受', () {
      final r = inspect(<PackageEntry>[
        file('README.md'),
        file('time-plugin/manifest.json'),
      ]);
      expect(r.isSafe, isFalse);
      expect(r.manifestPath, isNull);
    });

    test('空包被拒', () {
      final r = inspect(<PackageEntry>[]);
      expect(r.isSafe, isFalse);
      expect(r.fatalIssues.first.message, contains('没有任何文件'));
    });
  });

  group('问题严重度', () {
    test('致命问题会阻止安装', () {
      final r = inspect(<PackageEntry>[file('manifest.json'), file('../evil.txt')]);
      expect(r.fatalIssues, isNotEmpty);
      expect(r.isSafe, isFalse);
    });

    test('没有问题时代码路径正常', () {
      final r = inspect(<PackageEntry>[file('manifest.json')]);
      expect(r.issues, isEmpty);
      expect(r.isSafe, isTrue);
    });
  });

  group('package_inspector 的路径规则：单独验证', () {
    test('合法路径返回 null', () {
      for (final p in <String>[
        'manifest.json',
        'a/b/c.js',
        'assets/icon.svg',
        '带空格 的/文件.txt',
        '.hidden',
      ]) {
        expect(PackageInspector.pathProblem(p), isNull, reason: p);
      }
    });

    test('非法路径返回原因', () {
      for (final p in <String>[
        '../x',
        'a/../x',
        'a/../../x',
        '/x',
        r'C:\x',
        r'\\server\share',
        '~/x',
        'a\u0000b',
      ]) {
        expect(PackageInspector.pathProblem(p), isNotNull, reason: p);
      }
    });
  });
}
