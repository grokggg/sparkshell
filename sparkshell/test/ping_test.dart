// 「测试连接」的网络语义测试：全部打本机 HttpServer，不出网、不 mock。
//
// 覆盖用户真会撞上的情形：正常、Key 错、地址少 /v1、限流、服务端 5xx、
// 端口没人听（连接被拒）、对方接了连接却不回包（硬超时）。
//
// 「不回包」这条是回归守卫：旧 ping() 只设了 connectionTimeout，那管的是
// TCP 建连；对方接了连接却不发响应时它永远不触发，界面就一直停在「测试中…」，
// 用户看到的正是「点了没反应」。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/api_config.dart';
import 'package:sparkshell/chat/llm_client.dart';

/// 起一个本机 HTTP 服务；handler 自己决定怎么回。
Future<HttpServer> _serve(Future<void> Function(HttpRequest req) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    // 客户端硬超时后会拆 socket，handler 再写响应必然报错，这里吞掉即可
    handler(req).catchError((Object _) {});
  });
  return server;
}

/// 指向该服务的客户端（走 http://，方便本机回环）。
LlmClient _client(HttpServer server, {String key = 'sk-test'}) => LlmClient(
      ApiConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: key,
      ),
    );

Future<void> _reply(HttpRequest req, int code, String body) async {
  req.response.statusCode = code;
  req.response.headers.contentType = ContentType.json;
  req.response.write(body);
  await req.response.close();
}

void main() {
  group('ping：状态码语义', () {
    test('200：连通，报出可用模型数', () async {
      final server = await _serve((req) => _reply(
          req, 200, jsonEncode({
            'data': [
              {'id': 'qiniu/conatus-free'},
              {'id': 'qiniu/other'},
            ],
          })));
      addTearDown(() => server.close(force: true));

      final r = await _client(server).ping(timeout: const Duration(seconds: 5));

      expect(r.ok, isTrue, reason: r.message);
      expect(r.statusCode, 200);
      expect(r.message, contains('连接正常'));
      expect(r.message, contains('2'));
      expect(r.ms, greaterThanOrEqualTo(0));
    });

    test('401：提示 Key 不对或没权限', () async {
      final server =
          await _serve((req) => _reply(req, 401, '{"error":"invalid api key"}'));
      addTearDown(() => server.close(force: true));

      final r = await _client(server).ping(timeout: const Duration(seconds: 5));

      expect(r.ok, isFalse);
      expect(r.statusCode, 401);
      expect(r.message, contains('401'));
      expect(r.message, contains('Key'));
    });

    test('404：提示地址里少了 /v1', () async {
      final server = await _serve((req) => _reply(req, 404, '{"error":"not found"}'));
      addTearDown(() => server.close(force: true));

      final r = await _client(server).ping(timeout: const Duration(seconds: 5));

      expect(r.ok, isFalse);
      expect(r.statusCode, 404);
      expect(r.message, contains('404'));
      expect(r.message, contains('/v1'));
    });

    test('429：提示被限流，稍等再试', () async {
      final server = await _serve(
          (req) => _reply(req, 429, '{"error":"rate limit exceeded"}'));
      addTearDown(() => server.close(force: true));

      final r = await _client(server).ping(timeout: const Duration(seconds: 5));

      expect(r.ok, isFalse);
      expect(r.statusCode, 429);
      expect(r.message, contains('429'));
      expect(r.message, contains('稍等'));
    });

    test('500：提示接入点自己出问题', () async {
      final server = await _serve((req) => _reply(req, 500, 'upstream boom'));
      addTearDown(() => server.close(force: true));

      final r = await _client(server).ping(timeout: const Duration(seconds: 5));

      expect(r.ok, isFalse);
      expect(r.statusCode, 500);
      expect(r.message, contains('500'));
      expect(r.message, contains('过一会儿'));
    });
  });

  group('ping：网络层', () {
    test('连接被拒：说连不上这个地址', () async {
      // 先占一个端口再关掉，保证没人 listen
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final client = LlmClient(ApiConfig(
        baseUrl: 'http://127.0.0.1:$port/v1',
        apiKey: 'sk-test',
      ));
      final r = await client.ping(timeout: const Duration(seconds: 5));

      expect(r.ok, isFalse, reason: r.message);
      expect(r.message, contains('连不上这个地址'));
      expect(r.statusCode, isNull);
    });

    test('服务端 sleep 超过超时时间：硬超时生效，不会无限等', () async {
      // 接住请求后睡 5 秒再回——远超客户端的 600ms 超时
      final server = await _serve((req) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        await _reply(req, 200, '{"data":[]}');
      });
      addTearDown(() => server.close(force: true));

      final started = DateTime.now();
      final r = await _client(server)
          .ping(timeout: const Duration(milliseconds: 600));
      final elapsed = DateTime.now().difference(started);

      expect(r.ok, isFalse, reason: r.message);
      expect(r.message, contains('超时'));
      expect(r.statusCode, isNull);
      expect(
        elapsed,
        lessThan(const Duration(seconds: 4)),
        reason: '硬超时没生效：ping 挂了 ${elapsed.inMilliseconds}ms',
      );
    });
  });

  group('Base URL 归一化', () {
    test('漏写 https:// 自动补上', () {
      expect(
        LlmClient.normalizeBase('api.qnaigc.com/v1'),
        'https://api.qnaigc.com/v1',
      );
    });

    test('去掉首尾空白和尾部斜杠，显式 http 保留', () {
      expect(
        LlmClient.normalizeBase('  http://127.0.0.1:8080/v1//  '),
        'http://127.0.0.1:8080/v1',
      );
    });

    test('默认接入点原样通过', () {
      expect(
        LlmClient.normalizeBase('https://api.qnaigc.com/v1'),
        'https://api.qnaigc.com/v1',
      );
    });

    test('空地址返回空串', () {
      expect(LlmClient.normalizeBase('   '), '');
    });
  });

  test('pingMessage() 兼容旧调用：返回一句人话，不抛异常', () async {
    final server = await _serve(
        (req) => _reply(req, 200, jsonEncode({'data': [{'id': 'm'}]})));
    addTearDown(() => server.close(force: true));

    final msg = await _client(server).pingMessage();

    expect(msg, isA<String>());
    expect(msg, contains('连接正常'));
  });
}
