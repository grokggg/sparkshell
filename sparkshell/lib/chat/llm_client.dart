import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_config.dart';
import 'retry_policy.dart';
import 'vision.dart';
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

/// 「测试连接」的结果。
///
/// 只描述这一次探测的结论，**不抛异常**：网络层的失败全部折成一条中文
/// [message]，界面直接显示即可，不用再包一层 catch。
class PingResult {
  const PingResult({
    required this.ok,
    required this.message,
    required this.ms,
    this.statusCode,
  });

  /// 是否真的连通（HTTP 2xx 且读完了响应）
  final bool ok;

  /// 给用户看的一句中文结论
  final String message;

  /// 这次探测耗时（毫秒），从发请求到读完响应体
  final int ms;

  /// 服务端返回的状态码；压根没连上时为 null
  final int? statusCode;

  /// 让旧代码 `'✅ $result'` 这种字符串插值继续可用。
  @override
  String toString() => message;
}

/// 带状态码和响应体的 HTTP 错误。
///
/// 为什么不用裸 `HttpException`：图片降级必须看「是不是 400/422」以及
/// 「响应体里有没有 image/vision 这类词」。把这些信息丢掉只剩一句中文提示，
/// 上层就只能靠正则抠字符串里的状态码，非常脆。
/// 实现 [HttpException] 是为了让既有 `on HttpException` 的调用方（聊天页的错误
/// 翻译）继续正常工作，不用改一圈 catch。
class LlmHttpException implements HttpException {
  LlmHttpException(this.message, {this.statusCode, this.body = ''});

  @override
  final String message;

  /// 服务端状态码；根本没拿到响应时为 null
  final int? statusCode;

  /// 原始响应体（已被上层读过一遍，这里留档给错误分类用）
  final String body;

  @override
  Uri? get uri => null;

  @override
  String toString() => message;
}

/// 极简 OpenAI 兼容客户端：POST /chat/completions，`stream: true` 走 SSE。
///
/// 稳定性策略（针对中转站 5xx/522 这类"不是我们代码的错"的故障）：
/// 1. 同一个接入点失败先重试 1 次（间隔 0.9s），吃掉瞬时抖动；
/// 2. 还不行就自动切到备用接入点（`ApiConfig.backups`），切过去能通就留在那儿；
/// 3. 全部接入点都失败才抛错，错误文案带"是哪个接入点挂了"。
class LlmClient {
  LlmClient(
    this.cfg, {
    this.onRetry,
    this.vision = false,
    this.onVisionFallback,
    this.modelOverride,
  });

  final ApiConfig cfg;

  /// 重试进度回调：界面拿它显示「连接不稳定，正在重试 2/5…」。
  final void Function(String message)? onRetry;

  /// 本轮实际使用的模型名。带图且配了看图模型时由调用方传入；
  /// null 就沿用 [ApiConfig.model]，老路径行为不变。
  final String? modelOverride;

  String get model => modelOverride ?? cfg.model;

  /// 本轮是否允许把图片按多模态格式发出去。
  ///
  /// 默认 false：绝大多数免费接入点（比如 qiniu/conatus-free）是纯文本模型，
  /// 收到 image_url 直接 400。只有调用方确认「这一轮要发图 / 用户选了多模态模型」
  /// 时才打开；关着的时候即使 content 里混了图片块，也不会做降级——因为
  /// 那本来就不该发生，静默改请求反而会把真正的配置错误掩盖掉。
  bool vision;

  /// 图片降级回调：服务端明确表示看不了图、我们已经去掉图重发时触发。
  ///
  /// 必须让上层知道，不能默默吞掉：用户以为自己发了截图，模型答得却是
  /// 「你什么都没说」——这一句提示就是让界面告诉用户「这轮只发了文字」。
  final void Function(String message)? onVisionFallback;

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
    final base = normalizeBase(cfg.baseUrl);
    HttpException? last;
    var reason = 'network';

    // 等待响应 body 的阶段（chat 的 SSE 流、complete 的 join）都挂在同一个
    // HttpClient 上，所以停止时统一 close(force: true)：dart:io 会直接拆掉
    // socket，阻塞在 read 上的 Future 立即以 HttpException/SocketException 失败，
    // 比等 90 秒响应超时快得多。
    final c = cancel;
    if (c != null) unawaited(c.whenCancelled.then((_) => _abort()));

