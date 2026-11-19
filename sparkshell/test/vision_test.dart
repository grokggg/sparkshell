// 图片通道的真跑测试：真写临时文件、真起本机 HttpServer，不 mock 文件系统也不
// mock 网络。
//
// 为什么不用假的字节数组直接喂函数：这一层最容易踩的坑恰恰在真实 IO 上——
// 文件大小要先看 `length()` 再决定读不读、扩展名和真实格式经常不一致、
// rootfs 映射会把容器路径拼错。只测内存里的逻辑，这些全都测不出来。
//
// 降级那条用本机 HTTP 服务模拟「纯文本模型收到 image_url 就 400」，
// 断言的是真正的请求体（第二发里必须没有图片块），不是我们自己的中间变量。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/api_config.dart';
import 'package:sparkshell/chat/llm_client.dart';
import 'package:sparkshell/chat/vision.dart';

/// 一张真的 1x1 PNG（能被任何解码器认出来），用来验证「魔数优先于扩展名」。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

final Uint8List _tinyJpeg = Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
  ...List<int>.filled(32, 0x00),
]);

/// 每个用例一个独立临时目录，互不干扰。目录里写的是**宿主路径**，
/// 和真机上 `filesDir/rootfs/root/inbox/x.jpg` 的结构一致（只差 rootfs 前缀，
/// 而 buildImagePart 在没有 rootfs 时会把原路径当候选）。
late Directory _tmp;

