/// SSE（Server-Sent Events）解析。
///
/// **这是流式接入最容易写错的地方**：网络分片与 SSE 行边界没有任何关系，
/// 一个 `data:` 行被切成两半是常态。朴素实现（"每个 chunk 当成一行"）在
/// 短回复上看起来正常，一遇到长回复就出乱码或丢字。
///
/// 所以这里维护一个跨 chunk 的行缓冲，只处理**完整行**。
library;

import 'dart:async';
import 'dart:convert';

/// 把字节流解析为 SSE 的 `data:` 载荷流。
///
/// 行为：
///   - 处理 `\r\n` 与 `\n` 两种换行
///   - 跳过空行（事件分隔）与以 `:` 开头的注释行（很多服务用 `: ping` 做心跳）
///   - 遇到 `data: [DONE]` 结束流（OpenAI 的约定）
///   - 流在**没有尾部换行**时结束也能正确处理最后一行
///   - 忽略 `event:` / `id:` / `retry:` 字段（暂不需要）
Stream<String> sseDataEvents(
  Stream<List<int>> bytes, {
  bool stopOnDone = true,
}) async* {
  var pending = '';

  await for (final chunk in bytes.transform(utf8.decoder)) {
    pending += chunk;

    while (true) {
      final newline = pending.indexOf('\n');
      if (newline < 0) break;

      var line = pending.substring(0, newline);
      pending = pending.substring(newline + 1);

      // 处理 \r\n
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

      if (line.isEmpty || line.startsWith(':')) continue;
      if (!line.startsWith('data:')) continue;

      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      if (stopOnDone && data == '[DONE]') return;

      yield data;
    }
  }

  // 流结束时可能还剩最后一行（服务端没写尾换行）
  var tail = pending;
  if (tail.endsWith('\r')) tail = tail.substring(0, tail.length - 1);
  tail = tail.trim();
  if (tail.startsWith('data:')) {
    final data = tail.substring(5).trim();
    if (data.isNotEmpty && !(stopOnDone && data == '[DONE]')) {
      yield data;
    }
  }
}

/// 安全的 JSON 解析：非对象或解析失败返回 null，**绝不抛异常打断整条流**。
///
/// 中转站偶尔会插入非标准行（统计、心跳、私有事件），一条坏行不该让整轮对话失败。
Map<String, dynamic>? tryDecodeJsonObject(String text) {
  try {
    final v = jsonDecode(text);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}
