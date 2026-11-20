import 'dart:async';
import 'dart:io';

/// 一次失败的判定结果：值不值得再试、属于哪类故障、给用户看的一句话。
///
/// 设计前提：用的是免费中转站，5xx / 522 / 超时基本都是链路抖动，
/// 正确处理是「等几秒重发」，不是提示用户换模型或换接入点。
class RetryOutcome {
  const RetryOutcome({required this.retry, required this.reason, required this.tip});

  /// 是否值得再试
  final bool retry;

  /// 'rate_limit' | 'unstable' | 'auth' | 'server' | 'network' | 'client'
  /// （'unstable' 留给上层：SSE 流到一半断掉这种没有状态码的抖动）
  final String reason;

  /// 给用户看的一句中文
  final String tip;

  @override
  String toString() => 'RetryOutcome(retry: $retry, reason: $reason, tip: $tip)';
}

/// 网络重试策略：只负责「分类 + 算等待时间」，不发请求、不碰 UI，纯 Dart。
///
/// 用法（LlmClient 里）：
/// ```dart
/// final out = policy.judge(statusCode: resp.statusCode, body: errBody);
/// if (!out.retry) throw HttpException(out.tip);
/// await Future<void>.delayed(Duration(milliseconds: policy.delayMs(attempt)));
/// ```
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 12,
    this.delays = const [1000, 1500, 1200, 1800],
    this.rateLimitDelays = const [1000, 1500, 1200, 1800, 2200, 1500, 1200, 2000],
  });

  /// 最多试几次（含第一次）
  final int maxAttempts;

  /// 每次失败后的等待毫秒数，长度应 >= maxAttempts-1
  final List<int> delays;

  /// 限流（429）的等待：**不递增**，全程 1–2.5 秒。
  ///
  /// 免费池子是按秒抢的：指数退避（8s→120s）等于把这一轮额度让给别人。
  /// 原作者的做法就是 8 次、每次一两秒；8 次之后继续用同样的节奏打，
  /// 只是不再刷界面。这里的曲线只在 1–2.2 秒之间抖，越界就从头循环。
  final List<int> rateLimitDelays;

  /// 「喘一口气」的上下限：下界 1 秒（不停手），上界 5 秒（对方给了 retry-after 也照办）。
  static const minPauseMs = 1000;
  static const maxPauseMs = 5000;

  /// dsh-go 的做法（AOT 快照里能捞到的常量名与文案）：
  /// `chatRequestRetryLimit` / `chatRequestRetryAttempt` / `retry-after` /
  /// `backoff` / `LlmRetryEvent`，配一句 `429. A breather, then retry`。
  /// 翻成人话：**固定次数 + 短喘气**，服务端给了 `Retry-After` 就照它等；
  /// 不是指数退避，不会退到几十秒。
  ///
  /// 失败原因如果是限流，优先信 `retryAfterMs`（来自响应头），
  /// 但夹在 [minPauseMs, maxPauseMs] 里：头里写 60 秒也不能真睡 60 秒，
  /// 免费池子等 60 秒这一轮就没了。
  int delayFor(int attempt, String reason, {int? retryAfterMs}) {
    if (reason == 'rate_limit' && retryAfterMs != null && retryAfterMs > 0) {
      final v = retryAfterMs + ((attempt * 137) % 200); // 小小错峰，别和同池子的人撞点
      return v < minPauseMs
          ? minPauseMs
          : (v > maxPauseMs ? maxPauseMs : v);
    }
    final base = _pick(reason == 'rate_limit' ? rateLimitDelays : delays, attempt);
    return base < minPauseMs
        ? minPauseMs
        : (base > maxPauseMs ? maxPauseMs : base);
  }

  /// 在基准值上抖 ±300ms：固定节奏容易和别人的重试撞在同一毫秒。
  int _pick(List<int> list, int attempt) {
    if (list.isEmpty) return 0;
    final i = ((attempt - 1) % list.length + list.length) % list.length;
    final base = list[i];
    final jitter = ((attempt * 7919) % 601) - 300;
    final v = base + jitter;
    return v < 500 ? 500 : v;
  }

  /// attempt 从 1 开始，返回第 attempt 次失败后要等多久；越界返回最后一个。
  int delayMs(int attempt) => _pick(delays, attempt);

  /// statusCode 为 null 表示根本没拿到 HTTP 响应（SocketException / TimeoutException / DNS）。
  RetryOutcome judge({int? statusCode, String body = '', String? networkError}) {
    // 1) 连响应都没拿到：DNS 失败、连接被拒、读写超时——重试最有效
    // networkError 只用于日志排查，不展示给用户（技术细节没意义，用户只需要知道在重试）
    if (statusCode == null) {
      return const RetryOutcome(
        retry: true,
        reason: 'network',
        tip: '连不上接入点，正在重试（多半是暂时的）',
      );
    }

    // 2) Key 的问题，重试一万次也没用
    if (statusCode == 401 || statusCode == 403) {
      return const RetryOutcome(
        retry: false,
        reason: 'auth',
        tip: 'API Key 失效或被拒（401/403），需要去设置里换 Key',
      );
    }

    // 3) 明确限流：退避等一等，别把额度打穿
    if (statusCode == 429) {
      return const RetryOutcome(
        retry: true,
        reason: 'rate_limit',
        tip: '触发限流（429），正在退避重试',
      );
    }

    // 4) 有些中转站把限流/额度用尽塞进 5xx 返回，这种以 body 为准，记成限流而不是服务故障
    if (statusCode >= 500 && statusCode <= 599 && _looksRateLimited(body)) {
      return const RetryOutcome(
        retry: true,
        reason: 'rate_limit',
        tip: '触发限流或额度受限，正在退避重试',
      );
    }

    // 5) Cloudflare 系网关超时：源站没响应，链路抖动，重发通常就过
    if (statusCode == 522 || statusCode == 523 || statusCode == 524) {
      return const RetryOutcome(
        retry: true,
        reason: 'server',
        tip: '接入点网关超时（5xx），通常是链路抖动，重试即可',
      );
    }

    // 6) 其余 5xx：接入点自身不稳，重试几次就好，不用换模型
    if (statusCode >= 500 && statusCode <= 599) {
      return const RetryOutcome(
        retry: true,
        reason: 'server',
        tip: '接入点暂时不稳定（5xx），正在重试；重试几次通常就好，不用换模型',
      );
    }

    // 7) 其它 4xx：请求本身不合法（模型名写错、参数不支持），重试无意义
    return RetryOutcome(
      retry: false,
      reason: 'client',
      tip: '请求被拒（HTTP $statusCode）：${_snippet(body)}',
    );
  }

  /// body 里是否有「限流 / 额度」语义（不区分大小写）
  static bool _looksRateLimited(String body) {
    final lower = body.toLowerCase();
    return lower.contains('rate limit') ||
        lower.contains('rate_limit') ||
        lower.contains('too many') ||
        lower.contains('quota');
  }

  /// 取 body 前 120 字符，压掉换行，方便直接塞进提示条
  static String _snippet(String body) {
    final oneLine = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty) return '（响应无内容）';
    return oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine;
  }
}