Future<String> _write(String name, List<int> bytes) async {
  final f = File('${_tmp.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}

bool _bodyHasImage(String body) {
  final m = jsonDecode(body) as Map<String, dynamic>;
  final msgs = m['messages'] as List;
  for (final e in msgs) {
    final c = (e as Map)['content'];
    if (c is List && c.any((b) => b is Map && b['type'] == 'image_url')) {
      return true;
    }
  }
  return false;
}

String? _lastUserText(String body) {
  final m = jsonDecode(body) as Map<String, dynamic>;
  final msgs = m['messages'] as List;
  for (var i = msgs.length - 1; i >= 0; i--) {
    final e = msgs[i] as Map;
    if (e['role'] != 'user') continue;
    final c = e['content'];
    if (c is String) return c;
    if (c is List) {
      return c
          .whereType<Map>()
          .where((b) => b['type'] == 'text')
          .map((b) => '${b['text']}')
          .join('\n');
    }
  }
  return null;
}

Future<HttpServer> _serve(
  Future<void> Function(HttpRequest req, int index) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var n = 0;
  server.listen((req) {
    handler(req, n++).catchError((Object _) {});
  });
  return server;
}

LlmClient _client(
  HttpServer server, {
  bool vision = true,
  void Function(String)? onFallback,
}) =>
    LlmClient(
      ApiConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'sk-test',
        model: 'qiniu/conatus-free',
        systemPrompt: '',
      ),
      vision: vision,
      onVisionFallback: onFallback,
    );

void main() {
  // 刻意不初始化 TestWidgetsFlutterBinding：它会把 dart:io 的 HttpClient 换成
  // 一个「永远回 400、不发真请求」的假实现，本机 HttpServer 就测不到了。
  // 这个文件不碰 Widget，也不需要 binding。

  setUp(() async {
    _tmp = await Directory.systemTemp.createTemp('sparkshell_vision_');
  });
  tearDown(() async {
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
  });

  group('体积与格式：哪些图能发', () {
    test('PNG 读成 image_url 块，base64 解回来和原字节一致', () async {
      final path = await _write('shot.png', _tinyPng);

      final part = await buildImagePart(path);

      expect(part, isNotNull);
      expect(part!['type'], 'image_url');
      final url = ((part['image_url'] as Map)['url']) as String;
      expect(url.startsWith('data:image/png;base64,'), isTrue);
      expect(base64Decode(url.split(',').last), _tinyPng);
    });

    test('扩展名说谎时以魔数为准：.jpg 里装 PNG → image/png', () async {
      final path = await _write('actually_png.jpg', _tinyPng);

      final part = await buildImagePart(path);

      final url = ((part!['image_url'] as Map)['url']) as String;
      expect(url.startsWith('data:image/png;base64,'), isTrue);
    });

    test('超过 1.2MB 拒绝发送，并回调说明原因（不静默塞巨大 base64）', () async {
      // 头 8 字节是合法 PNG 魔数，后面补零到刚好超限
      final big = Uint8List(kMaxImageBytes + 1);
      big.setRange(0, _tinyPng.length, _tinyPng);
      final path = await _write('huge.png', big);

      String? reason;
      final part = await buildImagePart(
        path,
        onReject: (p, r) {
          expect(p, path);
          reason = r;
        },
      );

      expect(part, isNull);
      expect(reason, isNotNull);
      expect(reason!, contains('太大'));
      expect(reason!, contains('1.2 MB')); // 上限文案要能让人知道卡在哪
    });

    test('刚好等于上限仍然可以发（边界不算超）', () async {
      final exact = Uint8List(kMaxImageBytes);
      exact.setRange(0, _tinyPng.length, _tinyPng);
      final path = await _write('exact.png', exact);

      expect(await buildImagePart(path), isNotNull);
    });

    test('不是图片（改了后缀的文本）→ null + 原因', () async {
      final path = await _write('notes.jpg', utf8.encode('这不是图片，只是文本'));

      String? reason;
      final part = await buildImagePart(path, onReject: (_, r) => reason = r);

      expect(part, isNull);
      expect(reason, contains('不是图片'));
    });

    test('文件不存在 → null，不抛异常（一张图坏了不能毁掉整轮对话）', () async {
      String? reason;
      final part = await buildImagePart(
        '${_tmp.path}/nope.jpg',
        onReject: (_, r) => reason = r,
      );
      expect(part, isNull);
      expect(reason, contains('找不到'));
    });

    test('魔数识别覆盖 jpg / gif / webp', () {
      expect(sniffImageMime(_tinyJpeg), 'image/jpeg');
      expect(sniffImageMime(Uint8List.fromList(utf8.encode('GIF89a...'))), 'image/gif');
      expect(
        sniffImageMime(Uint8List.fromList([
          ...utf8.encode('RIFF'),
          0x24, 0x00, 0x00, 0x00,
          ...utf8.encode('WEBP'),
        ])),
        'image/webp',
      );
      expect(sniffImageMime(Uint8List.fromList(utf8.encode('hello'))), isNull);
    });
  });

  group('buildUserContent：有图走多模态，没图还是纯字符串', () {
    test('没有图片时返回 String，老调用方/纯文本模型完全不受影响', () async {
      final content = await buildUserContent('解释一下这段报错', const []);
      expect(content, isA<String>());
      expect(content, '解释一下这段报错');
    });

    test('两张图：文本块在前，两个图片块在后', () async {
      final a = await _write('a.png', _tinyPng);
      final b = await _write('b.jpg', _tinyJpeg);

      final content = await buildUserContent('这两张图有什么区别', [a, b]);

      expect(content, isA<List<Map<String, dynamic>>>());
      final blocks = content as List<Map<String, dynamic>>;
      expect(blocks.length, 3);
      expect(blocks.first['type'], 'text');
      expect(blocks.first['text'], '这两张图有什么区别');
      expect(blocks[1]['type'], 'image_url');
      expect(blocks[2]['type'], 'image_url');
      expect(
        ((blocks[2]['image_url'] as Map)['url'] as String).startsWith('data:image/jpeg;base64,'),
        isTrue,
      );
    });

    test('只发图不写字：补一句极短引导，不留空文本块', () async {
      final a = await _write('a.png', _tinyPng);
      final content = await buildUserContent('', [a]);
      final blocks = content as List<Map<String, dynamic>>;
      expect(blocks.first['text'], kFallbackImageText);
    });

    test('图全都没带上：正文里写明原因，不装作没事', () async {
      final content = await buildUserContent('看图', ['${_tmp.path}/missing.png']);
      expect(content, isA<String>());
      expect(content as String, contains('看图'));
      expect(content, contains('没能附带'));
    });
  });

  group('stripImageParts：降级后的消息形状', () {
    test('剥掉图片块、保留文字、补一句说明，且不改原消息', () async {
      final a = await _write('a.png', _tinyPng);
      final content = await buildUserContent('这是报错截图', [a]);
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': content},
      ];

      final out = stripImageParts(messages);

      expect(out[1]['content'], '这是报错截图\n$kVisionFallbackNote');
      expect(hasImageParts(out), isFalse);
      // 原对象不能被改：历史还要落盘，下次换多模态模型时图得还在
      expect(messages[1]['content'], isA<List>());
      expect(hasImageParts(messages), isTrue);
    });

    test('本来就没有图：原样返回，不硬加提示', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': '你好'},
      ];
      final out = stripImageParts(messages);
      expect(out[0]['content'], '你好');
    });
  });

  group('vision 降级：400 里说看不了图就自动重发文字版', () {
    test('流式：第一发 400 → 第二发没有图片块且带说明，回调被触发', () async {
      final a = await _write('a.png', _tinyPng);
      final bodies = <String>[];

      final server = await _serve((req, i) async {
        final body = await utf8.decoder.bind(req).join();
        bodies.add(body);
        if (_bodyHasImage(body)) {
          req.response.statusCode = 400;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'error': {'message': 'This model does not support image content'},
          }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '只看到文字'}
                }
              ]
            })}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final fallbacks = <String>[];
      final client = _client(server, onFallback: fallbacks.add);
      addTearDown(client.dispose);

      final content = await buildUserContent('看这张图', [a]);
      final text = await client
          .chat([
            {'role': 'user', 'content': content},
          ])
          .join();

      expect(text, '只看到文字');
      expect(bodies.length, 2, reason: '应当只重发一次');
      expect(_bodyHasImage(bodies.first), isTrue);
      expect(_bodyHasImage(bodies[1]), isFalse);
      expect(_lastUserText(bodies[1]), contains(kVisionFallbackNote));
      expect(fallbacks, hasLength(1));
      expect(fallbacks.single, contains('看不了图片'));
    });

    test('整段返回（complete）同样降级，不只照顾流式那条路', () async {
      final a = await _write('a.png', _tinyPng);
      var calls = 0;

      final server = await _serve((req, i) async {
        final body = await utf8.decoder.bind(req).join();
        calls++;
        if (_bodyHasImage(body)) {
          req.response.statusCode = 422;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'error': {'message': 'vision is not supported by this model'},
          }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '好的'}
            }
          ]
        }));
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final fallbacks = <String>[];
      final client = _client(server, onFallback: fallbacks.add);
      addTearDown(client.dispose);

      final msg = await client.complete([
        {'role': 'user', 'content': await buildUserContent('看这张图', [a])},
      ]);

      expect(msg['content'], '好的');
      expect(calls, 2);
      expect(fallbacks, hasLength(1));
    });

    test('vision 关着时 400 原样抛出：不能拿降级掩盖真正的配置错误', () async {
      final a = await _write('a.png', _tinyPng);
      var calls = 0;

      final server = await _serve((req, i) async {
        calls++;
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 400;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'error': {'message': 'image content is not allowed'},
        }));
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final client = _client(server, vision: false);
      addTearDown(client.dispose);

      await expectLater(
        client.chat([
          {'role': 'user', 'content': await buildUserContent('看图', [a])},
        ]).join(),
        throwsA(isA<LlmHttpException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
      expect(calls, 1, reason: '没开 vision 就不该偷偷重发');
    });

    test('400 但不是图片问题（模型名写错）→ 照样报错，不降级', () async {
      final a = await _write('a.png', _tinyPng);
      var calls = 0;

      final server = await _serve((req, i) async {
        calls++;
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 400;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'error': {'message': 'model not found'},
        }));
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final client = _client(server);
      addTearDown(client.dispose);

      await expectLater(
        client.chat([
          {'role': 'user', 'content': await buildUserContent('看图', [a])},
        ]).join(),
        throwsA(isA<LlmHttpException>()),
      );
      expect(calls, 1);
    });

    test('纯文本消息 + vision 开着也照常工作（不因为开关而多发一次）', () async {
      var calls = 0;
      final server = await _serve((req, i) async {
        calls++;
        await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.write('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '正常'}
                }
              ]
            })}\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final client = _client(server);
      addTearDown(client.dispose);

      final text = await client.chat([
        {'role': 'user', 'content': '你好'},
      ]).join();

      expect(text, '正常');
      expect(calls, 1);
    });
  });

  group('降级判据', () {
    test('只认 400/422，且 body 里要有图片语义词', () {
      expect(LlmClient.looksLikeVisionRejection(400, 'unsupported image url'), isTrue);
      expect(LlmClient.looksLikeVisionRejection(422, 'Vision not enabled'), isTrue);
      expect(LlmClient.looksLikeVisionRejection(400, 'model not found'), isFalse);
      expect(LlmClient.looksLikeVisionRejection(429, 'image rate limit'), isFalse);
      expect(LlmClient.looksLikeVisionRejection(500, 'image pipeline error'), isFalse);
      expect(LlmClient.looksLikeVisionRejection(null, 'image'), isFalse);
    });
  });
}
