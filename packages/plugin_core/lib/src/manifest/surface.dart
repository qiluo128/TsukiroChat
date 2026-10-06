/// 插件可视 Surface 声明。
///
/// Web Surface 运行插件自有 HTML/CSS/JS；Flame Surface 只选择宿主已注册的
/// gameType，普通插件包不能携带或动态执行 Dart/Flutter 代码。
library;

enum SurfaceKind {
  web,
  flame;

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

  @override
  String toString() => 'SurfaceDeclaration($id, ${kind.name}, $slot)';
}