    // 不设上限：免费额度模型的限流往往要等几分钟，逼用户点「继续」等于让他守着屏幕。
    // 退避封顶 120 秒，一直重试到成功；唯一的出口是用户点停止，或错误本身不可重试（401/403/400）。
    for (var attempt = 1; ; attempt++) {
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
        // 带上状态码和原文：图片降级要靠这两个判断「是不是模型看不懂图」，
        // 而 400 的重试判定依然走 RetryPolicy（4xx 一律不重试）。
        last = LlmHttpException(out.tip, statusCode: resp.statusCode, body: err);
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

      // 不可重试的错误（Key 错、模型名错、参数非法）在上面就已经 throw 了，
      // 能走到这里的只有限流 / 网络 / 5xx / 超时 —— 这些一律继续等，不交回用户。
      {
        // 退避之前先看一眼：用户可能刚好在这一刻点了停止，
        // 不然这次 delay 完还要再发一次请求才轮到检查。
        if (c != null && c.isCancelled) {
          _abort();
          throw const _Cancelled();
        }
        final wait = _policy.delayFor(attempt, reason);
        onRetry?.call(
            progressText(attempt + 1, 0, reason: reason, delayMs: wait));
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
  ///
  /// `messages` 的 `content` 允许是 `String`（纯文本）或 `List`（多模态
  /// content blocks），原样序列化进 JSON，不在这一层改写形状。
  Stream<String> chat(
    List<Map<String, dynamic>> messages, {
    CancelToken? cancel,
  }) async* {
    final sys = cfg.systemPrompt.trim();
    var convo = <Map<String, dynamic>>[
      if (sys.isNotEmpty) {'role': 'system', 'content': sys},
      ...messages,
    ];

    // 降级只做一次：去掉图还被 400，就不是「模型看不懂图」的问题了，
    // 再剥一遍也不会变好，只会把真正的报错拖成超时。
    var visionDegraded = false;

    while (true) {
      final body = jsonEncode({
        'model': model,
        'stream': true,
        'temperature': cfg.temperature,
        ...cfg.reasoningPayload(),
        'messages': convo,
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

        // 服务端明确说「看不了图」：把图摘掉、补一句说明，同一接入点重发一次。
        // 为什么不直接把 400 抛给用户：用户的意图是「看这张截图」，报错只会让
        // 他以为整个功能坏了；纯文本模型仍然能读路径干活，降级至少能给出回答。
        if (!visionDegraded && _tryVisionFallback(e, convo)) {
          visionDegraded = true;
          convo = stripImageParts(convo);
          continue;
        }

        // 4xx 是「这个请求本身不合法」（模型名错、参数错、Key 没权限），
        // 换成整段返回只是把同一个请求再发一遍，一定还是 4xx——多一次往返，
        // 用户多等好几秒才看到真正的错误。直接抛上去。
        final code = e is LlmHttpException ? e.statusCode : null;
        if (code != null && code >= 400 && code < 500) rethrow;

        // 已经吐过字就不重来，避免用户看到重复段落
        if (emitted) rethrow;
      }

      // 流式走不通（免费中转常把 SSE 掐断）→ 同一接入点、同一模型，改成整段返回。
      // 用户明确要求：不换模型、不换接入点，只换传输方式。
      if (cancel != null && cancel.isCancelled) return;
      onRetry?.call('流式被中断，改用整段返回（模型仍是 $model）');
      final msg = await complete(convo, cancel: cancel);
      final text = (msg['content'] as String?) ?? '';
      if (text.isNotEmpty) yield text;
      return;
    }
  }

  /// 非流式一轮，供 Agent 工具循环用（工具调用必须拿到完整 tool_calls）。
  Future<Map<String, dynamic>> complete(
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? tools,
    CancelToken? cancel,
  }) async {
    var convo = messages;
    var visionDegraded = false;

    while (true) {
      final hasTools = tools != null && tools.isNotEmpty;
      final payload = jsonEncode({
        'model': model,
        'messages': convo,
        'temperature': cfg.temperature,
        ...cfg.reasoningPayload(),
        'stream': false,
        if (hasTools) 'tools': tools,
        if (hasTools) 'tool_choice': 'auto',
      });

      final HttpClientResponse resp;
      try {
        resp = await _open('/chat/completions', () => payload, cancel: cancel);
      } on _Cancelled {
        rethrow;
      } catch (e) {
        if (cancel != null && cancel.isCancelled) throw const _Cancelled();
        // 整段返回也要能吃下「模型看不了图」：Agent 循环里上游可能带着图，
        // 不降级的话每一轮都会在同一个 400 上原地打转。
        if (!visionDegraded && _tryVisionFallback(e, convo)) {
          visionDegraded = true;
          convo = stripImageParts(convo);
          continue;
        }
        rethrow;
      }

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
  }

  /// 判断这次失败是不是「服务端看不了图」，并当场通知上层。
  ///
  /// 判据刻意保守——必须同时满足三条：
  /// 1. `vision` 开关是开的（关着说明调用方本来就不该发图，静默改请求会掩盖真错误）；
  /// 2. 状态码是 400 / 422（明确的「请求不合法」，而不是限流/链路抖动）；
  /// 3. 响应体里出现 image / vision / content 这类词。
  ///
  /// 为什么不能只看状态码：模型名写错、参数拼错同样是 400。无脑降级会把用户
  /// 真正的配置错误吃掉，变成「每次发图都莫名其妙只剩文字」。所以要看 body。
  bool _tryVisionFallback(Object error, List<Map<String, dynamic>> convo) {
    if (!vision) return false;
    if (error is! LlmHttpException) return false;
    if (!looksLikeVisionRejection(error.statusCode, error.body)) return false;
    if (!hasImageParts(convo)) return false;

    final msg = '当前模型（$model）看不了图片，已自动去掉图片、只发文字重试';
    onVisionFallback?.call(msg);
    // 顺手挂到状态条上：用户能立刻看到「这轮为什么只有文字」，
    // 而不是等模型回答完才发现图没生效。
    onRetry?.call(msg);
    return true;
  }

  /// 服务端是不是在说「我看不了这张图」。
  static bool looksLikeVisionRejection(int? status, String body) {
    if (status != 400 && status != 422) return false;
    final b = body.toLowerCase();
    const keys = ['image', 'vision', 'multimodal', 'multi-modal', 'modality', 'content'];
    return keys.any(b.contains);
  }

  /// 把用户手填的地址补成可用的 base URL：
  /// `api.qnaigc.com/v1/` → `https://api.qnaigc.com/v1`
  ///
  /// 设置页的输入框是自由文本，用户经常只填域名（漏 `https://`）或者粘贴时
  /// 带上一串尾斜杠——这两种在 Uri.parse 里都不报错，但请求会静默发错地方，
  /// 表现就是「测试连接点了没反应」。
  static String normalizeBase(String raw) {
    var b = raw.trim();
    if (b.isEmpty) return '';
    final lower = b.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      b = 'https://$b';
    }
    final stripped = b.replaceAll(RegExp(r'/+$'), '');
    // 只填了 `https://` 这种半截地址时，别把 scheme 的冒号也当成斜杠削掉
    return stripped.endsWith(':') ? b : stripped;
  }

  /// 秒数文案：整数就写 `20 秒`，否则 `0.7 秒`。
  static String _secondsText(Duration d) {
    if (d.inMilliseconds % 1000 == 0) return '${d.inSeconds} 秒';
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} 秒';
  }

  /// 状态码 → 能让用户动手改的中文原因。
  ///
  /// 必须有区分度：以前所有非 200 都套 retry 的文案，用户看到「连接不稳定，
  /// 正在重试」根本不知道该改 Key 还是改地址。
  static String _statusHint(int code) {
    switch (code) {
      case 400:
        return '请求被拒（400）：模型名或参数不对';
      case 401:
        return 'Key 不对或没权限（401）';
      case 403:
        return '这个 Key 没权限用这个接口或模型（403）';
      case 404:
        return '地址里少了 /v1（404），也可能是模型名不对';
      case 429:
        return '被限流了，稍等再试（429）';
    }
    if (code >= 500) return '接入点自己出问题了（$code），过一会儿再试';
    return '请求被拒（$code）';
  }

  /// 数一下 `/models` 返回里的模型个数（有些中转站返回 `{"data": [...]}`，
  /// 有些直接给数组）；解析不出来就返回 null，不把探测搞失败。
  static int? _countModels(String body) {
    try {
      final m = jsonDecode(body);
      if (m is Map && m['data'] is List) return (m['data'] as List).length;
      if (m is List) return m.length;
    } catch (_) {
      // 不是 JSON：只要能返回 200 就算通
    }
    return null;
  }

  /// 发一次 GET，任何异常都折成 PingResult。
  Future<PingResult> _pingOnce(
    HttpClient client,
    String base,
    Duration timeout,
    Stopwatch watch,
  ) async {
    PingResult done(bool ok, String message, {int? status}) => PingResult(
          ok: ok,
          message: message,
          ms: watch.elapsedMilliseconds,
          statusCode: status,
        );

    try {
      final req = await client.getUrl(Uri.parse('$base/models'));
      req.headers.set('Authorization', 'Bearer ${cfg.apiKey.trim()}');
      req.headers.set('Accept', 'application/json');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final code = resp.statusCode;

      if (code >= 200 && code < 300) {
        final n = _countModels(body);
        return done(
          true,
          n == null ? '连接正常（HTTP $code）' : '连接正常（HTTP $code），可用模型 $n 个',
          status: code,
        );
      }
      return done(false, _statusHint(code), status: code);
    } on TimeoutException {
      return done(false, '等了 ${_secondsText(timeout)} 还没回应（超时），连不上这个地址');
    } on SocketException {
      return done(false, '连不上这个地址：域名解析失败或连接被拒，检查地址和网络');
    } catch (e) {
      // 地址里有非法字符之类：给一句人话，别把 Dart 异常名甩给用户
      return done(false, '连不上这个地址：${e is FormatException ? '地址格式不对' : e}');
    }
  }

  /// 「测试连接」：GET `{base}/models`，只探一次，不重试（用户要的是即时结论）。
  ///
  /// 三件事和以前不同：
  /// 1. `api.qnaigc.com/v1` 这种漏 scheme、带尾斜杠的地址会被 [normalizeBase] 修正；
  /// 2. `connectionTimeout` 只管 TCP 建连——对方接了连接却不回包时它永远不触发，
  ///    这就是「点了没反应」的根因。这里对**建连 + 等响应 + 读 body** 整体加
  ///    [timeout]（默认 20 秒）硬超时；
  /// 3. 401/403/404/429/5xx 分别给可操作的中文原因，不再统一说「连接不稳定」。
  Future<PingResult> ping({Duration timeout = const Duration(seconds: 20)}) async {
    final watch = Stopwatch()..start();
    PingResult fail(String message, {int? status}) => PingResult(
          ok: false,
          message: message,
          ms: watch.elapsedMilliseconds,
          statusCode: status,
        );

    final base = normalizeBase(cfg.baseUrl);
    if (base.isEmpty) {
      return fail('还没填接口地址（例：https://api.qnaigc.com/v1）');
    }
    if (cfg.apiKey.trim().isEmpty) {
      return fail('还没填 API Key，先去设置里粘贴一个');
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _pingOnce(client, base, timeout, watch).timeout(
        timeout,
        // 硬超时命中：底层 socket 会在下面的 finally 里被强制拆掉
        onTimeout: () => fail('等了 ${_secondsText(timeout)} 还没回应（超时），连不上这个地址'),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 兼容旧调用：只要一句人话，永远不抛异常。
  ///
  /// 新的 UI 用 [ping] 拿 [PingResult]（要显示耗时/决定图标）；仍在等字符串的
  /// 老代码走这里。
  Future<String> pingMessage() async {
    final r = await ping();
    return r.ok ? '${r.message}（${r.ms}ms）' : r.message;
  }


  void dispose() => _http?.close(force: true);
}
