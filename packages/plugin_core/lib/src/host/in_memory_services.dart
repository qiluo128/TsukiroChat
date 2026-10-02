/// `context` / `message` / `schedule` 三个域的纯 Dart 参考实现。
///
/// 内核只定义了接口（[ContextSink] / [MessageStore] / [HostScheduler]）；
/// 这里是**可运行的实现**，用途有两个：
///   1. 无头测试与 Demo —— 不必等 Flutter 宿主
///   2. 作为 Flutter 宿主的实现参考（把存储换成 SQLite / 把 Timer 换成
///      `workmanager` 即可，语义与约束保持不变）
///
/// 三个实现都刻意把**安全约束**做进去，而不是留给宿主自觉：
///   - 上下文注入：可撤销、有长度上限、按 priority 排序、ttl 自动失效
///   - 消息操作：patch 只允许白名单字段
///   - 调度：最短周期、单插件任务数上限、插件停用即取消
library;

import 'dart:async';

import '../agent/chat_message.dart';
import '../common/errors.dart';
import '../primitive/host_services.dart';

// ═══════════════════════════ 上下文注入 ═══════════════════════════

/// 一条注入。
class ContextInjection {
  ContextInjection({
    required this.id,
    required this.pluginId,
    required this.text,
    required this.position,
    required this.priority,
    this.tag,
    this.expiresAt,
  });

  final String id;
  final String pluginId;
  final String text;

  /// `prepend` / `append`。
  final String position;

  final int priority;
  final String? tag;
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  int get byteLength => text.length * 3; // 中文按 UTF-8 粗估
}

/// 内存版上下文注入。
///
/// **不做 `context.replace`** 是刻意的：让插件替换整个 system prompt 会让它
/// 能冒充宿主设定的人设，也会让多个插件互相覆盖到不可预期。
/// 只给「追加 + 排序 + 撤销」，能力足够且可控（见 `docs/05-primitives.md` §3.20）。
class InMemoryContextSink implements ContextSink {
  InMemoryContextSink({
    this.maxBytesPerPlugin = 8 * 1024,
    this.maxBytesTotal = 32 * 1024,
  });

  /// 单插件注入上限。防止某个插件把上下文撑爆、把用户的 token 烧光。
  final int maxBytesPerPlugin;

  /// 全部插件合计上限。
  final int maxBytesTotal;

  final Map<String, List<ContextInjection>> _byPlugin = <String, List<ContextInjection>>{};
  int _counter = 0;

  @override
  Future<String> inject({
    required String pluginId,
    required String text,
    required String position,
    required int priority,
    String? tag,
    Duration? ttl,
  }) async {
    _evictExpired();

    final bytes = text.length * 3;
    final current = await currentBytes(pluginId);
    if (current + bytes > maxBytesPerPlugin) {
      throw TsukiroException(
        TsukiroErrorCode.rateLimited,
        '上下文注入超出单插件上限（已用 $current / $maxBytesPerPlugin 字节）。'
        '请用 tag 撤销旧注入，或缩短文本',
        details: <String, dynamic>{
          'used': current,
          'limit': maxBytesPerPlugin,
          'incoming': bytes,
        },
      );
    }

    final total = _totalBytes();
    if (total + bytes > maxBytesTotal) {
      throw TsukiroException(
        TsukiroErrorCode.rateLimited,
        '上下文注入总量超出上限（已用 $total / $maxBytesTotal 字节）',
      );
    }

    final id = 'inj_${(++_counter).toRadixString(36)}';
    _byPlugin.putIfAbsent(pluginId, () => <ContextInjection>[]).add(ContextInjection(
          id: id,
          pluginId: pluginId,
          text: text,
          position: position == 'prepend' ? 'prepend' : 'append',
          priority: priority,
          tag: tag,
          expiresAt: ttl == null ? null : DateTime.now().add(ttl),
        ));
    return id;
  }

  @override
  Future<int> clearPlugin(String pluginId) async {
    final removed = _byPlugin.remove(pluginId)?.length ?? 0;
    return removed;
  }

  /// 按 tag 精确撤销（插件换版本、换状态时用）。
  Future<int> clearByTag(String pluginId, String tag) async {
    final list = _byPlugin[pluginId];
    if (list == null) return 0;
    final before = list.length;
    list.removeWhere((i) => i.tag == tag);
    return before - list.length;
  }

