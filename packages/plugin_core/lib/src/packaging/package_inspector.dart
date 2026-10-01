/// 插件包（zip）的安全与结构检查。**纯逻辑，不依赖 zip 库。**
///
/// 与 zip 解析分离是刻意的：安全规则是最需要穷举测试的部分，而 zip 库的 API
/// 变动不该影响这些规则的测试。真实 zip 通过 `zip_reader.dart` 适配成
/// [PackageEntry] 列表后送进来。
///
/// 规则见 `docs/04-plugin-spec.md` §1.2。
library;

/// 包里的一个条目。
class PackageEntry {
  const PackageEntry({
    required this.path,
    required this.size,
    this.isDirectory = false,
    this.isSymlink = false,
    this.mode = 0,
  });

  /// zip 里记录的原始路径（尚未规范化）。
  final String path;

  /// 解压后大小（字节）。
  final int size;

  final bool isDirectory;
  final bool isSymlink;

  /// 外部属性里的 Unix mode 位。
  final int mode;

  @override
  String toString() => 'PackageEntry($path, $size bytes'
      '${isDirectory ? ', dir' : ''}${isSymlink ? ', symlink' : ''})';
}

/// 问题严重度。
enum PackageIssueSeverity {
  /// 必须中止安装。
  fatal,

  /// 记录并提示，但不阻止安装。
  warning,
}

/// 一条检查问题。
class PackageIssue {
  const PackageIssue(this.path, this.message, {this.severity = PackageIssueSeverity.fatal});

  final String path;
  final String message;
  final PackageIssueSeverity severity;

  @override
  String toString() => '${severity == PackageIssueSeverity.fatal ? "✗" : "!"} $path: $message';
}

/// 检查结果。
class PackageInspection {
  const PackageInspection({
    required this.entries,
    required this.issues,
    this.pluginRootPrefix = '',
    this.manifestPath,
    this.files = const <String>[],
  });

  /// 全部条目（原始顺序）。
  final List<PackageEntry> entries;

  final List<PackageIssue> issues;

  /// 插件根在 zip 内的前缀，`''` 或 `'time-plugin-1.0.0/'`。
  final String pluginRootPrefix;

  /// manifest.json 相对插件根的路径；未找到或无唯一根时为 null。
  final String? manifestPath;

  /// 相对插件根的文件路径列表（不含目录）。
  final List<String> files;

  /// 是否可以安装。
  bool get isSafe =>
      manifestPath != null &&
      !issues.any((i) => i.severity == PackageIssueSeverity.fatal);

  List<PackageIssue> get fatalIssues =>
      issues.where((i) => i.severity == PackageIssueSeverity.fatal).toList(growable: false);

  /// 插件根下是否存在该文件。
  bool has(String relativePath) =>
      files.contains(relativePath.replaceAll('\\', '/'));

  /// 解压后总字节数。
  int get totalBytes =>
      entries.where((e) => !e.isDirectory).fold(0, (sum, e) => sum + e.size);

  @override
  String toString() => 'PackageInspection(${files.length} files, ${issues.length} issues)';
}

/// 包大小限制（见 `docs/04-plugin-spec.md` §1.2）。
class PackageLimits {
  const PackageLimits({
    this.maxFileBytes = 10 * 1024 * 1024,
    this.maxTotalBytes = 50 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.zipBombMinBytes = 10 * 1024 * 1024,
  });

  final int maxFileBytes;
  final int maxTotalBytes;

  /// 解压后 / 压缩包 的比值上限。
  final int maxCompressionRatio;

  /// 只看大于这个体积的包是否压缩比异常（小包压缩比高是正常的）。
  final int zipBombMinBytes;
}

/// 禁止的文件扩展名。
const Set<String> forbiddenExtensions = <String>{
  '.so',
  '.dll',
  '.dylib',
  '.exe',
  '.node',
  '.bat',
  '.cmd',
  '.ps1',
  '.sh',
  '.apk',
  '.jar',
};

/// 禁止出现的目录名。
const Set<String> forbiddenDirectories = <String>{
  'node_modules',
  '.git',
  '__MACOSX',
};

/// 包检查器。
class PackageInspector {
  const PackageInspector({this.limits = const PackageLimits()});

  final PackageLimits limits;

