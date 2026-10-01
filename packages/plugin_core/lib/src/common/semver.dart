/// 极简语义化版本实现。
///
/// 只需要「解析 + 比较」，不需要 range 表达式求值（`hostApi` 的范围匹配
/// 目前只做同 major 比较，见 [satisfiesHostApi]）。
library;

/// 语义化版本。
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, {this.preRelease});

  /// 解析 `1.2.3` / `1.2.3-beta.1` / `1.2.3+build.7`。
  ///
  /// **严格模式：不接受 `v1.2.3` 这种前缀。** manifest 的 `version` 字段是给
  /// 机器读的，宽松解析会让 `v1.0.0` 和 `1.0.0` 变成两个不同的版本字符串，
  /// 在版本比较与去重时埋坑。不合法时抛 [FormatException]。
  factory SemVer.parse(String input) {
    final text = input.trim();
    final match =
        RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
            .firstMatch(text);
    if (match == null) {
      throw FormatException('不是合法的语义化版本: "$input"');
    }
    return SemVer(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      preRelease: match.group(4),
    );
  }

  /// 同 [parse]，但不合法时返回 null。
  static SemVer? tryParse(String? input) {
    if (input == null || input.trim().isEmpty) return null;
    try {
      return SemVer.parse(input);
    } on FormatException {
      return null;
    }
  }

  final int major;
  final int minor;
  final int patch;

  /// 预发布标识，如 `beta.1`。正式版为 null。
  final String? preRelease;

  bool get isPreRelease => preRelease != null;

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);

    // 正式版 > 预发布版（1.0.0 > 1.0.0-beta）
    if (preRelease == null && other.preRelease == null) return 0;
    if (preRelease == null) return 1;
    if (other.preRelease == null) return -1;
    return preRelease!.compareTo(other.preRelease!);
  }

  bool operator >(SemVer other) => compareTo(other) > 0;
  bool operator >=(SemVer other) => compareTo(other) >= 0;
  bool operator <(SemVer other) => compareTo(other) < 0;
  bool operator <=(SemVer other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is SemVer && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';
}

/// 判断宿主版本是否满足插件声明的 `hostApi` 范围。
///
/// 当前只支持三种写法，够用且不会误判：
///   - `^1.0.0`  → 同 major 且 >= 1.0.0
///   - `>=1.0.0` → 单纯的 >=
///   - `1.0.0`   → 精确相等
bool satisfiesHostApi(String range, String hostVersion) {
  final host = SemVer.tryParse(hostVersion);
  final trimmed = range.trim();
  if (host == null) return false;

  if (trimmed.startsWith('^')) {
    final lower = SemVer.tryParse(trimmed.substring(1));
    if (lower == null) return false;
    return host.major == lower.major && host >= lower;
  }
  if (trimmed.startsWith('>=')) {
    final lower = SemVer.tryParse(trimmed.substring(2));
    if (lower == null) return false;
    return host >= lower;
  }
  final exact = SemVer.tryParse(trimmed);
  if (exact == null) return false;
  return host == exact;
}
