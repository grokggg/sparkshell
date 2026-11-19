import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/api_config.dart';

void main() {
  group('modelFor：只有带图且配了看图模型才切', () {
    final cfg = ApiConfig(
      baseUrl: 'https://api.qnaigc.com/v1',
      apiKey: 'k',
      model: 'qiniu/conatus-free',
      visionModel: 'qwen-vl-max',
    );

    test('纯文字仍走主模型', () => expect(cfg.modelFor(), 'qiniu/conatus-free'));
    test('带图切看图模型', () => expect(cfg.modelFor(hasImages: true), 'qwen-vl-max'));

    test('没配看图模型就都走主模型', () {
      final c = ApiConfig(baseUrl: 'u', apiKey: 'k', model: 'm');
      expect(c.modelFor(hasImages: true), 'm');
    });

    test('看图模型只有空白等于没配', () {
      final c = ApiConfig(baseUrl: 'u', apiKey: 'k', model: 'm', visionModel: '   ');
      expect(c.modelFor(hasImages: true), 'm');
    });
  });

  test('visionModel 能存能读，老配置缺字段不炸', () {
    final c = ApiConfig(baseUrl: 'u', apiKey: 'k', model: 'm', visionModel: 'vl');
    final back = ApiConfig.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
    expect(back.visionModel, 'vl');

    final old = Map<String, dynamic>.from(c.toJson())..remove('visionModel');
    expect(ApiConfig.fromJson(old).visionModel, '');
  });
}