/// 重试中的进度提示，例：'连接不稳定，正在重试 2/5…'
String progressText(int attempt, int maxAttempts, {String? reason, int? delayMs}) {
  // maxAttempts < 1 表示「不设上限」：文案里就不写分母，免得出现「13/12」这种鬼话。
  final unlimited = maxAttempts < 1;
  final max = maxAttempts < 1 ? 1 : maxAttempts;
  var a = attempt < 1 ? 1 : attempt;
  if (!unlimited && a > max) a = max;
  final n = unlimited ? '第 $a 次' : '$a/$max';
  final secs = delayMs == null ? null : (delayMs / 1000).round();
  if (reason == 'rate_limit') {
    // 8 次之后界面不再跟着刷新，但后台仍在按同样节奏打；这句要让用户知道它没停。
    if (a > 8) {
      return secs == null ? '限流中，后台仍在重试（第 $a 次）…' : '限流中，后台仍在重试（第 $a 次，$secs 秒后）';
    }
    return secs == null ? '限流了，正在重试 $n…' : '限流（429）：$secs 秒后再试，$n';
  }
  return secs == null ? '连接不稳定，正在重试 $n…' : '连接不稳定：等 $secs 秒重试，$n';
}

/// 把 catch 到的异常转成 [RetryPolicy.judge] 需要的 networkError 文案。
String describeNetworkError(Object error) {
  if (error is SocketException) {
    return 'SocketException: ${error.message}';
  }
  if (error is TimeoutException) {
    return 'TimeoutException: ${error.message ?? '请求超时'}';
  }
  if (error is HttpException) {
    return 'HttpException: ${error.message}';
  }
  return error.toString();
}
