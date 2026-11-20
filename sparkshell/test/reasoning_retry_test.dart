import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/api_config.dart';
import 'package:sparkshell/chat/retry_policy.dart';

void main() {
  group('思考深度：auto 不带参数，其余带对应字段', () {
    test('auto 一个字段都不加（3.4.0 行为不变）', () {
      expect(ApiConfig().reasoningPayload(), isEmpty);
    });

    test('不思考：thinking.disabled + reasoning_effort=none', () {
      final p = (ApiConfig()..reasoning = 'off').reasoningPayload();
      expect(p['thinking'], {'type': 'disabled'});
      expect(p['reasoning_effort'], 'none');
    });

    for (final lv in ['low', 'high', 'max']) {
      test('$lv 只带 reasoning_effort', () {
        final p = (ApiConfig()..reasoning = lv).reasoningPayload();
        expect(p, {'reasoning_effort': lv});
      });
    }

    test('未知值当 auto 处理，不往请求里塞垃圾', () {
      expect((ApiConfig()..reasoning = '慢想').reasoningPayload(), isEmpty);
    });

    test('能落盘、能读回；老配置没这个键读成 auto', () async {
      final dir = Directory.systemTemp.createTempSync('reason');
      addTearDown(() => dir.deleteSync(recursive: true));
      final c = ApiConfig(reasoning: 'high');
      await c.save(dir.path);
      expect((await ApiConfig.load(dir.path)).reasoning, 'high');

      final f = File('${dir.path}/chat_config.json');
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>..remove('reasoning');
      f.writeAsStringSync(jsonEncode(m));
      expect((await ApiConfig.load(dir.path)).reasoning, 'auto');
    });
  });

  group('限流不再半路交回用户', () {
    final p = RetryPolicy();

    test('限流额度足够跑完几分钟的窗口', () {
      expect(p.maxAttempts, greaterThanOrEqualTo(10));
    });

    test('限流退避一路到 60 秒以上，且不会越界崩', () {
      expect(p.delayFor(4, 'rate_limit'), greaterThanOrEqualTo(60000));
      expect(p.delayFor(99, 'rate_limit'), p.rateLimitDelays.last);
    });

    test('429 判成可重试的 rate_limit', () {
      expect(p.judge(statusCode: 429).retry, isTrue);
      expect(p.judge(statusCode: 429).reason, 'rate_limit');
    });

    test('401 仍然不重试（Key 错了等下去没意义）', () {
      expect(p.judge(statusCode: 401).retry, isFalse);
    });
  });
}