  @override
  Future<int> currentBytes(String pluginId) async {
    _evictExpired();
    // 显式写 <int>：在 async 函数里，fold 的类型参数会被返回上下文
    // 推成 FutureOr<int>，于是 sum 变成 FutureOr<int>，`+` 就不认了。
    return (_byPlugin[pluginId] ?? const <ContextInjection>[])
        .fold<int>(0, (sum, i) => sum + i.byteLength);
  }

  /// 组装最终注入到 system prompt 的文本。
  ///
  /// 排序：`prepend` 在前、`append` 在后；组内按 priority 升序（越小越靠前），
  /// 同 priority 按插件 id 保证确定性。
  String buildInjection() {
    _evictExpired();
    final all = _byPlugin.values.expand((l) => l).toList();

    int compare(ContextInjection a, ContextInjection b) {
      final byPos = (a.position == 'prepend' ? 0 : 1)
          .compareTo(b.position == 'prepend' ? 0 : 1);
      if (byPos != 0) return byPos;
      final byPriority = a.priority.compareTo(b.priority);
      if (byPriority != 0) return byPriority;
      final byPlugin = a.pluginId.compareTo(b.pluginId);
      return byPlugin != 0 ? byPlugin : a.id.compareTo(b.id);
    }

    all.sort(compare);

    final prepends = all.where((i) => i.position == 'prepend').map((i) => i.text);
    final appends = all.where((i) => i.position == 'append').map((i) => i.text);

    final parts = <String>[...prepends, ...appends];
    return parts.where((p) => p.trim().isNotEmpty).join('\n\n');
  }

  int get count => _byPlugin.values.fold(0, (s, l) => s + l.length);

  Map<String, int> get bytesByPlugin => <String, int>{
        for (final e in _byPlugin.entries)
          e.key: e.value.fold(0, (s, i) => s + i.byteLength),
      };

  void clear() => _byPlugin.clear();

  void _evictExpired() {
    for (final list in _byPlugin.values) {
      list.removeWhere((i) => i.isExpired);
    }
    _byPlugin.removeWhere((_, l) => l.isEmpty);
  }

  int _totalBytes() =>
      _byPlugin.values.expand((l) => l).fold<int>(0, (s, i) => s + i.byteLength);
}

// ═══════════════════════════ 消息操作 ═══════════════════════════

/// 一条已存的消息。
class StoredMessage {
  StoredMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content,
    this.meta = const <String, dynamic>{},
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String sessionId;
  final ChatRole role;
  String? content;

  /// 插件私有数据放在 `meta[pluginId]` 下。
  Map<String, dynamic> meta;

  final DateTime createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'sessionId': sessionId,
        'role': role.name,
        'content': content,
        'meta': meta,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// 内存版消息存储。
class InMemoryMessageStore implements MessageStore {
  InMemoryMessageStore({
    this.sendHandler,
  });

  /// 主动发消息时宿主该做什么（真实环境是触发一次模型调用）。
  ///
  /// 做成回调是为了让内核不依赖 ModelGateway —— 装配关系由宿主决定。
  final Future<String> Function(String sessionId, String content)? sendHandler;

  final Map<String, StoredMessage> _messages = <String, StoredMessage>{};
  final Map<String, List<String>> _bySession = <String, List<String>>{};
  int _counter = 0;

  /// patch 允许改的字段。
  ///
  /// **不允许**改 `id` / `role` / `sessionId` / `createdAt` ——
  /// 那些是宿主的结构字段，让插件改会造成数据模型自相矛盾。
  static const Set<String> patchableFields = <String>{'content', 'richContent', 'meta'};

  /// 被拒绝的 patch 字段（测试与审计用）。
  final List<String> rejectedPatchFields = <String>[];

  @override
  Future<ChatMessage?> get(String messageId) async {
    final m = _messages[messageId];
    if (m == null) return null;
    return ChatMessage(role: m.role, content: m.content, meta: m.meta);
  }

  StoredMessage? getStored(String messageId) => _messages[messageId];

  @override
  Future<List<Map<String, dynamic>>> list(String sessionId, {int limit = 50}) async {
    final ids = _bySession[sessionId] ?? const <String>[];
    final slice = ids.length > limit ? ids.sublist(ids.length - limit) : ids;
    return slice
        .map((id) => _messages[id])
        .whereType<StoredMessage>()
        .map((m) => m.toJson())
        .toList(growable: false);
  }

