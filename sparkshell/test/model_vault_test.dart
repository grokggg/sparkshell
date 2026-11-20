import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/api_config.dart';
import 'package:sparkshell/chat/model_vault.dart';

/// 3.8.1 的回归用例：模型填一个不能顶掉上一个。
///
/// 用户原话：「模型只能填一个，填完这个以后上一个就没了，模型也不能自主选择。」
/// 根因是旧实现把「候选」和「已保存」混在一个 List<String> 里，insert(0) 加截断，
/// 拉取一次 /v1/models 就把手填的挤出去。这里把两条硬约束钉住：
/// 1. 追加不覆盖（哪怕加几百条）；
/// 2. 固定项永不淘汰、永不被批量灌入冲掉。
void main() {
  group('ModelVault：追加不覆盖', () {
    test('连续加两个，两个都在', () {
      final v = ModelVault();
      v.add('kilo-auto/free');
      v.add('qwen-max');
      final ids = v.entries.map((e) => e.id).toList();
      expect(ids.contains('kilo-auto/free'), isTrue);
      expect(ids.contains('qwen-max'), isTrue);
      expect(ids.length, 2);
    });

    test('同 id 同接入点重复添加只更新，不产生第二条', () {
      final v = ModelVault();
      expect(v.add('m1'), isTrue);
      expect(v.add('m1'), isFalse);
      expect(v.entries.length, 1);
    });

    test('同名不同接入点各存一份，互不覆盖', () {
      final v = ModelVault();
      v.add('m1', baseUrl: 'https://a/v1');
      v.add('m1', baseUrl: 'https://b/v1');
      expect(v.entries.length, 2);
      expect(v.forEndpoint('https://a/v1').map((e) => e.baseUrl).toSet(),
          {'https://a/v1'});
    });
  });

  group('ModelVault：固定项扛得住批量灌入', () {
    test('固定后灌 400 条，固定项还在且仍是固定', () {
      final v = ModelVault(maxUnpinned: 20);
      v.add('mine');
      v.pin('mine');
      for (var i = 0; i < 400; i++) {
        v.add('bulk-$i');
      }
      final hit = v.find('mine');
      expect(hit, isNotNull);
      expect(hit!.pinned, isTrue);
    });

    test('未固定项受上限约束，最久未用的先走', () {
      final v = ModelVault(maxUnpinned: 3);
      for (var i = 0; i < 6; i++) {
        v.add('u$i');
      }
      final unpinned = v.entries.where((e) => !e.pinned).toList();
      expect(unpinned.length, lessThanOrEqualTo(3));
      expect(unpinned.any((e) => e.id == 'u0'), isFalse);
      expect(unpinned.any((e) => e.id == 'u5'), isTrue);
    });
  });

  group('ModelVault：序列化与选择器', () {
    test('toJson → fromJson 条目数与固定位不变', () {
      final v = ModelVault();
      v.add('a');
      v.add('b');
      v.pin('a');
      v.markUsed('b');
      final back = ModelVault.fromJson(jsonDecode(jsonEncode(v.toJson())));
      expect(back.entries.length, v.entries.length);
      expect(back.find('a')!.pinned, isTrue);
      expect(back.find('b')!.pinned, isFalse);
    });

    test('chooseList 里当前模型一定在，且排在最前', () {
      final v = ModelVault();
      v.add('saved', baseUrl: 'https://a/v1');
      final list = v.chooseList(baseUrl: 'https://a/v1', current: '只有我');
      expect(list.first, '只有我');
      expect(list.contains('saved'), isTrue);
    });

    test('forEndpoint 只给本接入点 + 通用档', () {
      final v = ModelVault();
      v.add('a-only', baseUrl: 'https://a/v1');
      v.add('b-only', baseUrl: 'https://b/v1');
      v.add('generic');
      final ids = v.forEndpoint('https://a/v1').map((e) => e.id).toSet();
      expect(ids, {'a-only', 'generic'});
    });
  });

  group('ApiConfig：老配置迁移不丢模型', () {
    test('旧 json 只有 models 数组，读进来当前模型被固定', () async {
      final dir = Directory.systemTemp.createTempSync('vault-mig');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/chat_config.json').writeAsStringSync(jsonEncode({
        'baseUrl': 'https://a/v1',
        'apiKey': 'k',
        'model': 'legacy-model',
        'models': ['m1', 'legacy-model', 'm2'],
      }));

      final cfg = await ApiConfig.load(dir.path);
      expect(cfg.model, 'legacy-model');
      final sel = cfg.selectableModels;
      expect(sel.contains('m1'), isTrue);
      expect(sel.contains('m2'), isTrue);
      expect(sel.contains('legacy-model'), isTrue);
      expect(cfg.vault.find('legacy-model')!.pinned, isTrue);
    });

    test('新加一个模型 → 落盘 → 重载，两个都在（这就是用户抱怨的那一步）', () async {
      final dir = Directory.systemTemp.createTempSync('vault-save');
      addTearDown(() => dir.deleteSync(recursive: true));

      final cfg = ApiConfig(baseUrl: 'https://a/v1', apiKey: 'k', model: 'old')
        ..filesDir = dir.path;
      cfg.vault.pin('old');
      cfg.pinModel('new-one');

      final again = await ApiConfig.load(dir.path);
      final sel = again.selectableModels;
      expect(sel.contains('old'), isTrue);
      expect(sel.contains('new-one'), isTrue);
      expect(again.vault.find('old')!.pinned, isTrue);
    });
  });
}
