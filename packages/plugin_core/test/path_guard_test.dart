import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  final root = p.join(Directory.systemTemp.path, 'tsukiro-sandbox-test');
  late SandboxPathGuard guard;

  setUp(() {
    guard = SandboxPathGuard(root);
  });

  group('正常路径', () {
    test('普通相对路径', () {
      final abs = guard.resolve('notes/a.txt');
      expect(abs, p.join(guard.root, 'notes', 'a.txt'));
      expect(guard.isWithinRoot(abs), isTrue);
    });

    test('嵌套目录', () {
      expect(guard.resolve('a/b/c/d.txt'),
          p.join(guard.root, 'a', 'b', 'c', 'd.txt'));
    });

    test('反斜杠分隔符也接受（Windows 习惯）', () {
      expect(guard.resolve(r'notes\a.txt'),
          p.join(guard.root, 'notes', 'a.txt'));
    });

    test('点号被规范化', () {
      expect(guard.resolve('./notes/./a.txt'),
          p.join(guard.root, 'notes', 'a.txt'));
    });

    test('a/.. 等价于沙箱根', () {
      expect(guard.resolve('a/..'), guard.root);
      expect(guard.resolve('.'), guard.root);
    });

    test('含空格的路径', () {
      expect(guard.resolve('my notes/草稿 1.txt'),
          p.join(guard.root, 'my notes', '草稿 1.txt'));
    });
  });

  group('穿越攻击必须被拦', () {
    test('.. 单层', () {
      expect(() => guard.resolve('..'), throwsA(isA<TsukiroException>()));
    });

    test('../ 前置', () {
      expect(() => guard.resolve('../secret.txt'), throwsSandboxViolation);
    });

    test('深层穿越 a/../../x', () {
      expect(() => guard.resolve('a/../../secret.txt'), throwsSandboxViolation);
    });

    test('路径中间的穿越 notes/../../../x', () {
      expect(() => guard.resolve('notes/../../../../etc/passwd'),
          throwsSandboxViolation);
    });

    test('Windows 反斜杠穿越', () {
      expect(() => guard.resolve(r'..\..\windows\system32\config'),
          throwsSandboxViolation);
    });

    test('混合分隔符穿越', () {
      expect(() => guard.resolve(r'..\../x'), throwsSandboxViolation);
    });

    test('URL 编码穿越 %2e%2e%2f', () {
      expect(() => guard.resolve('%2e%2e%2fsecret.txt'), throwsSandboxViolation);
    });

    test('双重 URL 编码穿越 %252e%252e%252f', () {
      expect(() => guard.resolve('%252e%252e%252fsecret.txt'),
          throwsSandboxViolation);
    });

    test('大小写混合的 URL 编码 %2E%2E/', () {
      expect(() => guard.resolve('%2E%2E%2Fsecret.txt'), throwsSandboxViolation);
    });
  });

  group('绝对路径与特殊路径必须被拦', () {
    test('POSIX 绝对路径', () {
      expect(() => guard.resolve('/etc/passwd'), throwsSandboxViolation);
    });

    test('Windows 盘符路径', () {
      expect(() => guard.resolve(r'C:\Windows\System32'), throwsSandboxViolation);
    });

    test('小写盘符路径', () {
      expect(() => guard.resolve('d:/data/x'), throwsSandboxViolation);
    });

    test('UNC 路径', () {
      expect(() => guard.resolve(r'\\server\share\file'), throwsSandboxViolation);
    });

    test('HOME 展开', () {
      expect(() => guard.resolve('~/.ssh/id_rsa'), throwsSandboxViolation);
    });
  });

  group('畸形输入', () {
    test('空字符串 → INVALID_ARGS 而不是 SANDBOX_VIOLATION', () {
      expect(
        () => guard.resolve(''),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code, 'code', TsukiroErrorCode.invalidArgs)),
      );
    });

    test('纯空白', () {
      expect(() => guard.resolve('   '), throwsA(isA<TsukiroException>()));
    });

    test('NUL 字节', () {
      expect(() => guard.resolve('a\u0000b'), throwsSandboxViolation);
    });

    test('NUL 字节藏在目录名中', () {
      expect(() => guard.resolve('notes\u0000/../../x'), throwsSandboxViolation);
    });
  });

  group('tryResolve / isWithin', () {
    test('合法路径返回绝对路径', () {
      expect(guard.tryResolve('a.txt'), isNotNull);
    });

    test('非法路径返回 null 而不抛异常', () {
      expect(guard.tryResolve('../x'), isNull);
      expect(guard.isWithin('../x'), isFalse);
      expect(guard.isWithin('a.txt'), isTrue);
    });
  });

  group('isWithinRoot', () {
    test('根本身算在内部', () {
      expect(guard.isWithinRoot(guard.root), isTrue);
    });

    test('根下的文件算在内部', () {
      expect(guard.isWithinRoot(p.join(guard.root, 'x.txt')), isTrue);
    });

    test('同级的兄弟目录不算在内部', () {
      // 关键用例：字符串前缀相同但不是子路径
      final sibling = '${guard.root}-evil';
      expect(guard.isWithinRoot(sibling), isFalse,
          reason: '前缀匹配必须带路径分隔符，否则 /sandbox-evil 会被误判为 /sandbox 内');
    });

    test('上级目录不算在内部', () {
      expect(guard.isWithinRoot(p.dirname(guard.root)), isFalse);
    });
  });

  group('符号链接逃逸（第二层防御）', () {
    test('未注入 resolver 时 verifyNoEscape 直接放行', () {
      final abs = guard.resolve('a.txt');
      expect(guard.verifyNoEscape(abs), abs);
    });

    test('resolver 返回沙箱外路径 → 拒绝', () {
      final outside = p.join(Directory.systemTemp.path, 'somewhere-else', 'x');
      final g = SandboxPathGuard(
        root,
        realPathResolver: (_) => outside,
      );
      expect(() => g.verifyNoEscape(g.resolve('link.txt')),
          throwsSandboxViolation);
    });

    test('resolver 返回沙箱内路径 → 放行', () {
      final inside = p.join(root, 'real', 'a.txt');
      final g = SandboxPathGuard(root, realPathResolver: (_) => inside);
      expect(g.verifyNoEscape(g.resolve('link.txt')), inside);
    });

    test('resolveAndVerify 一步到位', () {
      final inside = p.join(root, 'real.txt');
      final g = SandboxPathGuard(root, realPathResolver: (_) => inside);
      expect(g.resolveAndVerify('a.txt'), inside);
    });
  });

  group('尾随空格与点（Windows 会剥掉它们）', () {
    // 这一组是**读代码发现的**，不是测试发现的。
    //
    // 机制：resolve 的第 5 步用 posix.normalize 判断有没有向上逃逸。
    // 但 `.. `（`..` 后带一个空格）normalize 之后仍是 `.. ` ——
    // 它既不等于 `..`，也不以 `../` 开头，于是**通过了词法检查**。
    //
    // 而 Windows 的 Win32 层会**剥掉路径段结尾的空格与点**，
    // 所以文件系统实际打开的是 `..` —— 父目录。
    //
    // 也就是说：**词法层认为它在沙箱内，文件系统认为它在沙箱外。**
    // 两边对同一个字符串的理解不一致，就是漏洞。
    //
    // 影响面：Android 是 Linux，不受影响；但这个项目也编 Windows。
    test('`..` 后带尾随空格', () {
      expect(() => guard.resolve('.. '), throwsSandboxViolation);
    });

    test('`..` 后带尾随点', () {
      expect(() => guard.resolve('...'), throwsSandboxViolation);
    });

    test('中间段带尾随空格，配合 `..`', () {
      expect(() => guard.resolve('a /../../x'), throwsSandboxViolation);
    });

    test('`.. /x`', () {
      expect(() => guard.resolve('.. /x'), throwsSandboxViolation);
    });

    test('普通文件名的尾随空格也拒绝（不做归一，直接拒）', () {
      // 拒绝而不是「剥掉再用」：我们没有义务支持这种文件名，
      // 而「剥掉」要精确复刻 Windows 的规则，复刻错了又是一个洞。
      expect(() => guard.resolve('a.txt '), throwsSandboxViolation);
    });

    test('合法路径里的空格不受影响', () {
      expect(guard.resolve('my notes/a.txt'), isNotNull);
    });
  });

  group('大小写敏感性', () {
    test('Windows/macOS 下大小写不敏感比较', () {
      final g = SandboxPathGuard(root, caseSensitive: false);
      final upper = p.join(g.root.toUpperCase(), 'x.txt');
      expect(g.isWithinRoot(upper), isTrue);
    });

    test('Linux 下大小写敏感', () {
      final g = SandboxPathGuard(root, caseSensitive: true);
      final upper = p.join(g.root.toUpperCase(), 'x.txt');
      expect(g.isWithinRoot(upper), isFalse);
    });
  });
}

/// 断言抛出的是 `SANDBOX_VIOLATION`。
final Matcher throwsSandboxViolation = throwsA(
  isA<TsukiroException>()
      .having((e) => e.code, 'code', TsukiroErrorCode.sandboxViolation)
      .having((e) => e.retryable, 'retryable', isFalse),
);