  @override
  Future<bool> patch(String messageId, Map<String, dynamic> patch) async {
    final m = _messages[messageId];
    if (m == null) {
      throw TsukiroException(
        TsukiroErrorCode.notFound,
        '消息不存在：$messageId',
        details: <String, dynamic>{'messageId': messageId},
      );
    }

    // 白名单之外的字段：记下来但**不报错** —— 报了错插件会知道宿主的字段结构，
    // 而这个信息对它没用。静默丢弃 + 审计，行为更干净。
    for (final key in patch.keys) {
      if (!patchableFields.contains(key)) {
        rejectedPatchFields.add(key);
      }
    }

    if (patch.containsKey('content')) m.content = patch['content']?.toString();
    if (patch.containsKey('richContent')) {
      m.meta = <String, dynamic>{...m.meta, 'richContent': patch['richContent']};
    }
    if (patch['meta'] is Map) {
      m.meta = <String, dynamic>{...m.meta, ...(patch['meta']! as Map).cast<String, dynamic>()};
    }
    return true;
  }

  @override
  Future<bool> delete(String messageId) async {
    final m = _messages.remove(messageId);
    if (m == null) return false;
    _bySession[m.sessionId]?.remove(messageId);
    return true;
  }

  @override
  Future<String> append(String sessionId, ChatMessage message) async {
    final id = 'msg_${(++_counter).toRadixString(36)}';
    final stored = StoredMessage(
      id: id,
      sessionId: sessionId,
      role: message.role,
      content: message.content,
      meta: message.meta,
    );
    _messages[id] = stored;
    _bySession.putIfAbsent(sessionId, () => <String>[]).add(id);
    return id;
  }

  @override
  Future<String> send(String sessionId, String content) async {
    final id = await append(sessionId, ChatMessage(role: ChatRole.assistant, content: content));
    final handler = sendHandler;
    if (handler != null) {
      await handler(sessionId, content);
    }
    return id;
  }

  int get count => _messages.length;

  List<StoredMessage> messagesOf(String sessionId) =>
      (_bySession[sessionId] ?? const <String>[])
          .map((id) => _messages[id])
          .whereType<StoredMessage>()
          .toList(growable: false);

  void clear() {
    _messages.clear();
    _bySession.clear();
    rejectedPatchFields.clear();
  }
}

// ═══════════════════════════ 调度 ═══════════════════════════

/// 一个已排期任务。
class ScheduledTask {
  ScheduledTask({
    required this.id,
    required this.pluginId,
    required this.handler,
    required this.isInterval,
    required this.period,
    this.tag,
    this.immediate = false,
  });

  final String id;
  final String pluginId;
  final String handler;
  final bool isInterval;
  final Duration period;
  final String? tag;
  final bool immediate;

  /// 已触发次数。
  int fireCount = 0;

  /// 下一次触发时间（interval 任务用）。
  DateTime? nextRunAt;

  Timer? timer;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'pluginId': pluginId,
        'kind': isInterval ? 'interval' : 'once',
        'periodMs': period.inMilliseconds,
        'handler': handler,
        if (tag != null) 'tag': tag,
        'fireCount': fireCount,
        if (nextRunAt != null) 'nextRunAt': nextRunAt!.toIso8601String(),
      };
}

/// 内存版调度器。
///
/// 四条约束（没有约束的调度器就是耗电与烧钱黑洞，见 `docs/05-primitives.md` §3.22）：
///   1. 最短周期 —— 想更频繁请用事件，不要轮询
///   2. 单插件任务数上限
///   3. 连续触发（不补跑错过的周期）
///   4. 插件停用/卸载即取消
///
/// **权限的重新校验不在这里做**：任务触发时会去调原语，而原语每一步都过
/// `Gatekeeper`。所以"任务创建后用户撤销了 `model.chat`"这个场景天然会失败 ——
/// 这是比在调度器里缓存权限更可靠的做法。
class InMemoryScheduler implements HostScheduler {
  InMemoryScheduler({
    this.minPeriod = HostScheduler.minPeriod,
    this.maxTasksPerPlugin = HostScheduler.maxTasksPerPlugin,
    this.onFire,
    this.isPluginActive,
  });

