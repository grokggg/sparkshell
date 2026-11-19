import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_config.dart';
import 'retry_policy.dart';
import '../agent/cancel_token.dart';

/// 「用户在途取消」的哨兵异常：不是故障，不重试、不弹错误条。
///
/// 用私有类型而不是 `StateError('cancelled')` 是为了让上层能一眼分辨
/// 「主动停止」和「真的报错」——上层只需 `catch (_Cancelled)` 静默收尾。
class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => 'cancelled';
}

/// 极简 OpenAI 兼容客户端：POST /chat/completions，`stream: true` 走 SSE。
///
/// 稳定性策略（针对中转站 5xx/522 这类"不是我们代码的错"的故障）：
/// 1. 同一个接入点失败先重试 1 次（间隔 0.9s），吃掉瞬时抖动；
/// 2. 还不行就自动切到备用接入点（`ApiConfig.backups`），切过去能通就留在那儿；
/// 3. 全部接入点都失败才抛错，错误文案带"是哪个接入点挂了"。
class LlmClient {
  LlmClient(this.cfg, {this.onRetry});

  final ApiConfig cfg;

  /// 重试进度回调：界面拿它显示「连接不稳定，正在重试 2/5…」。
  final void Function(String message)? onRetry;

  /// 免费中转站的 5xx / 522 / 超时基本都是链路抖动：同一个接入点重试几次就好，
  /// 不换模型、不换接入点（这是用户明确要的行为）。
  static const _policy = RetryPolicy();
  HttpClient? _http;


  /// 打开一次 POST；失败按 RetryPolicy 分类重试，重试次数用完才抛。
  ///
  /// `cancel` 一旦触发：立刻 `HttpClient.close(force: true)` 把在途 socket 掐断，
  /// 然后抛 [_Cancelled] 直接退出重试循环——绝不能走完 5 次退避。
  Future<HttpClientResponse> _open(
    String path,
    String Function() body, {
    bool sse = false,
    CancelToken? cancel,
  }) async {
    final client = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);
    final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    HttpException? last;
    var reason = 'network';

    // 等待响应 body 的阶段（chat 的 SSE 流、complete 的 join）都挂在同一个
    // HttpClient 上，所以停止时统一 close(force: true)：dart:io 会直接拆掉
    // socket，阻塞在 read 上的 Future 立即以 HttpException/SocketException 失败，
    // 比等 90 秒响应超时快得多。
    final c = cancel;
    if (c != null) unawaited(c.whenCancelled.then((_) => _abort()));

