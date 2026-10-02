/// 无头测试用的宿主服务假实现。
///
/// 存在的意义：**在没有 Flutter / Android / WebView 的情况下跑通整条链路**。
/// 内核只依赖 `HostClock` / `HostUi` / `HostFiles` / `ModelGateway` 这些抽象，
/// 所以这里用内存实现替换它们即可。
///
/// 这一层替代的是「宿主 Flutter 实现」，**不是**「插件 JS 运行时」——
/// 后者由 `headless_host.dart` 里的 `PluginRuntimeStub` 替代。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:plugin_core/plugin_core.dart';

// ─────────────────────────── 时钟 ───────────────────────────

/// 固定时刻的时钟，便于断言。
class FakeClock implements HostClock {
  FakeClock({
    required this.fixed,
    this.timezoneName = 'Asia/Shanghai',
    this.offsets = const <String, int>{
      'Asia/Shanghai': 8,
      'Asia/Tokyo': 9,
      'UTC': 0,
      'America/New_York': -5,
      'Europe/London': 0,
    },
  });

  final DateTime fixed;

  @override
  final String timezoneName;

  /// IANA 时区名 → 相对 UTC 的小时偏移。
  final Map<String, int> offsets;

  @override
  DateTime now() => fixed;

  @override
  DateTime? nowIn(String timezoneName) {
    final offset = offsets[timezoneName];
    if (offset == null) return null;
    final localOffset = offsets[this.timezoneName] ?? 0;
    // fixed 以本地时区表示；换算到目标时区
    final utc = fixed.subtract(Duration(hours: localOffset));
    return utc.add(Duration(hours: offset));
  }
}

// ─────────────────────────── UI ───────────────────────────

/// 记录型 UI：把所有调用记下来，便于断言"插件确实弹了提示"。
class RecordingUi implements HostUi {
  final List<Map<String, dynamic>> toasts = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> dialogs = <Map<String, dynamic>>[];
  final List<String> navigations = <String>[];
  final List<String> titles = <String>[];
  int closeCount = 0;

  /// 预设的对话框返回值（按钮 id）。
  String? dialogReturn;

  @override
  void toast(String text, {Duration duration = const Duration(seconds: 2), String kind = 'info'}) {
    toasts.add(<String, dynamic>{
      'text': text,
      'durationMs': duration.inMilliseconds,
      'kind': kind,
    });
  }

  @override
  Future<String?> dialog({
    required String title,
    String? content,
    List<UiButton> buttons = const <UiButton>[],
  }) async {
    dialogs.add(<String, dynamic>{
      'title': title,
      'content': content,
      'buttons': buttons.map((b) => b.id).toList(growable: false),
    });
    return dialogReturn ?? (buttons.isEmpty ? null : buttons.first.id);
  }

  @override
  Future<bool> navigate(String pageId, {Map<String, dynamic>? params}) async {
    navigations.add(pageId);
    return true;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Future<void> setTitle(String title) async {
    titles.add(title);
  }

  bool toastedWith(String substring) =>
      toasts.any((t) => (t['text'] as String).contains(substring));
}

// ─────────────────────────── 文件 ───────────────────────────

/// 内存文件系统。
class InMemoryFiles implements HostFiles {
  final Map<String, Uint8List> _files = <String, Uint8List>{};

  /// 直接塞一个文件（测试准备用）。
  ///
  /// **必须用 UTF-8 而不是 `text.codeUnits`**：中文的 code unit（如 U+4F60 = 20320）
  /// 塞进 `Uint8List` 会被截成 8 位（20320 & 0xFF = 96），读回来就是乱码。
  void seed(String absolutePath, String text) {
    _files[_normalize(absolutePath)] = Uint8List.fromList(utf8.encode(text));
  }

  /// 沙箱**之外**的文件 —— 用于验证越界读取确实失败。
  void seedOutside(String absolutePath, String text) => seed(absolutePath, text);

  bool contains(String absolutePath) => _files.containsKey(_normalize(absolutePath));

  @override
  Future<bool> exists(String absolutePath) async => _files.containsKey(_normalize(absolutePath));

