/// 运行期 UI 树：插件描述界面，宿主用 Flutter 渲染。
///
/// ## 为什么需要它
///
/// 插件想画一个「礼物展柜」（网格 + 卡片 + 图片），今天只能：
///   - 开 WebView 写 HTML → 主题接不上，还得带一整套前端
///   - 开 Flame                              → 为了一个网格引入游戏引擎
///
/// 两者对一个网格列表都太重。所以补一层：**声明式的原生窗口**。
///
/// ## 和其它层的分工
///
/// | 层 | 谁画 | 适合 |
/// |---|---|---|
/// | `provides.ui`（插槽控件） | 宿主 | 一两个按钮、一个开关 |
/// | **本文件（原生窗口）** | **宿主** | **列表、网格、卡片、图文** |
/// | `kind: web` Surface | 插件自己 | 复杂动画、富交互、已有前端 |
/// | `kind: flame` Surface | 宿主编译期注册 | 游戏 |
///
/// ## 为什么是「声明」而不是「构建」
///
/// 插件**拿不到 Flutter**，它只能描述"我要一个三列的网格"。
/// 这不是限制，是**主题一致性的来源** —— 因为宿主画，
/// 所以颜色、圆角、间距、深浅色全都自动跟着设计 token 走。
///
/// 一个用 WebView 画的界面永远做不到这点。
///
/// ## 硬限制（fail-closed）
///
/// 树是插件给的，所以每一条都要有上限：深度、节点数、子节点数、
/// 文本长度。**没有上限的递归结构就是一个 DoS 面**。
library;

import '../common/errors.dart';

/// 节点类型。
///
/// **封闭集合** —— 未知类型不报错，渲染成"不支持的控件"占位。
/// 这样插件用新版宿主的新控件时，在旧宿主上只是显示不全，
/// 而不是整个窗口打不开。
enum UiNodeType {
  // ── 布局 ──
  column,
  row,
  grid,
  list,
  spacer,
  divider,

  // ── 内容 ──
  text,
  image,
  icon,
  badge,
  progress,

  // ── 交互 ──
  button,
  toggle,
  card,

  // ── 结构 ──
  section,

  /// 未知类型。渲染成占位，不抛错。
  unknown;

  static UiNodeType parse(String raw) {
    for (final t in UiNodeType.values) {
      if (t.name == raw) return t;
    }
    return UiNodeType.unknown;
  }

  bool get isContainer =>
      this == column ||
      this == row ||
      this == grid ||
      this == list ||
      this == card ||
      this == section;
}

/// 语义化的强调级别。
///
/// **刻意不给任意颜色** —— 给颜色就等于给了一套 CSS，
/// 插件会开始写 `#FF5722`，然后深色模式下看不见。
/// 给语义，颜色由宿主按 token 决定。
enum UiEmphasis {
  normal,
  muted,
  primary,
  danger,
  success;

  static UiEmphasis parse(String? raw) {
    for (final e in UiEmphasis.values) {
      if (e.name == raw) return e;
    }
    return UiEmphasis.normal;
  }
}

/// 语义化的尺寸。同样不给像素值。
enum UiSize {
  sm,
  md,
  lg;

  static UiSize parse(String? raw) {
    for (final s in UiSize.values) {
      if (s.name == raw) return s;
    }
    return UiSize.md;
  }
}

/// 对齐。
enum UiAlign {
  start,
  center,
  end,
  spaceBetween;

  static UiAlign parse(String? raw) {
    for (final a in UiAlign.values) {
      if (a.name == raw) return a;
    }
    return UiAlign.start;
  }
}

/// 一个 UI 节点。
class UiNode {
  const UiNode({
    required this.type,
    this.id,
    this.text,
    this.subtitle,
    this.icon,
    this.image,
    this.emphasis = UiEmphasis.normal,
    this.size = UiSize.md,
    this.align = UiAlign.start,
    this.value,
    this.enabled = true,
    this.progress,
    this.columns,
    this.spacing,
    this.flex,
    this.onTap,
    this.children = const <UiNode>[],
  });

  final UiNodeType type;

  /// 事件回传时用它标识是哪个节点被点了。
  final String? id;

  final String? text;
  final String? subtitle;

  /// lucide 图标名（`gift` / `heart`…）。宿主做映射。
  final String? icon;

  /// 图片地址。**只允许 http/https** —— 见 [parse]。
  final String? image;

  final UiEmphasis emphasis;
  final UiSize size;
  final UiAlign align;

  /// toggle 的当前值。
  final bool? value;

  final bool enabled;

  /// progress 的 0..1。
  final double? progress;

  /// grid 的列数。
  final int? columns;

  /// 子项间距（token 单位，不是像素）。
  final double? spacing;

  /// 在父容器里的伸展比例。
  final int? flex;

  /// 点一下要发的事件名。
  final String? onTap;

  final List<UiNode> children;

  bool get isUnknown => type == UiNodeType.unknown;

  // ══════════════════ 限制 ══════════════════

