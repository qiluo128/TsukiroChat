/// 设计令牌（design tokens）—— L1 美化包的全部能力。
///
/// 见 `docs/08-ui-slots.md` §8.1 与 `docs/16-extensibility.md`。
///
/// ## 核心设计：令牌是**值**，不是 CSS
///
/// 美化包只能覆盖一张**白名单**里的令牌，每个令牌有确定的类型与取值范围。
/// 宿主拿到 `#FF6B9D` 或 `16` 之后自己拼装样式，因此 `url(...)` / `expression(...)` /
/// `@import` 这类注入**无从下手** —— 不是"我们过滤了"，而是"根本没有地方可放"。
///
/// ## 为什么未知令牌名要报错
///
/// 与权限名同一个原则：拼错的令牌如果被静默忽略，主题作者会看到"我明明改了但没生效"，
/// 而这种问题极难排查。宁可安装时报错。
library;

/// 令牌的取值类型。
enum TokenKind {
  /// 颜色，`#RGB` / `#RRGGBB` / `#RRGGBBAA`。
  color,

  /// 尺寸，数字（逻辑像素）或 `"16px"` / `"1.2rem"`。
  size,

  /// 字体名，内置字体标识或包内相对路径。
  family,

  /// 字重，100–900 的整数。
  weight,

  /// 阴影档位。**只接受枚举**，不接受 CSS 阴影串。
  shadow,

  /// 时长，毫秒。
  duration,

  /// 缓动函数。**只接受枚举**。
  easing,

  /// 图标名。
  icon,
}

/// 一个令牌的定义。
class TokenSpec {
  const TokenSpec(this.name, this.kind, this.description, {this.enumValues});

  final String name;
  final TokenKind kind;
  final String description;

  /// [TokenKind.shadow] / [TokenKind.easing] 的合法取值。
  final List<String>? enumValues;
}

/// 阴影档位。
const List<String> shadowLevels = <String>['none', 'soft', 'medium', 'strong', 'glow'];

/// 缓动档位。
const List<String> easingLevels = <String>[
  'linear',
  'standard',
  'decelerate',
  'accelerate',
  'spring',
];

