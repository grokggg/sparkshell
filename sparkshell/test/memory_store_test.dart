// 长期记忆的落盘/去重/检索/截断，全是纯 Dart 逻辑，临时目录直接跑。
//
// 这里守的是「记错、记丢、截出乱码」这三类真会伤到用户的问题，
// 不是 UI；所以断言都盯着 count、顺序、rune 长度这些可验证的量。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/memory/memory_store.dart';

void main() {
  late Directory tmp;
  late MemoryStore store;

  File file() => File('${tmp.path}/memory.json');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sparkshell_memory_test');
    store = MemoryStore(tmp.path);
    await store.load();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('新增后能读出来，最近的排在最前', () async {
    final a = await store.add('用户住在杭州', tags: ['profile', '城市']);
    final b = await store.add('偏好深色主题');

    expect(store.count, 2);
    expect(store.facts.first.id, b.id);
    expect(store.facts.last.id, a.id);
    expect(store.facts.last.tags, ['profile', '城市']);
    expect(store.facts.first.text, '偏好深色主题');
  });

  test('同文本第二次 add 只更新时间，不新增', () async {
    final first = await store.add('项目用 Dart 3 写', tags: ['stack']);
    final firstAt = first.at;

    // 故意带前后空格和重复标签，验证 trim 后判等、标签去重
    final second = await store.add(
      '  项目用 Dart 3 写  ',
      tags: ['stack', 'flutter', 'stack'],
    );

    expect(store.count, 1);
    expect(second.id, first.id); // 沿用旧 id，旧引用不会失效
    expect(second.at.isAfter(firstAt), isTrue);
    expect(store.facts.single.text, '项目用 Dart 3 写');
    expect(store.facts.single.tags, ['stack', 'flutter']);
  });

  test('搜索按中文关键词命中，空白 query 返回最近的几条', () async {
    await store.add('用户喜欢喝冰美式', tags: ['偏好']);
    await store.add('用户在杭州做 Flutter 开发', tags: ['工作']);
    await store.add('每周三晚上打羽毛球');

    final byText = store.search('杭州');
    expect(byText.length, 1);
    expect(byText.single.text, contains('杭州'));

    final byTag = store.search('偏好'); // 标签也算命中面
    expect(byTag.length, 1);
    expect(byTag.single.text, contains('冰美式'));

    expect(store.search('不存在的词'), isEmpty);
    expect(store.search('   ').length, 3);
    expect(store.search('', limit: 2).length, 2);
    expect(store.search('', limit: 0), isEmpty);

    // 命中词多的排前面
    final multi = store.search('杭州 Flutter 开发');
    expect(multi.first.text, contains('杭州'));
  });

  test('digest 每条一行，标签跟在括号里', () async {
    await store.add('用户偏好深色主题', tags: ['偏好', 'UI']);
    await store.add('项目根目录 /workspace/sparkshell');

    final out = store.digest();
    final lines = out.split('\n');
    expect(lines.length, 2);
    expect(lines.first, '- 项目根目录 /workspace/sparkshell'); // 最近的在前
    expect(lines.last, '- 用户偏好深色主题（#偏好 #UI）');
  });

  test('digest 超长按 rune 截断，不切出半个汉字/半个 emoji', () async {
    for (var i = 0; i < 30; i++) {
      await store.add('第 $i 条：用户说很喜欢在杭州西湖边跑步，顺便记录一下当天的天气和心率数据');
    }

    final full = store.digest(maxChars: 100000);
    expect(full.runes.length, greaterThan(1200));

    for (final limit in [40, 61, 120, 200]) {
      final out = store.digest(maxChars: limit);
      expect(
        out.runes.length,
        lessThanOrEqualTo(limit),
        reason: 'limit=$limit',
      );
      expect(out, contains('…（还有'), reason: 'limit=$limit');
      // 出现孤立代理项就说明某个字符被劈成了两半
      expect(
        out.runes.any((r) => r >= 0xD800 && r <= 0xDFFF),
        isFalse,
        reason: 'limit=$limit',
      );
      expect(out.contains('\uFFFD'), isFalse, reason: 'limit=$limit');
    }

    // 单条就超预算：也要按 rune 截，emoji 不能只剩半个
    await store.add('📌' * 80, tags: ['钉']);
    final one = store.digest(maxChars: 41);
    expect(one.runes.length, lessThanOrEqualTo(41));
    expect(one.runes.any((r) => r >= 0xD800 && r <= 0xDFFF), isFalse);
    expect(one, contains('📌')); // 截了但没截没
  });

  test('落盘再 load 回来内容一致，文件结构是 version + facts', () async {
    await store.add('用户叫小林', tags: ['profile', '称呼']);
    await store.add('在做 SparkShell 这个项目', tags: ['项目']);
    final before = store.facts;

    final again = MemoryStore(tmp.path);
    await again.load();

    expect(again.count, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(again.facts[i].id, before[i].id);
      expect(again.facts[i].text, before[i].text);
      expect(again.facts[i].tags, before[i].tags);
      expect(
        again.facts[i].at.toIso8601String(),
        before[i].at.toIso8601String(),
      );
    }

    final raw = jsonDecode(await file().readAsString()) as Map;
    expect(raw['version'], 1);
    expect((raw['facts'] as List).length, before.length);
  });

  test('坏 JSON 不崩，当空库处理且之后还能正常写', () async {
    await file().writeAsString('{这不是 json');

    final broken = MemoryStore(tmp.path);
    await broken.load();
    expect(broken.count, 0);
    expect(broken.facts, isEmpty);
    expect(broken.digest(), isEmpty);
    expect(broken.search('任意'), isEmpty);

    await broken.add('新记忆');
    expect(broken.count, 1);

    final again = MemoryStore(tmp.path);
    await again.load();
    expect(again.count, 1);
    expect(again.facts.single.text, '新记忆');
  });

  test('目录和文件都不存在时 load 当空库，不抛', () async {
    final empty = MemoryStore('${tmp.path}/nope/deeper');
    await empty.load();
    expect(empty.count, 0);
  });

  test('remove 按 id 删除并落盘，重复删除返回 false', () async {
    final a = await store.add('临时记忆 A');
    await store.add('保留记忆 B');

    expect(await store.remove(a.id), isTrue);
    expect(store.count, 1);
    expect(await store.remove(a.id), isFalse);

    final again = MemoryStore(tmp.path);
    await again.load();
    expect(again.count, 1);
    expect(again.facts.single.text, '保留记忆 B');
  });

  test('超过 500 条时只留最新的 500 条', () async {
    final base = DateTime.utc(2026, 1, 1);
    final facts = <Map<String, dynamic>>[];
    for (var i = 0; i < 510; i++) {
      facts.add({
        'id': 'seed$i',
        'text': '第 $i 条',
        'tags': <String>['seed'],
        'at': base.add(Duration(minutes: i)).toIso8601String(),
      });
    }
    await file().writeAsString(jsonEncode({'version': 1, 'facts': facts}));

    final capped = MemoryStore(tmp.path);
    await capped.load();
    expect(capped.count, 500);
    expect(capped.facts.first.text, '第 509 条');
    expect(capped.facts.last.text, '第 10 条'); // 最旧的 10 条被丢掉

    // 再写一遍也不会把丢掉的捞回来
    await capped.save();
    final again = MemoryStore(tmp.path);
    await again.load();
    expect(again.count, 500);
  });
}
