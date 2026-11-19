import 'dart:convert';
import 'dart:io';

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

  test('visionModel 能落盘再读回来，老配置缺字段不炸', () async {
    final dir = Directory.systemTemp.createTempSync('cfg');
    addTearDown(() => dir.deleteSync(recursive: true));

    final c = ApiConfig(baseUrl: 'u', apiKey: 'k', model: 'm', visionModel: 'vl')..filesDir = dir.path;
    await c.save(dir.path);
    expect((await ApiConfig.load(dir.path)).visionModel, 'vl');

    // 老版本写下的配置文件没有这个键，读的时候必须给空串而不是抛异常
    final f = File('${dir.path}/chat_config.json');
    final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>..remove('visionModel');
    f.writeAsStringSync(jsonEncode(m));
    expect((await ApiConfig.load(dir.path)).visionModel, '');
  });
}