  /// 执行检查。
  ///
  /// [archiveByteSize] 为 zip 文件的字节数，用于压缩比（zip bomb）判断；
  /// 为 null 时跳过这一项。
  PackageInspection inspect(
    List<PackageEntry> entries, {
    int? archiveByteSize,
  }) {
    final issues = <PackageIssue>[];

    // ── 1. 逐条目：路径安全 ──
    var totalBytes = 0;
    for (final entry in entries) {
      final reason = pathProblem(entry.path);
      if (reason != null) {
        issues.add(PackageIssue(entry.path, reason));
        continue;
      }

      if (entry.isSymlink) {
        issues.add(PackageIssue(entry.path, '禁止符号链接（可绕过沙箱路径检查）'));
        continue;
      }

      if (entry.isDirectory) continue;

      totalBytes += entry.size;

      // ── 2. 单文件体积 ──
      if (entry.size > limits.maxFileBytes) {
        issues.add(PackageIssue(
          entry.path,
          '单文件超限: ${_mb(entry.size)} > ${_mb(limits.maxFileBytes)}',
        ));
      }

      // ── 3. 文件类型 ──
      final lower = entry.path.toLowerCase();
      final dot = lower.lastIndexOf('.');
      if (dot >= 0) {
        final ext = lower.substring(dot);
        if (forbiddenExtensions.contains(ext)) {
          issues.add(PackageIssue(
            entry.path,
            '禁止的文件类型 $ext（原生二进制可绕过 JS 沙箱直接调系统 API）',
          ));
        }
      }

      // ── 4. 禁止的目录 ──
      final segments = entry.path.replaceAll('\\', '/').split('/');
      for (final dir in forbiddenDirectories) {
        if (segments.contains(dir)) {
          issues.add(PackageIssue(entry.path, '禁止包含 $dir/ 目录'));
          break;
        }
      }
    }

    // ── 5. 总体积 ──
    if (totalBytes > limits.maxTotalBytes) {
      issues.add(PackageIssue(
        '<package>',
        '解压后总体积超限: ${_mb(totalBytes)} > ${_mb(limits.maxTotalBytes)}',
      ));
    }

    // ── 6. zip bomb：压缩比异常 ──
    if (archiveByteSize != null &&
        archiveByteSize > 0 &&
        totalBytes > limits.zipBombMinBytes) {
      final ratio = totalBytes / archiveByteSize;
      if (ratio > limits.maxCompressionRatio) {
        issues.add(PackageIssue(
          '<package>',
          '压缩比异常（${ratio.toStringAsFixed(0)}:1 > ${limits.maxCompressionRatio}:1），'
          '疑似 zip bomb',
        ));
      }
    }

    // ── 7. 定位插件根与 manifest.json ──
    final layout = _locatePluginRoot(entries, issues);

    final files = <String>[];
    if (layout.prefix != null) {
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (pathProblem(entry.path) != null) continue;
        final rel = relativize(entry.path, layout.prefix!);
        if (rel != null && rel.isNotEmpty) files.add(rel);
      }
    }

    return PackageInspection(
      entries: entries,
      issues: issues,
      pluginRootPrefix: layout.prefix ?? '',
      manifestPath: layout.manifestPath,
      files: files,
    );
  }

  /// 路径层面的问题；返回 null 表示合规。
  ///
  /// 公开是因为 `zip_reader.dart` 在读取条目前要复用同一套判断 ——
  /// 安全规则必须只有一处实现。
  static String? pathProblem(String rawPath) {
    if (rawPath.trim().isEmpty) return '路径为空';

    // zip 条目一律用 /，但容忍某些打包工具写 \
    final unified = rawPath.replaceAll('\\', '/');

    if (unified.contains('\u0000')) return '路径包含 NUL 字节';
    if (unified.startsWith('/')) return '不接受绝对路径（Zip Slip）';
    if (RegExp(r'^[a-zA-Z]:').hasMatch(unified)) return '不接受盘符路径（Zip Slip）';
    if (unified.startsWith('~')) return '不接受 HOME 展开路径';

    // 逐段检查：任何一段是 .. 就拒绝。
    // 不能只看规范化结果 —— 规范化会掩盖 `a/../b` 这类"看似安全"的写法，
    // 而不同的解压实现对它的处理并不一致（这正是 Zip Slip 的成因）。
    for (final segment in unified.split('/')) {
      if (segment == '..') return '路径包含 .. （Zip Slip）';
    }

    return null;
  }

  /// 找到插件根前缀与 manifest 位置。
  static _Layout _locatePluginRoot(List<PackageEntry> entries, List<PackageIssue> issues) {
    final safePaths = <String>[];
    for (final e in entries) {
      if (e.isDirectory) continue;
      if (pathProblem(e.path) != null) continue;
      safePaths.add(e.path.replaceAll('\\', '/'));
    }

    // 情况 A：manifest.json 在根目录
    if (safePaths.contains('manifest.json')) {
      return const _Layout(prefix: '', manifestPath: 'manifest.json');
    }

    // 情况 B：恰好一个顶层目录，且 manifest.json 在其下
    final roots = <String>{};
    for (final p in safePaths) {
      final slash = p.indexOf('/');
      if (slash <= 0) {
        // 根目录下有散落文件，但没有 manifest.json
        if (p.isNotEmpty) roots.add('<root-file>');
      } else {
        roots.add(p.substring(0, slash));
      }
    }

    if (roots.length == 1 && !roots.contains('<root-file>')) {
      final dir = roots.first;
      final manifest = '$dir/manifest.json';
      if (safePaths.contains(manifest)) {
        return _Layout(prefix: '$dir/', manifestPath: 'manifest.json');
      }
      issues.add(PackageIssue(
        manifest,
        '顶层目录 "$dir" 下没有 manifest.json',
      ));
      return _Layout(prefix: '$dir/', manifestPath: null);
    }

    if (roots.isEmpty) {
      issues.add(const PackageIssue('<package>', '包内没有任何文件'));
    } else {
      issues.add(PackageIssue(
        '<package>',
        'manifest.json 必须位于 zip 根目录，或唯一顶层目录之下；'
        '当前顶层有 ${roots.length} 个条目：${roots.take(5).join(", ")}'
        '${roots.length > 5 ? " …" : ""}',
      ));
    }
    return const _Layout(prefix: '', manifestPath: null);
  }

  static String? relativize(String path, String prefix) {
    final unified = path.replaceAll('\\', '/');
    if (prefix.isEmpty) return unified;
    if (!unified.startsWith(prefix)) return null;
    return unified.substring(prefix.length);
  }

  static String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';
}

class _Layout {
  const _Layout({required this.prefix, required this.manifestPath});
  final String? prefix;
  final String? manifestPath;
}
