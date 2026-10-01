import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  group('SemVer 解析', () {
    test('接受标准三段式', () {
      expect(SemVer.parse('1.2.3').toString(), '1.2.3');
    });

    test('拒绝 v 前缀（严格 semver，避免同一版本两种写法）', () {
      expect(() => SemVer.parse('v1.2.3'), throwsFormatException);
      expect(() => SemVer.parse('V1.2.3'), throwsFormatException);
    });

    test('接受预发布标识', () {
      final v = SemVer.parse('1.0.0-beta.1');
      expect(v.preRelease, 'beta.1');
      expect(v.isPreRelease, isTrue);
    });

    test('忽略构建元数据', () {
      expect(SemVer.parse('1.2.3+build.7').toString(), '1.2.3');
    });

    test('拒绝两段式', () {
      expect(() => SemVer.parse('1.0'), throwsFormatException);
    });

    test('拒绝空串', () {
      expect(() => SemVer.parse(''), throwsFormatException);
    });

    test('tryParse 对非法输入返回 null', () {
      expect(SemVer.tryParse('abc'), isNull);
      expect(SemVer.tryParse(null), isNull);
      expect(SemVer.tryParse(''), isNull);
    });
  });

  group('SemVer 比较', () {
    test('按 major/minor/patch 排序', () {
      expect(SemVer.parse('2.0.0') > SemVer.parse('1.9.9'), isTrue);
      expect(SemVer.parse('1.10.0') > SemVer.parse('1.9.0'), isTrue);
      expect(SemVer.parse('1.0.10') > SemVer.parse('1.0.9'), isTrue);
    });

    test('正式版大于同号预发布版', () {
      expect(SemVer.parse('1.0.0') > SemVer.parse('1.0.0-beta'), isTrue);
      expect(SemVer.parse('1.0.0-beta') < SemVer.parse('1.0.0'), isTrue);
    });

    test('相等判定', () {
      expect(SemVer.parse('1.2.3') == SemVer.parse('1.2.3'), isTrue);
      expect(SemVer.parse('1.2.3').hashCode, SemVer.parse('1.2.3').hashCode);
    });
  });

  group('satisfiesHostApi', () {
    test('^ 表示同 major 且不低于', () {
      expect(satisfiesHostApi('^1.0.0', '1.0.0'), isTrue);
      expect(satisfiesHostApi('^1.0.0', '1.9.9'), isTrue);
      expect(satisfiesHostApi('^1.0.0', '2.0.0'), isFalse);
      expect(satisfiesHostApi('^1.2.0', '1.1.0'), isFalse);
    });

    test('>= 表示单纯下限', () {
      expect(satisfiesHostApi('>=1.0.0', '3.0.0'), isTrue);
      expect(satisfiesHostApi('>=2.0.0', '1.0.0'), isFalse);
    });

    test('精确版本', () {
      expect(satisfiesHostApi('1.0.0', '1.0.0'), isTrue);
      expect(satisfiesHostApi('1.0.0', '1.0.1'), isFalse);
    });

    test('非法范围返回 false（fail-closed）', () {
      expect(satisfiesHostApi('不是版本', '1.0.0'), isFalse);
      expect(satisfiesHostApi('^1.0.0', '不是版本'), isFalse);
    });
  });
}