    for (var attempt = 1; attempt <= _policy.maxAttempts; attempt++) {
      // 取消优先：已经停了就一次请求都别再发
      if (c != null && c.isCancelled) {
        _abort();
        throw const _Cancelled();
      }
      try {
        final req = await client.postUrl(Uri.parse('$base$path'));
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer ${cfg.apiKey}');
        if (sse) req.headers.set('Accept', 'text/event-stream');
        req.add(utf8.encode(body()));
        final resp = await req.close().timeout(const Duration(seconds: 90));
        if (resp.statusCode == 200) return resp;

        final err = await resp.transform(utf8.decoder).join();
        final out = _policy.judge(statusCode: resp.statusCode, body: err);
        reason = out.reason;
        last = HttpException(out.tip);
        if (!out.retry) throw last; // Key 失效 / 参数错，重试没意义
      } on SocketException catch (e) {
        // 自己 close(force: true) 拆 socket 也会走到这里，不能当网络故障重试
        if (c != null && c.isCancelled) {
          _abort();
          throw const _Cancelled();
        }
        last = HttpException(_policy.judge(networkError: e.message).tip);
      } on TimeoutException {
        if (c != null && c.isCancelled) {
          _abort();
          throw const _Cancelled();
        }
        last = HttpException(_policy.judge(networkError: 'timeout').tip);
      } catch (e) {
        // 强制关连接时 dart:io 抛的是 HttpException("Connection closed…")，
        // package:http 下则是 ClientException，统一按「已取消」处理；
        // 其他异常（比如 url 写错）原样抛出，别吞。
        if (c != null && c.isCancelled) {
          _abort();
          throw const _Cancelled();
        }
        rethrow;
      }

      // 限流别死磕：免费额度窗口可能要几分钟，5 次全等下来 2 分多钟，
      // 用户以为卡死了。3 次（8s+20s）不行就交回界面，让他点重试。
      if (reason == 'rate_limit' && attempt >= 3) break;

      if (attempt < _policy.maxAttempts) {
        // 退避之前先看一眼：用户可能刚好在这一刻点了停止，
        // 不然这次 delay 完还要再发一次请求才轮到检查。
        if (c != null && c.isCancelled) {
          _abort();
          throw const _Cancelled();
        }
        final wait = _policy.delayFor(attempt, reason);
        onRetry?.call(
            progressText(attempt + 1, _policy.maxAttempts, reason: reason, delayMs: wait));
        await _sleep(wait, c);
        if (c != null && c.isCancelled) {
          _abort();
          throw const _Cancelled();
        }
      }
    }
    throw last ?? const HttpException('请求失败');
  }

  /// 等重试退避，但 `whenCancelled` 一完成就立刻醒来（用户点停止不用等完这 8/20 秒）。
  Future<void> _sleep(int ms, CancelToken? cancel) {
    final wait = Future<void>.delayed(Duration(milliseconds: ms));
    if (cancel == null) return wait;
    return Future.any<void>([wait, cancel.whenCancelled]);
  }

  /// 掐断在途连接。
  ///
  /// `close(force: true)` 是 dart:io 里唯一能立刻断 socket 的办法：
  /// 优雅关闭会等响应读完（在 SSE 上等于挂到超时），强制关闭直接把 TCP 连接拆了。
  /// 同时把 `_http` 置空——关闭过的 HttpClient 不能复用，下一轮必须新建。
  void _abort() {
    final h = _http;
    _http = null;
    try {
      h?.close(force: true);
    } catch (_) {
      // 已经关过或已销毁，忽略
    }
  }

  /// `cancel` 非空时：点停止会立刻拆 socket，本流以 [_Cancelled] 结束，
  /// 并且**不会**退回到「整段返回」那条兜底路径（用户已经不想再等了）。
  Stream<String> chat(List<Map<String, String>> messages, {CancelToken? cancel}) async* {
    final sys = cfg.systemPrompt.trim();
    final body = jsonEncode({
      'model': cfg.model,
      'stream': true,
      'temperature': cfg.temperature,
      'messages': [
        if (sys.isNotEmpty) {'role': 'system', 'content': sys},
        ...messages,
      ],
    });

    var emitted = false;
    try {
      final resp = await _open('/chat/completions', () => body, sse: true, cancel: cancel);
      await for (final line
          in resp.transform(utf8.decoder).transform(const LineSplitter())) {
        if (cancel != null && cancel.isCancelled) throw const _Cancelled();
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') break;
        try {
          final m = jsonDecode(payload) as Map<String, dynamic>;
          final delta = (m['choices'] as List?)?.isNotEmpty == true
              ? (m['choices'][0] as Map)['delta'] as Map?
              : null;
          final text = delta?['content'] as String?;
          if (text != null && text.isNotEmpty) {
            emitted = true;
            yield text;
          }
        } catch (_) {
          // 单帧坏掉不中断整个流
        }
      }
      return;
    } on _Cancelled {
      // 主动停止：不重来、不兜底，安静结束
      return;
    } catch (e) {
      // 停止时 close(force: true) 会以 SocketException / HttpException 的形式
      // 冒到这里，本质仍是「已取消」，不是链路故障，别去走整段返回
      if (cancel != null && cancel.isCancelled) return;
      // 已经吐过字就不重来，避免用户看到重复段落
      if (emitted) rethrow;
    }

    // 流式走不通（免费中转常把 SSE 掐断）→ 同一接入点、同一模型，改成整段返回。
    // 用户明确要求：不换模型、不换接入点，只换传输方式。
    if (cancel != null && cancel.isCancelled) return;
    onRetry?.call('流式被中断，改用整段返回（模型仍是 ${cfg.model}）');
    final msg = await complete([
      if (sys.isNotEmpty) {'role': 'system', 'content': sys},
      ...messages.map((e) => <String, dynamic>{...e}),
    ], cancel: cancel);
    final text = (msg['content'] as String?) ?? '';
    if (text.isNotEmpty) yield text;
  }

  /// 非流式一轮，供 Agent 工具循环用（工具调用必须拿到完整 tool_calls）。
  Future<Map<String, dynamic>> complete(
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? tools,
    CancelToken? cancel,
  }) async {
    final hasTools = tools != null && tools.isNotEmpty;
    final payload = jsonEncode({
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'stream': false,
      if (hasTools) 'tools': tools,
      if (hasTools) 'tool_choice': 'auto',
    });

    final resp = await _open('/chat/completions', () => payload, cancel: cancel);
    if (cancel != null && cancel.isCancelled) throw const _Cancelled();
    // 响应体可能还在慢慢吐：这里也要接住「socket 被强制拆掉」的异常，
    // 否则界面会把一次主动停止显示成「连不上模型服务」。
    String text;
    try {
      text = await resp.transform(utf8.decoder).join();
    } catch (e) {
      if (cancel != null && cancel.isCancelled) throw const _Cancelled();
      rethrow;
    }
    final m = jsonDecode(text) as Map<String, dynamic>;
    final choices = m['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw const HttpException('响应里没有 choices');
    }
    return (choices.first as Map)['message'] as Map<String, dynamic>;
  }

  /// 非流式，用于「测试连接」按钮。
  Future<String> ping() async {
    final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse('$base/models'));
      req.headers.set('Authorization', 'Bearer ${cfg.apiKey}');
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw HttpException(
            _policy.judge(statusCode: resp.statusCode, body: text).tip);
      }
      return 'OK ${resp.statusCode}（${text.length} 字节模型列表）';
    } finally {
      client.close(force: true);
    }
  }

  void dispose() => _http?.close(force: true);
}
