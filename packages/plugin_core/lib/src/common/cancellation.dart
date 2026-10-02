/// 取消令牌。
///
/// 存在的理由：原语调用可能很长（下载、录屏、模型流式），宿主在插件停用 / 崩溃 /
/// 用户切页时需要**主动中止**它。没有取消机制，就会出现"插件已经卸载了，它的下载
/// 还在跑"这类悬挂任务。
library;

import 'dart:async';

/// 一个可被取消的操作句柄。
class CancellationToken {
  CancellationToken();

  final Completer<void> _cancelled = Completer<void>();
  String? _reason;

  /// 是否已被取消。
  bool get isCancelled => _cancelled.isCompleted;

  /// 取消原因（用于日志与审计）。
  String? get reason => _reason;

  /// 一个在取消时完成的 Future，便于 `Future.any` 组合。
  Future<void> get whenCancelled => _cancelled.future;

  /// 请求取消。重复调用无副作用。
  void cancel([String? reason]) {
    if (_cancelled.isCompleted) return;
    _reason = reason;
    _cancelled.complete();
  }

  /// 若已取消则抛出 `USER_CANCELLED`。
  ///
  /// 长任务的循环体里应定期调用它（每个 chunk / 每个循环迭代一次）。
  void throwIfCancelled() {
    if (isCancelled) {
      throw StateError('操作已被取消${_reason == null ? '' : '：$_reason'}');
    }
  }
}

/// 一个永远不会被取消的令牌。用于不需要取消能力的调用。
class NeverCancelled extends CancellationToken {
  NeverCancelled();

  @override
  bool get isCancelled => false;

  @override
  void cancel([String? reason]) {
    // 刻意忽略：这个令牌代表"不可取消"
  }
}
