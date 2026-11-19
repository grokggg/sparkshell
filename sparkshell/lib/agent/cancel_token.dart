import 'dart:async';

/// 协作式取消令牌：一个 bool + 一个 Completer，谁都能读、谁都能触发。
///
/// 为什么不用 Stream / Isolate 那套：整条链路（LlmClient → AgentRunner → UI）
/// 都在同一个事件循环里，需要的只是「一个能被多处同时观察的开关」，
/// Completer 正好给到 `whenCancelled`，让等在 `Future.delayed` 重试里的代码
/// 立刻醒来，而不是傻等 20 秒退避。
class CancelToken {
  bool _cancelled = false;
  final Completer<void> _done = Completer<void>();

  /// 已经按过停止
  bool get isCancelled => _cancelled;

  /// 取消时完成（不会带错误，所以没人 await 也不会变成未捕获异常）
  Future<void> get whenCancelled => _done.future;

  /// 幂等：连点两次停止不会抛「Already completed」
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _done.complete();
  }
}
