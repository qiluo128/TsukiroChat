/// 插件可视 Surface 声明。
///
/// Web Surface 运行插件自有 HTML/CSS/JS；Flame Surface 只选择宿主已注册的
/// gameType，普通插件包不能携带或动态执行 Dart/Flutter 代码。
library;

enum SurfaceKind {
  /// 插件自带 HTML/CSS/JS，宿主开 WebView。
  web,

  /// 宿主编译期注册的 FlameGame。插件只选 gameType。
  flame,

  /// **声明式的原生界面。**
  ///
  /// 插件在运行期送来一棵 [UiNode] 树，宿主用 Flutter 渲染。
  /// 插件拿不到 Flutter，只能描述"我要一个三列网格" ——
  /// 这不是限制，是**主题一致性的来源**：因为宿主画，
  /// 颜色、圆角、间距、深浅色全都自动跟着设计 token 走。
  ///
  /// 适合列表、网格、卡片、图文这类"用 Flutter 画最简单"的界面。
  /// 用 WebView 画它们要带一整套前端，而且主题永远接不上。
  native;

  static SurfaceKind? parse(String? raw) {
    for (final value in SurfaceKind.values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}

const Set<String> surfaceCapabilities = <String>{
  'interaction',
  'dragDrop',
  'richText',
  'animation',
  'canvas',
};

class SurfaceDeclaration {
  const SurfaceDeclaration({
    required this.id,
    required this.kind,
    required this.slot,
    this.entry,
    this.gameType,
    this.presentation = 'page',
    this.minWidth,
    this.minHeight,
    this.maxWidth,
    this.maxHeight,
    this.capabilities = const <String>[],
    this.permissions = const <String>[],
  });

  final String id;
  final SurfaceKind kind;
  final String slot;
  final String? entry;
  final String? gameType;
  final String presentation;
  final double? minWidth;
  final double? minHeight;
  final double? maxWidth;
  final double? maxHeight;
  final List<String> capabilities;
  final List<String> permissions;

  bool get isWeb => kind == SurfaceKind.web;
  bool get isFlame => kind == SurfaceKind.flame;
  bool get isNative => kind == SurfaceKind.native;

  /// 这种 Surface 需不需要插件自带资源（entry / gameType）。
  ///
  /// native 不需要 —— 它的内容在运行期由插件送来，
  /// 清单里只有一个 id 和一串尺寸约束。
  bool get needsEntry => kind == SurfaceKind.web;
  bool get needsGameType => kind == SurfaceKind.flame;

  @override
  String toString() => 'SurfaceDeclaration($id, ${kind.name}, $slot)';
}
