/// UI 插槽树与页面表。
///
/// 位置轴的设计见 `docs/16-extensibility.md` §4：
/// **插槽是字符串，不是枚举。** 加一个挂载位置 = 宿主 UI 里多写一行
/// `PluginSlot(slot: 'xxx.yyy')`，注册表这边一行都不用改。
///
/// 未知插槽名**静默忽略**（记一条审计，不算安装失败）——
/// 否则插件作者每用一个新插槽都要配 `minHostVersion`，生态会碎成一片。
library;

import '../audit/audit.dart';
import '../manifest/manifest.dart';
import '../permission/gatekeeper.dart';

/// 宿主基线的插槽。
///
/// ## 这份清单的定位变过
///
/// 以前它是**白名单**：不在里面的插槽，插件注册时直接被丢掉。
/// 那意味着**加一个新插槽必须改内核** —— 而插槽本来就该是
/// 「界面上多写一行」，不该是内核的事。
///
/// 现在它只是**基线**：给自省、文档和向后兼容用。
/// 真正的来源是界面自己声明的 [SlotRegistry.declare] ——
/// 界面里写一个 `PluginSlot(slot: 'x.y')`，那个插槽就存在了。
///
/// 注册时只校验**格式**（形如 `a.b.c`），不校验成员资格。
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

  // 智能体相关（docs/18 §7.1）。
  // 智能体已经取代会话成为核心单位，插件自然需要往它的界面里塞东西
  // （比如「查看 AI 心情」）。
  'agent.header',
  'agent.actions',
  'agent.sections',
];