/// 令牌目录 —— **这是全部可换肤能力的边界**。
const Map<String, TokenSpec> tokenCatalog = <String, TokenSpec>{
  // ── 颜色 ──
  'color.primary': TokenSpec('color.primary', TokenKind.color, '主色（按钮、强调）'),
  'color.background': TokenSpec('color.background', TokenKind.color, '页面背景'),
  'color.surface': TokenSpec('color.surface', TokenKind.color, '卡片/面板底色'),
  'color.text': TokenSpec('color.text', TokenKind.color, '主文本'),
  'color.textMuted': TokenSpec('color.textMuted', TokenKind.color, '次要文本'),
  'color.userBubble': TokenSpec('color.userBubble', TokenKind.color, '用户气泡'),
  'color.assistantBubble': TokenSpec('color.assistantBubble', TokenKind.color, 'AI 气泡'),
  'color.divider': TokenSpec('color.divider', TokenKind.color, '分隔线'),
  'color.danger': TokenSpec('color.danger', TokenKind.color, '危险/删除'),
  'color.success': TokenSpec('color.success', TokenKind.color, '成功'),

  // ── 字体 ──
  'font.family': TokenSpec('font.family', TokenKind.family, '正文字体'),
  'font.familyMono': TokenSpec('font.familyMono', TokenKind.family, '等宽字体'),
  'font.size.body': TokenSpec('font.size.body', TokenKind.size, '正文字号'),
  'font.size.caption': TokenSpec('font.size.caption', TokenKind.size, '辅助文字字号'),
  'font.size.title': TokenSpec('font.size.title', TokenKind.size, '标题字号'),
  'font.lineHeight': TokenSpec('font.lineHeight', TokenKind.size, '行高倍数'),
  'font.weight.regular': TokenSpec('font.weight.regular', TokenKind.weight, '常规字重'),
  'font.weight.bold': TokenSpec('font.weight.bold', TokenKind.weight, '粗体字重'),

  // ── 圆角 ──
  'radius.bubble': TokenSpec('radius.bubble', TokenKind.size, '气泡圆角'),
  'radius.card': TokenSpec('radius.card', TokenKind.size, '卡片圆角'),
  'radius.button': TokenSpec('radius.button', TokenKind.size, '按钮圆角'),
  'radius.input': TokenSpec('radius.input', TokenKind.size, '输入框圆角'),

  // ── 间距 ──
  'spacing.page': TokenSpec('spacing.page', TokenKind.size, '页面内边距'),
  'spacing.messageGap': TokenSpec('spacing.messageGap', TokenKind.size, '消息间距'),
  'spacing.section': TokenSpec('spacing.section', TokenKind.size, '分区间距'),

  // ── 阴影 ──
  'shadow.card': TokenSpec('shadow.card', TokenKind.shadow, '卡片阴影', enumValues: shadowLevels),
  'shadow.fab': TokenSpec('shadow.fab', TokenKind.shadow, '悬浮按钮阴影', enumValues: shadowLevels),

  // ── 动画 ──
  'animation.duration.fast': TokenSpec('animation.duration.fast', TokenKind.duration, '快速动画时长(ms)'),
  'animation.duration.normal': TokenSpec('animation.duration.normal', TokenKind.duration, '常规动画时长(ms)'),
  'animation.easing.standard': TokenSpec('animation.easing.standard', TokenKind.easing, '标准缓动', enumValues: easingLevels),

  // ── 图标 ──
  'icon.send': TokenSpec('icon.send', TokenKind.icon, '发送按钮图标'),
  'icon.regenerate': TokenSpec('icon.regenerate', TokenKind.icon, '重新生成图标'),
  'icon.copy': TokenSpec('icon.copy', TokenKind.icon, '复制图标'),
};

/// 令牌校验问题。
class TokenIssue {
  const TokenIssue(this.token, this.message);

  final String token;
  final String message;

  @override
  String toString() => '$token: $message';
}

/// 令牌校验器。
class TokenValidator {
  const TokenValidator();

  /// 校验一批令牌。返回空列表表示全部合法。
  List<TokenIssue> validate(Map<String, dynamic> tokens) {
    final issues = <TokenIssue>[];
    tokens.forEach((name, value) {
      final spec = tokenCatalog[name];
      if (spec == null) {
        issues.add(TokenIssue(name, _unknownTokenHint(name)));
        return;
      }
      final problem = _checkValue(spec, value);
      if (problem != null) issues.add(TokenIssue(name, problem));
    });
    return issues;
  }

  /// 拼错令牌名时给出最接近的候选 —— 拼错的人需要的是提示，不是"未知令牌"四个字。
  static String _unknownTokenHint(String name) {
    final candidates = _closest(name, tokenCatalog.keys, 3);
    if (candidates.isEmpty) {
      return '未知令牌。可用令牌见 docs/08-ui-slots.md §8.1';
    }
    return '未知令牌。是不是想写：${candidates.join(" / ")}？';
  }

