import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_config.dart';

/// 极简 OpenAI 兼容客户端：POST /chat/completions，`stream: true` 走 SSE。
class LlmClient {
  LlmClient(this.cfg);

  final ApiConfig cfg;
  HttpClient? _http;

  /// 网关抖动（5xx / 429 / 连接超时）自动重试，退避 1s、3s、7s。
  static const _maxTries = 3;
  static bool _retryable(int code) => code == 408 || code == 429 || code >= 500;

  static String _why(int code) {
    switch (code) {
      case 522:
      case 523:
      case 524:
        return '接入点网关超时（$code）：中转服务的源站没响应，不是你的手机问题';
      case 502:
      case 503:
      case 504:
        return '接入点暂时不可用（$code）';
      default:
        return 'HTTP $code';
    }
  }

  Stream<String> chat(List<Map<String, String>> messages) async* {
    final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final client = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);

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

    HttpClientResponse? resp;
    for (var attempt = 1;; attempt++) {
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer ${cfg.apiKey}');
        req.headers.set('Accept', 'text/event-stream');
        req.add(utf8.encode(body));
        resp = await req.close();
        if (resp.statusCode == 200) break;
        final err = await resp.transform(utf8.decoder).join();
        final short = err.length > 200 ? err.substring(0, 200) : err;
        if (_retryable(resp.statusCode) && attempt < _maxTries) {
          await Future<void>.delayed(Duration(milliseconds: 800 * attempt * attempt));
          continue;
        }
        throw HttpException('${_why(resp.statusCode)}｜$short');
      } on SocketException {
        if (attempt >= _maxTries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt * attempt));
      } on TimeoutException {
        if (attempt >= _maxTries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt * attempt));
      }
    }

    await for (final line in resp!
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
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
    final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 30);
    final payload = jsonEncode({
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'stream': false,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
    });
    HttpClientResponse resp;
    String text;
    for (var attempt = 1;; attempt++) {
      try {
        final req = await client.postUrl(Uri.parse('$base/chat/completions'));
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer ${cfg.apiKey}');
        req.add(utf8.encode(payload));
        resp = await req.close();
        text = await resp.transform(utf8.decoder).join();
        if (resp.statusCode == 200) break;
        final short = text.length > 200 ? text.substring(0, 200) : text;
        if (_retryable(resp.statusCode) && attempt < _maxTries) {
          await Future<void>.delayed(Duration(milliseconds: 800 * attempt * attempt));
          continue;
        }
        throw HttpException('${_why(resp.statusCode)}｜$short');
      } on SocketException {
        if (attempt >= _maxTries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt * attempt));
      } on TimeoutException {
        if (attempt >= _maxTries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt * attempt));
      }
    }
    final m = jsonDecode(text) as Map<String, dynamic>;
    final choices = m['choices'] as List?;
    if (choices == null || choices.isEmpty) throw const HttpException('响应里没有 choices');
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
        throw HttpException('HTTP ${resp.statusCode}: ${text.substring(0, text.length.clamp(0, 200))}');
      }
      return 'OK ${resp.statusCode}（${text.length} 字节模型列表）';
    } finally {
      client.close(force: true);
    }
  }

  void dispose() => _http?.close(force: true);
}
