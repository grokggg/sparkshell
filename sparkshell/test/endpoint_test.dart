import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/api_config.dart';
import 'package:sparkshell/chat/api_endpoint.dart';

/// 3.8.4 的回归用例：**多个 key 的模型必须都留着**。
///
/// 用户原话：「我输入了这个七牛云的模型 key，我的另一个 key 的模型就没有了，
/// 还是给我消除了。我就只能用这一个 key 的模型不行。应该把所有 key 的模型都留着。」
///
/// 3.8.3 只有一个 baseUrl/apiKey 字段：填第二个 key 就把第一个顶掉，
/// 旧 key 名下的模型虽然还在档案库里（按 baseUrl 分组），界面只按当前地址过滤，
/// 看起来就是「没了」。这组用例把硬约束钉死：
/// 1. 第二个 key 是**新增**接入点，不是覆盖；
/// 2. 切换只换指针，两边的模型互不干扰；
/// 3. 落盘重载后，所有 key 和各自的模型都在。
void main() {
  ApiConfig fresh(String dir) => ApiConfig()..filesDir = dir;

  group('接入点：多个 key 并存', () {
    test('填第二个 key 后，第一个 key 的模型还在', () {
      final dir = Directory.systemTemp.createTempSync('ep-two').path;
      addTearDown(() => Directory(dir).deleteSync(recursive: true));

      final cfg = fresh(dir);
      // 第一个 key
      cfg.baseUrl = 'https://api.qnaigc.com/v1';
      cfg.apiKey = 'key-A';
      cfg.model = 'qiniu/conatus-free';
      cfg.pinModel('qiniu/conatus-free');
      cfg.pinModel('deepseek-reasoner');

      // 第二个 key（用户实际动作：改地址 + 填新 key）
      cfg.baseUrl = 'https://api.deepseek.com/v1';
      cfg.apiKey = 'key-B';
      cfg.model = 'deepseek-chat';
      cfg.pinModel('deepseek-chat');

      expect(cfg.endpoints.length, 2, reason: '两个 key 应该是两条接入点');
      expect(cfg.modelCountOf(ApiEndpoint.normalize('https://api.qnaigc.com/v1')),
          greaterThanOrEqualTo(2));
      // 关键：第一个 key 的模型一条都没少
      final a = cfg.vault
          .forEndpoint(ApiEndpoint.normalize('https://api.qnaigc.com/v1'))
          .map((e) => e.id)
          .toList();
      expect(a.contains('qiniu/conatus-free'), isTrue);
      expect(a.contains('deepseek-reasoner'), isTrue);
    });

    test('切换接入点只换指针，两边模型各自独立', () {
      final dir = Directory.systemTemp.createTempSync('ep-switch').path;
      addTearDown(() => Directory(dir).deleteSync(recursive: true));

      final cfg = fresh(dir);
      cfg.baseUrl = 'https://a.example.com/v1';
      cfg.apiKey = 'key-A';
      cfg.model = 'a-model';
      cfg.pinModel('a-model');
      final idA = cfg.ensureEndpoint(name: '接入点A')!.id;

      cfg.baseUrl = 'https://b.example.com/v1';
      cfg.apiKey = 'key-B';
      cfg.model = 'b-model';
      cfg.pinModel('b-model');
      final idB = cfg.activeEndpointId;

      expect(cfg.useEndpoint(idA), isTrue);
      expect(cfg.baseUrl, 'https://a.example.com/v1');
      expect(cfg.apiKey, 'key-A');
      expect(cfg.model, 'a-model');
      expect(cfg.selectableModels.contains('a-model'), isTrue);
      expect(cfg.selectableModels.contains('b-model'), isFalse,
          reason: 'A 的列表里不该混进 B 的模型');

      expect(cfg.useEndpoint(idB), isTrue);
      expect(cfg.apiKey, 'key-B');
      expect(cfg.selectableModels.contains('b-model'), isTrue);
      // 切回来 A 还在
      cfg.useEndpoint(idA);
      expect(cfg.vault.entries.any((e) => e.id == 'a-model'), isTrue);
    });

    test('落盘 → 重载：两个 key、两组模型都在（用户抱怨的那一步）', () async {
      final dir = Directory.systemTemp.createTempSync('ep-save').path;
      addTearDown(() => Directory(dir).deleteSync(recursive: true));

      final cfg = fresh(dir);
      cfg.baseUrl = 'https://api.qnaigc.com/v1';
      cfg.apiKey = 'key-A';
      cfg.model = 'qiniu/conatus-free';
      cfg.pinModel('qiniu/conatus-free');
      await cfg.save(dir);

      cfg.baseUrl = 'https://api.deepseek.com/v1';
      cfg.apiKey = 'key-B';
      cfg.model = 'deepseek-chat';
      cfg.pinModel('deepseek-chat');
      await cfg.save(dir);

      final again = await ApiConfig.load(dir);
      expect(again.endpoints.length, 2);
      final keys = again.endpoints.map((e) => e.apiKey).toSet();
      expect(keys.contains('key-A'), isTrue, reason: '第一个 key 不能被抹掉');
      expect(keys.contains('key-B'), isTrue);

      final all = again.vault.entries.map((e) => e.id).toSet();
      expect(all.contains('qiniu/conatus-free'), isTrue);
      expect(all.contains('deepseek-chat'), isTrue);
    });

    test('老配置（只有 baseUrl/apiKey/models）升级后自动有一条接入点', () async {
      final dir = Directory.systemTemp.createTempSync('ep-migrate').path;
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      File('$dir/chat_config.json').writeAsStringSync(
          '{"baseUrl":"https://api.qnaigc.com/v1","apiKey":"key-old",'
          '"model":"qiniu/conatus-free","models":["qiniu/conatus-free","qwen-max"]}');

      final cfg = await ApiConfig.load(dir);
      expect(cfg.endpoints.length, 1);
      expect(cfg.endpoints.first.apiKey, 'key-old');
      expect(cfg.activeEndpointId, ApiEndpoint.normalize('https://api.qnaigc.com/v1'));
      // 升级后第一次保存 → 第二个 key 才不会顶掉它
      cfg.baseUrl = 'https://other.example.com/v1';
      cfg.apiKey = 'key-new';
      cfg.model = 'm2';
      await cfg.save(dir);
      final again = await ApiConfig.load(dir);
      expect(again.endpoints.length, 2);
    });

    test('同地址重复保存不产生重复接入点', () async {
      final dir = Directory.systemTemp.createTempSync('ep-dup').path;
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final cfg = fresh(dir);
      cfg.baseUrl = 'https://a.example.com/v1/'; // 结尾斜杠
      cfg.apiKey = 'k';
      cfg.model = 'm';
      await cfg.save(dir);
      cfg.baseUrl = 'https://a.example.com/v1'; // 规范化后同一个
      await cfg.save(dir);
      expect(cfg.endpoints.length, 1);
    });

    test('删掉一个接入点只清它自己的模型', () {
      final dir = Directory.systemTemp.createTempSync('ep-del').path;
      addTearDown(() => Directory(dir).deleteSync(recursive: true));
      final cfg = fresh(dir);
      cfg.baseUrl = 'https://a.example.com/v1';
      cfg.apiKey = 'key-A';
      cfg.pinModel('a1');
      final idA = cfg.activeEndpointId;
      cfg.baseUrl = 'https://b.example.com/v1';
      cfg.apiKey = 'key-B';
      cfg.pinModel('b1');

      cfg.removeEndpoint(idA);
      expect(cfg.endpoints.length, 1);
      expect(cfg.vault.entries.any((e) => e.id == 'a1'), isFalse);
      expect(cfg.vault.entries.any((e) => e.id == 'b1'), isTrue,
          reason: '删 A 不能连累 B');
    });

    test('接入点显示名：没起名字就用域名', () {
      final e = ApiEndpoint(id: 'x', baseUrl: 'https://api.deepseek.com/v1');
      expect(e.label, 'api.deepseek.com');
      e.name = '七牛云';
      expect(e.label, '七牛云');
    });
  });
}