  @override
  Future<String> readText(String absolutePath) async {
    final bytes = _files[_normalize(absolutePath)];
    if (bytes == null) throw StateError('文件不存在: $absolutePath');
    return utf8.decode(bytes);
  }

  @override
  Future<List<int>> readBytes(String absolutePath) async {
    final bytes = _files[_normalize(absolutePath)];
    if (bytes == null) throw StateError('文件不存在: $absolutePath');
    return bytes;
  }

  @override
  Future<void> writeText(String absolutePath, String text, {bool append = false}) async {
    final key = _normalize(absolutePath);
    final incoming = Uint8List.fromList(utf8.encode(text));
    if (append && _files.containsKey(key)) {
      final existing = _files[key]!;
      _files[key] = Uint8List.fromList(<int>[...existing, ...incoming]);
    } else {
      _files[key] = incoming;
    }
  }

  @override
  Future<void> writeBytes(String absolutePath, List<int> bytes, {bool append = false}) async {
    final key = _normalize(absolutePath);
    if (append && _files.containsKey(key)) {
      _files[key] = Uint8List.fromList(<int>[..._files[key]!, ...bytes]);
    } else {
      _files[key] = Uint8List.fromList(bytes);
    }
  }

  @override
  Future<int> size(String absolutePath) async => _files[_normalize(absolutePath)]?.length ?? 0;

  @override
  Future<void> delete(String absolutePath, {bool recursive = false}) async {
    _files.remove(_normalize(absolutePath));
  }

  @override
  Future<List<Map<String, dynamic>>> list(String absoluteDirectory,
      {bool recursive = false}) async {
    final prefix = _normalize(absoluteDirectory);
    return _files.entries
        .where((e) => e.key.startsWith(prefix))
        .map((e) => <String, dynamic>{'path': e.key, 'size': e.value.length})
        .toList(growable: false);
  }

  static String _normalize(String p) => p.replaceAll('\\', '/').toLowerCase();
}

// ─────────────────────────── 沙箱 ───────────────────────────

/// 固定的沙箱根目录映射。
class MapSandbox implements SandboxProvider {
  MapSandbox(Map<String, String> roots) : _roots = Map<String, String>.from(roots);

  final Map<String, String> _roots;

  @override
  String? dataRootFor(String pluginId) => _roots[pluginId];

  void register(String pluginId, String root) => _roots[pluginId] = root;
}

// ─────────────────────────── 模型网关 ───────────────────────────

/// 按脚本回应的模型网关。
///
/// 这是无头验证台的关键替身：它让「模型调用工具」这一步变得可 determinism 复现 ——
/// 不需要真的联网、不需要 Key，也就能在 CI 里跑。
class ScriptedGateway implements ModelGateway {
  ScriptedGateway(this.script, {this.modelName = 'fake-1'});

  /// 依次返回的回复。用完后再调用会抛错（避免测试静默多调了一次）。
  final List<ModelReply> script;

  final String modelName;

  final List<ModelRequest> requests = <ModelRequest>[];

  int _cursor = 0;

  int get callCount => requests.length;

  @override
  String get activeModel => modelName;

  @override
  Future<ModelReply> complete(ModelRequest request) async {
    requests.add(request);
    if (_cursor >= script.length) {
      throw StateError(
        '模型脚本已用完（已调用 ${requests.length} 次，脚本只有 ${script.length} 条）。'
        '这说明宿主多调了一次模型 —— 通常是工具循环没有正确收敛。',
      );
    }
    return script[_cursor++];
  }

  @override
  Stream<String> stream(ModelRequest request) async* {
    final reply = await complete(request);
    // 按 4 字符切块，模拟真实分片
    for (var i = 0; i < reply.text.length; i += 4) {
      yield reply.text.substring(i, (i + 4).clamp(0, reply.text.length));
    }
  }

  /// 最后一次请求里带的工具名列表。
  List<String> get lastToolNames {
    if (requests.isEmpty) return const <String>[];
    return requests.last.tools
        .map((t) => (t['function'] as Map<String, dynamic>?)?['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList(growable: false);
  }
}