  /// 树的最大深度。
  ///
  /// 递归结构必须有上限 —— 否则一个自引用/极深的树就能把
  /// 渲染栈打爆。12 层足够表达任何正常界面。
  static const int maxDepth = 12;

  /// 整棵树的最大节点数。
  static const int maxNodes = 400;

  /// 单个节点的最大子节点数。
  static const int maxChildren = 60;

  /// 文本最大长度（按字符）。
  static const int maxTextLength = 2000;

  /// 单次 update 的最大字节数。
  static const int maxPayloadBytes = 256 * 1024;

  // ══════════════════ 解析 ══════════════════

  /// 从插件给的 JSON 解析。
  ///
  /// 全程 fail-closed：超限抛错，不静默截断。
  /// 静默截断会让插件以为画上了，实际少了一半 —— 更难查。
  static UiNode parse(Map<String, dynamic> raw) {
    final counter = _Counter();
    final node = _parseNode(raw, depth: 0, counter: counter);
    return node;
  }

  static UiNode _parseNode(
    Map<String, dynamic> raw, {
    required int depth,
    required _Counter counter,
  }) {
    if (depth > maxDepth) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'UI 树超过 $maxDepth 层。请检查有没有把节点套得太深。',
      );
    }
    counter.count++;

    final typeName = raw['type']?.toString();
    if (typeName == null || typeName.isEmpty) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        'UI 节点缺少 type',
      );
    }

    final rawChildren = raw['children'];
    final children = <UiNode>[];
    if (rawChildren is List) {
      if (rawChildren.length > maxChildren) {
        throw TsukiroException(
          TsukiroErrorCode.invalidArgs,
          '单个节点最多 $maxChildren 个子节点，收到 ${rawChildren.length}',
        );
      }
      for (final child in rawChildren) {
        if (child is! Map) {
          throw TsukiroException(
            TsukiroErrorCode.invalidArgs,
            'children 里必须都是对象',
          );
        }
        children.add(_parseNode(
          child.map((k, v) => MapEntry('$k', v)),
          depth: depth + 1,
          counter: counter,
        ));
      }
    }

    return UiNode(
      type: UiNodeType.parse(typeName),
      id: _shortString(raw['id'], 128),
      text: _longString(raw['text']),
      subtitle: _longString(raw['subtitle']),
      icon: _shortString(raw['icon'], 64),
      image: _parseImage(raw['image']),
      emphasis: UiEmphasis.parse(raw['emphasis']?.toString()),
      size: UiSize.parse(raw['size']?.toString()),
      align: UiAlign.parse(raw['align']?.toString()),
      value: raw['value'] is bool ? raw['value'] as bool : null,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      progress: (raw['progress'] as num?)?.toDouble().clamp(0.0, 1.0),
      columns: (raw['columns'] as num?)?.toInt().clamp(1, 8),
      spacing: (raw['spacing'] as num?)?.toDouble().clamp(0, 64),
      flex: (raw['flex'] as num?)?.toInt().clamp(0, 20),
      onTap: _shortString(raw['onTap'], 128),
      children: children,
    );
  }

  /// 图片地址白名单。
  ///
  /// **只允许 http/https。**
  ///
  /// 不允许 `file:` —— 那是插件读宿主私有文件的入口。
  /// 也不允许 `data:` —— 一个 200KB 的 base64 就能塞满内存，
  /// 而且它让"图片"变成一个任意载荷通道。
  ///
  /// 插件自带图片（`asset:`）留到后面做，那需要限定在
  /// 插件自己的目录里，比 URL 白名单复杂。
  static String? _parseImage(Object? raw) {
    if (raw == null) return null;
    final url = raw.toString().trim();
    if (url.isEmpty) return null;
    if (url.length > 2048) {
      throw TsukiroException(TsukiroErrorCode.invalidArgs, '图片地址过长');
    }
    final lower = url.toLowerCase();
    if (!lower.startsWith('https://') && !lower.startsWith('http://')) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '图片地址只支持 http/https，收到「${url.length > 40 ? '${url.substring(0, 40)}…' : url}」',
      );
    }
    return url;
  }

  static String? _shortString(Object? raw, int max) {
    if (raw == null) return null;
    final s = raw.toString();
    if (s.length > max) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '字段过长（上限 $max 字符）',
      );
    }
    return s;
  }

  static String? _longString(Object? raw) =>
      _shortString(raw, maxTextLength);

  /// 遍历所有节点（含自身）。
  Iterable<UiNode> walk() sync* {
    yield this;
    for (final c in children) {
      yield* c.walk();
    }
  }

  /// 找第一棵树里所有带 id 的节点，供事件回传做映射。
  Map<String, UiNode> indexById() => <String, UiNode>{
        for (final n in walk())
          if (n.id != null && n.id!.isNotEmpty) n.id!: n,
      };

  @override
  String toString() => 'UiNode(${type.name}${id == null ? '' : ' #$id'}, '
      '${children.length} 子)';
}

class _Counter {
  int count = 0;
}