/// 每个插槽的建议容量。超出不报错，宿主按 `order` 截断并聚合进「⋯」菜单。
const Map<String, int> slotCapacity = <String, int>{
  'chat.toolbar': 4,
  'chat.input.actions': 3,
  'chat.message.menu': 6,
  'chat.header': 2,
  'global.fab': 1,
  'agent.actions': 3,
  'agent.header': 3,
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

/// 一个插入点。
class SlotPoint {
  const SlotPoint({
    required this.path,
    this.label,
    this.capacity = 99,
    this.fromBaseline = false,
  });

  /// 形如 `chat.toolbar` / `chat.toolbar.extra`。
  final String path;

  /// 给插件作者看的人话说明。
  final String? label;

  /// 建议容量。超出不报错，宿主按 order 截断。
  final int capacity;

  /// 来自内核基线（而不是界面声明）。
  final bool fromBaseline;

  /// 父路径。`chat.toolbar` 的父是 `chat`；顶层没有父。
  String? get parent {
    final i = path.lastIndexOf('.');
    return i <= 0 ? null : path.substring(0, i);
  }

  @override
  String toString() => 'SlotPoint($path)';
}

/// 插槽树 + 页面表。
class SlotRegistry {
  SlotRegistry({AuditSink? audit, bool withBaseline = true})
      : audit = audit ?? const NullAuditSink() {
    if (withBaseline) {
      for (final p in knownSlots) {
        declare(p, capacity: slotCapacity[p] ?? 99, fromBaseline: true);
      }
    }
  }

  final AuditSink audit;

  final Map<String, List<RegisteredUi>> _bySlot = <String, List<RegisteredUi>>{};
  final Map<String, List<RegisteredPage>> _pagesByPlugin = <String, List<RegisteredPage>>{};

  /// 已知的插入点。基线 + 界面声明的合起来。
  final Map<String, SlotPoint> _points = <String, SlotPoint>{};

  // ══════════════════ 声明（界面调用） ══════════════════

  /// 声明一个插入点。
  ///
  /// **界面在 build 时调它** —— 于是在界面里写一行
  /// `PluginSlot(slot: 'newpage.thing')` 就等于给插件开了一个新位置，
  /// 内核一行不用改。
  ///
  /// 幂等：同一个路径重复声明不会报错（build 会被调很多次）。
  void declare(
    String path, {
    String? label,
    int capacity = 99,
    bool fromBaseline = false,
  }) {
    final normalized = path.trim();
    if (!isWellFormedSlot(normalized)) return;

    final existing = _points[normalized];
    if (existing != null) {
      // build 会被调很多次，没有新信息就别重建对象
      final sameLabel = label == null || label == existing.label;
      final sameCapacity = capacity == existing.capacity;
      // 界面声明的信息比基线更具体，允许覆盖
      if (sameLabel && sameCapacity && (!existing.fromBaseline || fromBaseline)) return;
      _points[normalized] = SlotPoint(
        path: normalized,
        label: label ?? existing.label,
        capacity: capacity,
        fromBaseline: fromBaseline && existing.fromBaseline,
      );
      return;
    }

    _points[normalized] = SlotPoint(
      path: normalized,
      label: label,
      capacity: capacity,
      fromBaseline: fromBaseline,
    );
  }

  void declareAll(Iterable<String> paths, {bool fromBaseline = false}) {
    for (final p in paths) {
      declare(p, capacity: slotCapacity[p] ?? 99, fromBaseline: fromBaseline);
    }
  }

  /// 插槽路径的格式校验。
  ///
  /// **只校验形状，不校验成员资格。**
  ///
  /// 以前用已知清单做白名单，结果是「加插槽要改内核」。
  /// 现在任何形如 `a.b.c` 的路径都合法：界面声明了就渲染、
  /// 没声明就不渲染 —— 这才是插槽该有的语义。
  static bool isWellFormedSlot(String path) {
    if (path.isEmpty || path.length > 128) return false;
    if (path.split('.').length > 5) return false;
    return RegExp(r'^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)*$').hasMatch(path);
  }

  /// 某个插入点现在有没有被声明。
  bool isDeclared(String path) => _points.containsKey(path);

  /// 所有插入点，按路径排序。
  List<SlotPoint> get points {
    final list = _points.values.toList(growable: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    return list;
  }

  /// 某个路径下的直接子节点。
  List<SlotPoint> childrenOf(String path) {
    final list = _points.values.where((p) => p.parent == path).toList(growable: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    return list;
  }

  /// 树形结构（给 `slot.list` 与自省用）。
  ///
  /// 插件靠它在运行期问「有哪些位置能用」，而不是翻文档猜。
  /// **能发现和能使用一样重要** —— 宿主加了位置，插件立刻能用。
  List<Map<String, dynamic>> tree() {
    final roots = _points.values.where((p) => p.parent == null).toList(growable: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    return roots.map(_nodeOf).toList(growable: false);
  }

  Map<String, dynamic> _nodeOf(SlotPoint point) {
    final kids = childrenOf(point.path);
    return <String, dynamic>{
      'path': point.path,
      if (point.label != null) 'label': point.label,
      'capacity': point.capacity,
      // 有多少插件控件挂在这儿 —— 界面据此决定要不要占位
      'occupied': _bySlot[point.path]?.length ?? 0,
      if (kids.isNotEmpty)
        'children': kids.map(_nodeOf).toList(growable: false),
    };
  }

  // ══════════════════ 插件注册 ══════════════════

  /// 注册一个插件的全部 UI 与页面。重复注册同一插件会先清掉旧的（升级场景）。
  List<String> registerPlugin(PluginManifest manifest) {
    unregisterPlugin(manifest.id);

    final badSlots = <String>[];

    for (final decl in manifest.ui) {
      if (!isWellFormedSlot(decl.slot)) {
        // **只有格式错误的才丢弃**（空串、超深、含非法字符）。
        //
        // 格式对但界面还没声明的**照样注册** —— 界面可能还没 build 到，
        // 而且「插件先加载还是界面先渲染」不该决定谁有效。
        badSlots.add(decl.slot);
        audit.write(AuditEntry(
          pluginId: manifest.id,
          pluginVersion: manifest.version,
          kind: 'plugin',
          primitive: 'ui.badSlot',
          argsDigest: <String, dynamic>{'slot': decl.slot, 'id': decl.id},
          result: 'rejected',
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

    return badSlots;
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
    _points.removeWhere((_, p) => !p.fromBaseline);
  }

  /// 自省：有哪些插入点、哪些被占了。
  Map<String, dynamic> describe() => <String, dynamic>{
        // 树形 —— 插件靠它发现位置
        'tree': tree(),
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
