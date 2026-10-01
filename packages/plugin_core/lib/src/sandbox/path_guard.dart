/// 沙箱路径守门 —— 阻止插件用 `fs.*` 越出自己的目录。
///
/// 路径穿越是插件系统里最容易被利用的一类漏洞，因此这里有**分层防御**：
///
/// | 层 | 防什么 | 在哪 |
/// |---|---|---|
/// | 1. 词法层（本文件） | `..`、绝对路径、UNC、URL 编码、混合分隔符 | [resolve] |
/// | 2. 真实路径层 | 符号链接指向沙箱外 | [verifyNoEscape] |
/// | 3. 打包层 | zip 内的 `../` 条目（Zip Slip） | `packaging/package_inspector.dart` |
///
/// 词法层是纯函数、无 IO，因此可以被穷举测试。
library;

import 'dart:io' show Platform;

import 'package:path/path.dart' as p;

import '../common/errors.dart';

/// 把绝对路径解析成「真实路径」的回调（用于穿透符号链接）。
///
/// 传入 `dart:io` 的 `File(path).resolveSymbolicLinksSync()` 即可。
/// 之所以做成回调而不是直接 `import 'dart:io'`，是为了让本文件保持纯净、可单测。
typedef RealPathResolver = String Function(String absolutePath);

/// 插件沙箱的路径守门人。
class SandboxPathGuard {
  /// 创建守门人。
  ///
  /// [root] 是插件数据目录的绝对路径（宿主提供，插件无法影响）。
  /// [caseSensitive] 默认按平台推断：Windows / macOS 不区分大小写。
  SandboxPathGuard(
    String root, {
    bool? caseSensitive,
    RealPathResolver? realPathResolver,
  })  : root = p.normalize(p.absolute(root)),
        caseSensitive = caseSensitive ?? !_isCaseInsensitivePlatform,
        _realPathResolver = realPathResolver;

  /// 沙箱根目录（已规范化）。
  final String root;

  /// 路径比较是否区分大小写。
  final bool caseSensitive;

  final RealPathResolver? _realPathResolver;

  /// Windows 与 macOS 的文件系统不区分大小写；Linux / Android 区分。
  ///
  /// 注意 `path` 包的 `Style` 只有 `posix` / `windows` / `url`，macOS 在它眼里
  /// 也是 posix，因此必须问 `dart:io` 的 `Platform`。
  static bool get _isCaseInsensitivePlatform {
    try {
      return Platform.isWindows || Platform.isMacOS;
    } on UnsupportedError {
      // Web 等没有平台概念的环境：按区分大小写处理（更严格，fail-closed）
      return false;
    }
  }

  /// 把插件给的相对路径解析为沙箱内的绝对路径。
  ///
  /// 任何越界尝试都抛 [TsukiroException]（`SANDBOX_VIOLATION` 或 `INVALID_ARGS`）。
  String resolve(String userPath) {
    if (userPath.trim().isEmpty) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '路径不能为空',
        details: <String, dynamic>{'path': userPath},
      );
    }

    // ── 1. URL 解码（反复解码，防 %252e%252e%252f 这类多重编码） ──
    var text = userPath;
    for (var i = 0; i < 3; i++) {
      final decoded = _decodePercentOnce(text);
      if (decoded == text) break;
      text = decoded;
    }

    // ── 2. NUL 字节（C 层字符串截断攻击） ──
    if (text.contains('\u0000')) {
      throw TsukiroException.sandboxViolation(userPath, reason: '路径包含 NUL 字节');
    }

    // ── 3. 统一分隔符后处理（Windows 上 \ 与 / 等价） ──
    final unified = text.replaceAll('\\', '/');

    // ── 4. 拒绝绝对路径与 UNC ──
    if (unified.startsWith('/')) {
      throw TsukiroException.sandboxViolation(userPath, reason: '不接受绝对路径');
    }
    if (RegExp(r'^[a-zA-Z]:').hasMatch(unified)) {
      throw TsukiroException.sandboxViolation(userPath, reason: '不接受盘符路径');
    }
    if (RegExp(r'^~').hasMatch(unified)) {
      throw TsukiroException.sandboxViolation(userPath, reason: '不接受 HOME 展开路径');
    }

    // ── 5. 用 POSIX 语义规范化，再检查是否向上逃逸 ──
    //     'a/../../b' → '../b'   → 拒绝
    //     'a/..'      → '.'      → 允许（即沙箱根）
    final normalized = p.posix.normalize(unified);
    if (normalized == '..' || normalized.startsWith('../')) {
      throw TsukiroException.sandboxViolation(userPath, reason: '路径穿越出沙箱');
    }

    // ── 6. 拼接并做最终包含性检查（第三道保险） ──
    final joined = normalized == '.'
        ? root
        : p.normalize(p.join(root, p.joinAll(normalized.split('/'))));

    if (!isWithinRoot(joined)) {
      throw TsukiroException.sandboxViolation(userPath, reason: '解析结果位于沙箱之外');
    }
    return joined;
  }

  /// 同 [resolve]，但不抛异常，越界返回 null。
  String? tryResolve(String userPath) {
    try {
      return resolve(userPath);
    } on TsukiroException {
      return null;
    }
  }

  /// 该相对路径是否位于沙箱内。
  bool isWithin(String userPath) => tryResolve(userPath) != null;

  /// 绝对路径是否位于沙箱根之内（含根本身）。
  bool isWithinRoot(String absolutePath) {
    var candidate = p.normalize(p.absolute(absolutePath));
    var base = root;
    if (!caseSensitive) {
      candidate = candidate.toLowerCase();
      base = base.toLowerCase();
    }
    if (candidate == base) return true;
    final prefix = base.endsWith(p.separator) ? base : '$base${p.separator}';
    return candidate.startsWith(prefix);
  }

  /// 第二层防御：解析符号链接后再次确认没有逃逸。
  ///
  /// 需要在真正做 IO 之前调用（`fs.read` / `fs.write` / `fs.delete`）。
  /// 未注入 [RealPathResolver] 时直接返回入参（纯逻辑测试场景）。
  String verifyNoEscape(String absolutePath) {
    final resolver = _realPathResolver;
    if (resolver == null) return absolutePath;

    final real = resolver(absolutePath);
    if (!isWithinRoot(real)) {
      throw TsukiroException.sandboxViolation(
        absolutePath,
        reason: '符号链接指向沙箱之外: $real',
      );
    }
    return real;
  }

  /// 一次搞定：解析 → 真实路径校验。
  String resolveAndVerify(String userPath) => verifyNoEscape(resolve(userPath));

  @override
  String toString() => 'SandboxPathGuard($root, caseSensitive: $caseSensitive)';
}

/// 解码一次百分号编码。遇到非法序列保持原样，不抛异常。
String _decodePercentOnce(String input) {
  if (!input.contains('%')) return input;
  final buffer = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == '%' && i + 3 <= input.length) {
      final hex = input.substring(i + 1, i + 3);
      final value = int.tryParse(hex, radix: 16);
      if (value != null) {
        buffer.writeCharCode(value);
        i += 3;
        continue;
      }
    }
    buffer.write(ch);
    i++;
  }
  return buffer.toString();
}
