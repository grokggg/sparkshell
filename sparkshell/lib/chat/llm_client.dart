import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_config.dart';

/// 极简 OpenAI 兼容客户端：POST /chat/completions，`stream: true` 走 SSE。
///
/// 稳定性策略（针对中转站 5xx/522 这类"不是我们代码的错"的故障）：
/// 1. 同一个接入点失败先重试 1 次（间隔 0.9s），吃掉瞬时抖动；
/// 2. 还不行就自动切到备用接入点（`ApiConfig.backups`），切过去能通就留在那儿；
/// 3. 全部接入点都失败才抛错，错误文案带"是哪个接入点挂了"。
class LlmClient {
  LlmClient(this.cfg);

  final ApiConfig cfg;
  HttpClient? _http;

  static const _triesPerEndpoint = 2;

  static bool _retryable(int code) => code == 408 || code == 429 || code >= 500;

  static String _why(int code) {
    switch (code) {
      case 522:
      case 523:
      case 524:
        return '接入点网关超时（$code）：中转服务的源站没响应';
      case 502:
      case 503:
      case 504:
        return '接入点暂时不可用（$code）';
      case 429:
        return '请求太频繁或额度用尽（429）';
      case 401:
        return 'API Key 无效（401）';
      default:
        return 'HTTP $code';
    }
  }

  /// 打开一次 POST；内部完成「同点重试 + 跨点轮换」。
  Future<HttpClientResponse> _open(
    String path,
    String Function() body, {
    bool sse = false,
  }) async {
    final client = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);
    var lastErr = '请求失败';
    var rotated = 0;

    while (true) {
      final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      for (var attempt = 1; attempt <= _triesPerEndpoint; attempt++) {
        try {
          final req = await client.postUrl(Uri.parse('$base$path'));
          req.headers.set('Content-Type', 'application/json');
          req.headers.set('Authorization', 'Bearer ${cfg.apiKey}');
          if (sse) req.headers.set('Accept', 'text/event-stream');
          req.add(utf8.encode(body()));
          final resp = await req.close();
          if (resp.statusCode == 200) return resp;

          final err = await resp.transform(utf8.decoder).join();
          final short = err.length > 200 ? err.substring(0, 200) : err;
          lastErr = '${_why(resp.statusCode)}｜$short';
          if (!_retryable(resp.statusCode)) throw HttpException(lastErr);
        } on SocketException catch (e) {
          lastErr = '连不上 $base（${e.message}）';
        } on TimeoutException {
          lastErr = '连接超时：$base';
        }
        if (attempt < _triesPerEndpoint) {
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
      }
      if (rotated < cfg.backupCount && await cfg.rotate()) {
        rotated++;
        continue;
      }
      throw HttpException(lastErr);
    }
  }

  Stream<String> chat(List<Map<String, String>> messages) async* {
    final body = jsonEncode({
      'model': cfg.model,
      'stream': true,
      'temperature': cfg.temperature,
      'messages': [
        if (cfg.systemPrompt.trim().isNotEmpty)
          {'role': 'system', 'content': cfg.systemPrompt},
        ...messages,
      ],
    });

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
        if (text != null && text.isNotEmpty) yield text;
      } catch (_) {
        // 单帧坏掉不中断整个流
      }
    }
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
        throw HttpException('${_why(resp.statusCode)}｜${text.length > 160 ? text.substring(0, 160) : text}');
      }
      return 'OK ${resp.statusCode}（${text.length} 字节模型列表）';
    } finally {
      client.close(force: true);
    }
  }

  void dispose() => _http?.close(force: true);
}
