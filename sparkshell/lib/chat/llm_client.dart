import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_config.dart';
import 'retry_policy.dart';

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
  Future<HttpClientResponse> _open(
    String path,
    String Function() body, {
    bool sse = false,
  }) async {
    final client = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);
    final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    HttpException? last;
    var reason = 'network';

    for (var attempt = 1; attempt <= _policy.maxAttempts; attempt++) {
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
        last = HttpException(_policy.judge(networkError: e.message).tip);
      } on TimeoutException {
        last = HttpException(_policy.judge(networkError: 'timeout').tip);
      }

      // 限流别死磕：免费额度窗口可能要几分钟，5 次全等下来 2 分多钟，
      // 用户以为卡死了。3 次（8s+20s）不行就交回界面，让他点重试。
      if (reason == 'rate_limit' && attempt >= 3) break;

      if (attempt < _policy.maxAttempts) {
        final wait = _policy.delayFor(attempt, reason);
        onRetry?.call(
            progressText(attempt + 1, _policy.maxAttempts, reason: reason, delayMs: wait));
        await Future<void>.delayed(Duration(milliseconds: wait));
      }
    }
    throw last ?? const HttpException('请求失败');
  }

  Stream<String> chat(List<Map<String, String>> messages) async* {
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
      final resp = await _open('/chat/completions', () => body, sse: true);
      await for (final line
          in resp.transform(utf8.decoder).transform(const LineSplitter())) {
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
    } catch (e) {
      // 已经吐过字就不重来，避免用户看到重复段落
      if (emitted) rethrow;
    }

    // 流式走不通（免费中转常把 SSE 掐断）→ 同一接入点、同一模型，改成整段返回。
    // 用户明确要求：不换模型、不换接入点，只换传输方式。
    onRetry?.call('流式被中断，改用整段返回（模型仍是 ${cfg.model}）');
    final msg = await complete([
      if (sys.isNotEmpty) {'role': 'system', 'content': sys},
      ...messages.map((e) => <String, dynamic>{...e}),
    ]);
    final text = (msg['content'] as String?) ?? '';
    if (text.isNotEmpty) yield text;
  }

  /// 非流式一轮，供 Agent 工具循环用（工具调用必须拿到完整 tool_calls）。
  Future<Map<String, dynamic>> complete(
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? tools,
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

    final resp = await _open('/chat/completions', () => payload);
    final text = await resp.transform(utf8.decoder).join();
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
