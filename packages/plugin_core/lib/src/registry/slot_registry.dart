/// UI 插槽表与页面表。
///
/// 位置轴的设计见 `docs/16-extensibility.md` §4：
/// **插槽是字符串，不是枚举。** 加一个挂载位置 = 宿主 UI 里多写一行
/// `SlotHost('xxx.yyy')`，注册表这边一行都不用改。
///
/// 未知插槽名**静默忽略**（记一条 warning 审计，不算安装失败）——
/// 否则插件作者每用一个新插槽都要配 `minHostVersion`，生态会碎成一片。
library;

import '../audit/audit.dart';
import '../manifest/manifest.dart';
import '../permission/gatekeeper.dart';

/// 宿主预埋的插槽。
///
/// 这份清单只用于**自省与文档**，不是白名单 —— 插件往未知插槽放东西不会被拒，
/// 只是不会显示。
const List<String> knownSlots = <String>[
  'chat.header',
  'chat.toolbar',
  'chat.input.actions',
  'chat.message.menu',
  'chat.message.after',
  'home.cards',
  'settings.sections',
  'profile.actions',
  'global.fab',
  'plugin.detail',
];

/// 每个插槽的建议容量。超出不报错，宿主按 `order` 截断并聚合进「⋯」菜单。
const Map<String, int> slotCapacity = <String, int>{
  'chat.toolbar': 4,
  'chat.input.actions': 3,
  'chat.message.menu': 6,
  'chat.header': 2,
  'global.fab': 1,
};

/// 注册表里的一条 UI 控件。
class RegisteredUi {
  const RegisteredUi({
    required this.declaration,
    required this.pluginId,
    required this.pluginVersion,
  });

  final UiDeclaration declaration;
  final String pluginId;
  final String pluginVersion;

  String get slot => declaration.slot;
  String get id => declaration.id;

  /// 全局唯一键：`<pluginId>#<slot>#<id>`。
  String get key => '$pluginId#${declaration.slot}#${declaration.id}';

  @override
  String toString() => 'RegisteredUi($key)';
}

/// 注册表里的一条页面。
class RegisteredPage {
  const RegisteredPage({
    required this.declaration,
    required this.pluginId,
    required this.pluginVersion,
  });

  final PageDeclaration declaration;
  final String pluginId;
  final String pluginVersion;

  String get pageId => declaration.id;
  String get key => '$pluginId#${declaration.id}';

  @override
  String toString() => 'RegisteredPage($key)';
}

/// 插槽表 + 页面表。
class SlotRegistry {
  SlotRegistry({AuditSink? audit}) : audit = audit ?? const NullAuditSink();

  final AuditSink audit;

  final Map<String, List<RegisteredUi>> _bySlot = <String, List<RegisteredUi>>{};
  final Map<String, List<RegisteredPage>> _pagesByPlugin = <String, List<RegisteredPage>>{};

  /// 注册一个插件的全部 UI 与页面。重复注册同一插件会先清掉旧的（升级场景）。
  List<String> registerPlugin(PluginManifest manifest) {
    unregisterPlugin(manifest.id);

    final unknownSlots = <String>[];

    for (final decl in manifest.ui) {
      if (!knownSlots.contains(decl.slot)) {
        // 静默忽略，但记审计 —— 让插件作者能查出来
        unknownSlots.add(decl.slot);
        audit.write(AuditEntry(
          pluginId: manifest.id,
          pluginVersion: manifest.version,
          kind: 'plugin',
          primitive: 'ui.unknownSlot',
          argsDigest: <String, dynamic>{'slot': decl.slot, 'id': decl.id},
          result: 'ok',
        ));
        continue;
      }
      _bySlot.putIfAbsent(decl.slot, () => <RegisteredUi>[]).add(RegisteredUi(
            declaration: decl,
            pluginId: manifest.id,
            pluginVersion: manifest.version,
          ));
    }

    // 每个插槽内按 order 升序；同 order 按 pluginId 保证确定性
    for (final list in _bySlot.values) {
      list.sort((a, b) {
        final byOrder = a.declaration.order.compareTo(b.declaration.order);
        if (byOrder != 0) return byOrder;
        final byPlugin = a.pluginId.compareTo(b.pluginId);
        return byPlugin != 0 ? byPlugin : a.id.compareTo(b.id);
      });
    }

    if (manifest.pages.isNotEmpty) {
      _pagesByPlugin[manifest.id] = manifest.pages
          .map((p) => RegisteredPage(
                declaration: p,
                pluginId: manifest.id,
                pluginVersion: manifest.version,
              ))
          .toList(growable: false);
    }

    return unknownSlots;
  }

  /// 注销一个插件的 UI 与页面。
  int unregisterPlugin(String pluginId) {
    var removed = 0;
    for (final list in _bySlot.values) {
      final before = list.length;
      list.removeWhere((e) => e.pluginId == pluginId);
      removed += before - list.length;
    }
    _bySlot.removeWhere((_, list) => list.isEmpty);
    removed += _pagesByPlugin.remove(pluginId)?.length ?? 0;
    return removed;
  }

  /// 某插槽下的控件（已排序）。
  ///
  /// [gatekeeper] 非空时会**过滤掉权限已被撤销的控件** —— 与其显示一个点了就报错的
  /// 按钮，不如不显示。
  List<RegisteredUi> uiIn(String slot, {Gatekeeper? gatekeeper}) {
    final all = _bySlot[slot];
    if (all == null || all.isEmpty) return const <RegisteredUi>[];

    if (gatekeeper == null) return List<RegisteredUi>.unmodifiable(all);

    return all.where((ui) {
      for (final perm in ui.declaration.permissions) {
        if (!gatekeeper.check(ui.pluginId, perm).isAllowed) return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// 某插件的全部页面。
  List<RegisteredPage> pagesOf(String pluginId) =>
      List<RegisteredPage>.unmodifiable(_pagesByPlugin[pluginId] ?? const <RegisteredPage>[]);

  /// 按 (pluginId, pageId) 找页面。
  RegisteredPage? findPage(String pluginId, String pageId) {
    for (final p in _pagesByPlugin[pluginId] ?? const <RegisteredPage>[]) {
      if (p.pageId == pageId) return p;
    }
    return null;
  }

  /// 全局找页面（页面 id 在插件内唯一，跨插件可能重名）。
  List<RegisteredPage> findPageAnywhere(String pageId) => _pagesByPlugin.values
      .expand((list) => list)
      .where((p) => p.pageId == pageId)
      .toList(growable: false);

  int get uiCount => _bySlot.values.fold(0, (s, l) => s + l.length);

  int get pageCount => _pagesByPlugin.values.fold(0, (s, l) => s + l.length);

  Iterable<String> get occupiedSlots => _bySlot.keys;

  void clear() {
    _bySlot.clear();
    _pagesByPlugin.clear();
  }

  /// 自省：哪些插槽被占了、各有多少。
  Map<String, dynamic> describe() => <String, dynamic>{
        'knownSlots': knownSlots,
        'capacity': slotCapacity,
        'occupied': <String, int>{
          for (final e in _bySlot.entries)
            if (e.value.isNotEmpty) e.key: e.value.length,
        },
        'pages': <String, int>{
          for (final e in _pagesByPlugin.entries) e.key: e.value.length,
        },
      };
}
