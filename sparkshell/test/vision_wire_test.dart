// 接线测试：证明"图真的进了请求体"，而不是只证明 vision.dart 自己会拼字符串。
//
// 分两层：
//  1. 纯逻辑：replaceLastUserContent 改的是哪一条、isImagePath 认不认扩展名
//  2. 真链路：本地起 HttpServer 当接入点，用 LlmClient.complete 发一条带图的消息，
//     断言抓到的请求体里出现 image_url + data:image/...;base64
// 第二层才有意义——第一层全对、序列化丢字段，用户还是看不到图。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/api_config.dart';
import 'package:sparkshell/chat/llm_client.dart';
import 'package:sparkshell/chat/vision.dart';

/// 1x1 的 PNG，够小、够真（magic bytes 正确）。
final List<int> kPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('replaceLastUserContent', () {
    test('只改最后一条 user，system/assistant 不动', () {
      final h = <Map<String, dynamic>>[
        {'role': 'system', 'content': '你是助手'},
        {'role': 'user', 'content': '第一句'},
        {'role': 'assistant', 'content': '第一答'},
        {'role': 'user', 'content': '这图什么意思'},
      ];
      final ok = replaceLastUserContent(h, <Map<String, dynamic>>[
        {'type': 'text', 'text': '这图什么意思'},
      ]);

      expect(ok, isTrue);
      expect(h[0]['content'], '你是助手');
      expect(h[1]['content'], '第一句');
      expect(h[2]['content'], '第一答');
      expect(h[3]['content'], isA<List>());
      expect((h[3]['content'] as List).first['text'], '这图什么意思');
    });

    test('没有 user 消息时返回 false，不瞎插一条', () {
      final h = <Map<String, dynamic>>[
        {'role': 'system', 'content': 's'},
      ];
      expect(replaceLastUserContent(h, 'x'), isFalse);
      expect(h.length, 1);
    });
  });

  group('isImagePath', () {
    test('常见图片扩展名（大小写都算）', () {
      for (final p in [
        '/root/inbox/a.jpg',
        '/root/inbox/b.JPEG',
        '/root/inbox/c.png',
        '/root/inbox/d.webp',
        '/root/inbox/e.gif',
      ]) {
        expect(isImagePath(p), isTrue, reason: p);
      }
    });

    test('文档/压缩包/无扩展名不算图片', () {
      for (final p in [
        '/root/inbox/x.pdf',
        '/root/inbox/y.zip',
        '/root/inbox/Makefile',
      ]) {
        expect(isImagePath(p), isFalse, reason: p);
      }
    });
  });

  group('请求体里真的有图', () {
    late HttpServer server;
    late Directory tmp;
    late String base;
    final bodies = <String>[];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('vision_wire');
      File('${tmp.path}/shot.png').writeAsBytesSync(kPng);
      bodies.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}/v1';
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        bodies.add(body);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '看到了'}
              }
            ]
          }));
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('带图消息 → JSON 里有 image_url 与 base64', () async {
      final content = await buildUserContent(
        '这图报什么错',
        ['${tmp.path}/shot.png'],
      );
      expect(content, isA<List>());

      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': content},
      ];
      final client = LlmClient(
        ApiConfig(baseUrl: base, apiKey: 'k', model: 'm', systemPrompt: '', temperature: 0),
        vision: true,
      );
      final msg = await client.complete(messages);
      expect(msg['content'], '看到了');
      client.dispose();

      expect(bodies, hasLength(1));
      final sent = bodies.single;
      expect(sent, contains('image_url'));
      expect(sent, contains('data:image/png;base64'));
      expect(sent, contains('这图报什么错'));
    });

    test('不带图时请求体里没有 image_url（纯文本模型不受影响）', () async {
      final client = LlmClient(
        ApiConfig(baseUrl: base, apiKey: 'k', model: 'm', systemPrompt: '', temperature: 0),
      );
      await client.complete([
        {'role': 'user', 'content': '你好'}
      ]);
      client.dispose();

      expect(bodies.single, isNot(contains('image_url')));
      expect(bodies.single, contains('你好'));
    });
  });
}