  static String? _checkValue(TokenSpec spec, Object? value) {
    // 所有令牌都拒绝含 CSS 结构的字符串。
    // 即使类型正确（比如 color 传了字符串），也不允许里面藏东西。
    if (value is String) {
      final lower = value.toLowerCase();
      for (final bad in const <String>[
        'url(',
        'expression(',
        '@import',
        'javascript:',
        '<',
        '>',
        '{',
        '}',
        ';',
        '/*',
      ]) {
        if (lower.contains(bad)) {
          return '取值里不允许出现 "$bad"（令牌是值，不是 CSS）';
        }
      }
    }

    switch (spec.kind) {
      case TokenKind.color:
        if (value is! String) return '颜色必须是字符串，如 "#FF6B9D"';
        if (!RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(value)) {
          return '颜色格式非法（支持 #RGB / #RRGGBB / #RRGGBBAA），收到 "$value"';
        }
        return null;

      case TokenKind.size:
        if (value is num) {
          if (value < 0) return '尺寸不能为负';
          return null;
        }
        if (value is String &&
            RegExp(r'^\d+(\.\d+)?(px|rem|em|%)$').hasMatch(value)) {
          return null;
        }
        return '尺寸必须是数字或带单位的值（如 16 或 "16px"），收到 "$value"';

      case TokenKind.weight:
        if (value is! num) return '字重必须是数字';
        if (value < 100 || value > 900 || value % 100 != 0) {
          return '字重必须是 100–900 的整百，收到 $value';
        }
        return null;

      case TokenKind.duration:
        if (value is! num) return '时长必须是数字（毫秒）';
        if (value < 0 || value > 5000) {
          return '时长必须在 0–5000ms 之间（再长就不是"动画"了，是卡顿）';
        }
        return null;

      case TokenKind.shadow:
      case TokenKind.easing:
        final allowed = spec.enumValues ?? const <String>[];
        if (value is! String || !allowed.contains(value)) {
          return '取值必须是 ${allowed.join(" / ")} 之一，收到 "$value"';
        }
        return null;

      case TokenKind.family:
        if (value is! String || value.trim().isEmpty) return '字体名不能为空';
        // 内置字体标识，或包内相对路径
        if (value.contains('..')) {
          return '字体路径不能含 ".."（防止读包外文件）';
        }
        if (value.startsWith('/') || value.startsWith('\\')) {
          return '字体路径必须是包内相对路径，不接受绝对路径';
        }
        // Windows 盘符：C:\x.ttf 这种既不是绝对 POSIX 路径、也不含 ".."，
        // 光靠上面两条会漏掉
        if (RegExp(r'^[a-zA-Z]:').hasMatch(value)) {
          return '字体路径不能带盘符';
        }
        if (value.contains('\u0000')) return '字体名包含非法字符';
        return null;

      case TokenKind.icon:
        if (value is! String || value.trim().isEmpty) return '图标名不能为空';
        if (!RegExp(r'^[a-z0-9:_-]+$').hasMatch(value)) {
          return '图标名只允许小写字母、数字、冒号、下划线、连字符（如 lucide:send）';
        }
        return null;
    }
  }

  /// 简单的编辑距离，用于"是不是想写 X"提示。
  static List<String> _closest(String input, Iterable<String> candidates, int limit) {
    int distance(String a, String b) {
      final prev = List<int>.generate(b.length + 1, (i) => i);
      for (var i = 1; i <= a.length; i++) {
        var last = prev[0];
        prev[0] = i;
        for (var j = 1; j <= b.length; j++) {
          final tmp = prev[j];
          prev[j] = a[i - 1] == b[j - 1]
              ? last
              : 1 + [last, prev[j], prev[j - 1]].reduce((x, y) => x < y ? x : y);
          last = tmp;
        }
      }
      return prev[b.length];
    }

    final scored = candidates
        .map((c) => MapEntry(c, distance(input.toLowerCase(), c.toLowerCase())))
        .where((e) => e.value <= 6)
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return scored.take(limit).map((e) => e.key).toList(growable: false);
  }
}

/// 美化包声明。
class ThemeDeclaration {
  const ThemeDeclaration({
    required this.id,
    required this.name,
    required this.tokens,
    this.base,
    this.isDark = false,
  });

  final String id;
  final String name;

  /// 已校验的令牌（键一定在 [tokenCatalog] 里）。
  final Map<String, Object> tokens;

  /// 基于哪个主题派生（`null` 表示基于宿主默认）。
  final String? base;

  final bool isDark;

  /// 取一个令牌值，缺失时返回 null。
  T? get<T>(String token) {
    final v = tokens[token];
    return v is T ? v : null;
  }

  @override
  String toString() => 'ThemeDeclaration($id, ${tokens.length} 个令牌)';
}