  /// 最短周期。测试会调小它。
  final Duration minPeriod;

  final int maxTasksPerPlugin;

  /// 任务触发时的回调（真实环境是往插件的 Bridge 发 `inv schedule.fire`）。
  final void Function(ScheduledTask task)? onFire;

  /// 插件是否仍然可用。返回 false 时任务会被自动取消。
  ///
  /// 这是"插件已卸载但定时任务还在跑"的唯一防线。
  final bool Function(String pluginId)? isPluginActive;

  final Map<String, ScheduledTask> _tasks = <String, ScheduledTask>{};
  int _counter = 0;

  @override
  Future<String> once({
    required String pluginId,
    required Duration delay,
    required String handler,
    String? tag,
  }) async {
    if (delay < Duration.zero) {
      throw TsukiroException(TsukiroErrorCode.invalidArgs, 'delay 不能为负');
    }
    _assertCapacity(pluginId);

    final task = ScheduledTask(
      id: 'job_${(++_counter).toRadixString(36)}',
      pluginId: pluginId,
      handler: handler,
      isInterval: false,
      period: delay,
      tag: tag,
    );
    task.nextRunAt = DateTime.now().add(delay);
    task.timer = Timer(delay, () => _fire(task));
    _tasks[task.id] = task;
    return task.id;
  }

  @override
  Future<String> interval({
    required String pluginId,
    required Duration period,
    required String handler,
    String? tag,
    bool immediate = false,
  }) async {
    if (period < minPeriod) {
      throw TsukiroException(
        TsukiroErrorCode.invalidArgs,
        '周期不能短于 ${minPeriod.inSeconds} 秒（收到 ${period.inMilliseconds}ms）。'
        '需要更频繁请用事件，不要轮询',
        details: <String, dynamic>{
          'requestedMs': period.inMilliseconds,
          'minMs': minPeriod.inMilliseconds,
        },
      );
    }
    _assertCapacity(pluginId);

    final task = ScheduledTask(
      id: 'job_${(++_counter).toRadixString(36)}',
      pluginId: pluginId,
      handler: handler,
      isInterval: true,
      period: period,
      tag: tag,
      immediate: immediate,
    );
    task.nextRunAt = DateTime.now().add(immediate ? Duration.zero : period);
    task.timer = Timer.periodic(period, (_) => _fire(task));
    if (immediate) {
      // 立即先跑一次，但周期计时不重置
      Timer(Duration.zero, () => _fire(task));
    }
    _tasks[task.id] = task;
    return task.id;
  }

  @override
  Future<bool> cancel(String taskId) async {
    final task = _tasks.remove(taskId);
    task?.timer?.cancel();
    return task != null;
  }

  @override
  Future<List<Map<String, dynamic>>> list({String? pluginId}) async => _tasks.values
      .where((t) => pluginId == null || t.pluginId == pluginId)
      .map((t) => t.toJson())
      .toList(growable: false);

  @override
  Future<int> clearPlugin(String pluginId) async {
    final ids = _tasks.values.where((t) => t.pluginId == pluginId).map((t) => t.id).toList();
    for (final id in ids) {
      _tasks.remove(id)?.timer?.cancel();
    }
    return ids.length;
  }

  int get count => _tasks.length;

  int taskCountOf(String pluginId) =>
      _tasks.values.where((t) => t.pluginId == pluginId).length;

  ScheduledTask? taskOf(String id) => _tasks[id];

  void dispose() {
    for (final t in _tasks.values) {
      t.timer?.cancel();
    }
    _tasks.clear();
  }

  void _assertCapacity(String pluginId) {
    if (taskCountOf(pluginId) >= maxTasksPerPlugin) {
      throw TsukiroException(
        TsukiroErrorCode.rateLimited,
        '插件 $pluginId 的定时任务已达上限（$maxTasksPerPlugin）',
      );
    }
  }

  void _fire(ScheduledTask task) {
    // 插件已停用/卸载 → 任务自动取消，绝不继续跑
    if (isPluginActive != null && !isPluginActive!(task.pluginId)) {
      _tasks.remove(task.id)?.timer?.cancel();
      return;
    }

    task.fireCount++;
    if (task.isInterval) {
      task.nextRunAt = DateTime.now().add(task.period);
    } else {
      _tasks.remove(task.id);
    }
    onFire?.call(task);
  }
}
