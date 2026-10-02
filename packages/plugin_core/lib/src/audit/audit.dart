/// 审计日志的写入接口与脱敏规则。
///
/// **脱敏必须在写入之前完成**，而不是在读取时。日志本身不能成为泄密渠道：
/// 一旦 `model.chat` 的对话原文进了数据库，后续任何"展示时打码"都只是掩耳盗铃
/// —— 文件、备份、导出里都还是明文。
///
/// 规则见 `docs/06-permissions.md` §7.2。
library;

/// 一条审计记录。
class AuditEntry {
  AuditEntry({
    required this.pluginId,
    required this.kind,
    required this.result,
    this.pluginVersion,
    this.primitive,
    this.permission,
    this.argsDigest,
    this.errorCode,
    this.durationMs,
    this.bytesOut,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final DateTime timestamp;
  final String pluginId;

  /// `primitive` / `permission` / `plugin` / `network` / `hook`。
  final String kind;

  final String? pluginVersion;
  final String? primitive;
  final String? permission;

  /// **已脱敏**的参数摘要。
  final Map<String, dynamic>? argsDigest;

  /// `ok` / `denied` / `error`。
  final String result;

  final String? errorCode;
  final int? durationMs;
  final int? bytesOut;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': timestamp.toIso8601String(),
        'pluginId': pluginId,
        if (pluginVersion != null) 'pluginVersion': pluginVersion,
        'kind': kind,
        if (primitive != null) 'primitive': primitive,
        if (permission != null) 'permission': permission,
        if (argsDigest != null) 'argsDigest': argsDigest,
        'result': result,
        if (errorCode != null) 'errorCode': errorCode,
        if (durationMs != null) 'durationMs': durationMs,
        if (bytesOut != null) 'bytesOut': bytesOut,
      };

  @override
  String toString() => 'AuditEntry($pluginId $primitive $result)';
}

/// 审计写入端。
///
/// 宿主注入具体实现（写 SQLite）；内核只依赖这个接口，从而保持可单测。
abstract class AuditSink {
  void write(AuditEntry entry);
}

/// 丢弃全部审计（测试与"审计未启用"场景）。
class NullAuditSink implements AuditSink {
  const NullAuditSink();

  @override
  void write(AuditEntry entry) {}
}

/// 内存审计（测试用，可断言写入了什么）。
class MemoryAuditSink implements AuditSink {
  final List<AuditEntry> entries = <AuditEntry>[];

  @override
  void write(AuditEntry entry) => entries.add(entry);

  void clear() => entries.clear();

  Iterable<AuditEntry> ofPlugin(String pluginId) =>
      entries.where((e) => e.pluginId == pluginId);
}

/// 审计参数脱敏。
///
/// 与 `docs/06-permissions.md` §7.2 的表格一一对应。
class AuditRedactor {
  const AuditRedactor();

  /// 生成某次原语调用的脱敏参数摘要。
  ///
  /// 未知原语一律**只记参数名，不记值** —— fail-closed：宁可少记，不可多记。
  Map<String, dynamic>? digest(String primitive, Map<String, dynamic>? args) {
    if (args == null || args.isEmpty) return null;

    switch (primitive) {
      // 只记路径 / 条数，绝不记内容
      case 'fs.read':
      case 'fs.write':
      case 'fs.delete':
      case 'fs.meta':
      case 'fs.list':
        return <String, dynamic>{
          if (args['path'] != null) 'path': args['path'],
          if (args['recursive'] != null) 'recursive': args['recursive'],
        };

      case 'model.chat':
      case 'model.embed':
      case 'model.vision':
        final messages = args['messages'];
        return <String, dynamic>{
          'messageCount': messages is List ? messages.length : null,
          'hasTools': args['tools'] != null,
          'stream': args['stream'] == true,
        };

      case 'sms.send':
        return <String, dynamic>{
          'to': _maskPhone(args['to']?.toString()),
          'textLength': (args['text']?.toString() ?? '').length,
        };

      case 'sms.list':
      case 'sms.listen':
        return <String, dynamic>{'limit': args['limit']};

      case 'contact.list':
      case 'contact.search':
      case 'contact.get':
        // 通讯录是高度敏感个人信息，连查询词都不记
        return <String, dynamic>{'count': null};

      case 'location.get':
      case 'location.watch':
      case 'location.geocode':
        return <String, dynamic>{
          'lat': _roundCoord(args['lat']),
          'lng': _roundCoord(args['lng']),
        };

      case 'sys.clipboard.read':
      case 'sys.clipboard.write':
        return <String, dynamic>{
          'textLength': (args['text']?.toString() ?? '').length,
        };

      case 'net.request':
      case 'net.download':
      case 'net.upload':
      case 'net.websocket':
        return <String, dynamic>{
          'host': _hostOf(args['url']?.toString()),
          'method': args['method'],
        };

      // 加密：绝不记密钥，只记算法
      case 'crypto.hash':
      case 'crypto.random':
      case 'crypto.encrypt':
      case 'crypto.decrypt':
        return <String, dynamic>{'algo': args['algo']};

      // 上下文注入：记 tag 与长度，不记内容
      case 'context.inject':
      case 'context.append':
        return <String, dynamic>{
          'tag': args['tag'],
          'textLength': (args['text']?.toString() ?? '').length,
        };

      // 消息操作：记 id，不记内容
      case 'message.send':
        return <String, dynamic>{
          'contentLength': (args['content']?.toString() ?? '').length,
        };
      case 'message.update':
      case 'message.append':
      case 'message.delete':
      case 'message.get':
        return <String, dynamic>{'messageId': args['messageId']};

      default:
        // fail-closed：未知原语只记参数名
        return <String, dynamic>{
          'argKeys': args.keys.toList(growable: false),
        };
    }
  }

  /// 手机号打码：保留前 3 后 4。
  static String? _maskPhone(String? phone) {
    if (phone == null || phone.isEmpty) return null;
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) return '***';
    return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
  }

  /// 坐标降到 2 位小数（约 1km 精度）。
  static num? _roundCoord(Object? v) {
    if (v is num) return (v * 100).round() / 100;
    return null;
  }

  /// 只保留域名，丢掉路径与查询串（路径可能含 token）。
  static String? _hostOf(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.host;
  }
}
