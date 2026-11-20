// 插件系统的回归测试：存储生命周期、工具规范形状、命令拼装的转义。
//
// 重点在两处最容易出人命的地方：
// 1) plugins.json 是单文件 —— 坏一次就是「所有插件全没了」，所以坏 JSON 必须当空库。
// 2) 参数是模型给的任意文本，会直接进 shell —— 单引号/中文/$ 必须原样活着到插件里，
//    所以除了断言字符串形态，还真的丢给 sh 跑一遍看回显。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/plugins/gallery.dart';
import 'package:sparkshell/plugins/plugin.dart';
import 'package:sparkshell/plugins/plugin_store.dart';

Plugin _p(String id, {String command = 'echo {{args}}', bool enabled = true}) {
  return Plugin(
    id: id,
    name: '插件$id',
    description: '测试用插件 $id',
    command: command,
    enabled: enabled,
  );
}

void main() {
  late Directory tmp;
  late PluginStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('plugin_store_test');
    store = PluginStore(tmp.path);
    await store.load();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('安装与去重', () {
    test('安装后 all/enabled 都能看到，并已经落盘', () async {
      await store.install(_p('foo'));
      expect(store.all.length, 1);
      expect(store.enabled.length, 1);
      expect(store.byId('foo')?.name, '插件foo');
      expect(File(store.filePath).existsSync(), isTrue);
    });

    test('同 id 覆盖而不是新增，且位置不变', () async {
      await store.install(_p('a'));
      await store.install(_p('b'));
      await store.install(_p('a', command: 'echo 新版 {{args}}'));
      expect(store.all.map((Plugin p) => p.id).toList(), <String>['a', 'b']);
      expect(store.byId('a')?.command, contains('新版'));
    });

    test('非法 id 安装直接抛，且不进列表', () async {
      expect(() => store.install(_p('bad-id')), throwsArgumentError);
      expect(() => store.install(_p('Bad')), throwsArgumentError);
      expect(() => store.install(_p('中文')), throwsArgumentError);
      expect(store.all, isEmpty);
    });

    test('空命令拒绝安装（装了也没法跑）', () async {
      expect(() => store.install(_p('x', command: '   ')), throwsArgumentError);
      expect(store.all, isEmpty);
    });
  });

  group('启停与删除', () {
    test('setEnabled 只影响目标，enabled 列表随之增减', () async {
      await store.install(_p('a'));
      await store.install(_p('b'));
      await store.setEnabled('a', false);
      expect(store.byId('a')?.enabled, isFalse);
      expect(store.enabled.map((Plugin p) => p.id).toList(), <String>['b']);
      await store.setEnabled('a', true);
      expect(store.enabled.length, 2);
    });

    test('setEnabled 未知 id 静默忽略', () async {
      await store.setEnabled('nope', false);
      expect(store.all, isEmpty);
    });

    test('remove 返回 true 后不可再查，重复删返回 false', () async {
      await store.install(_p('a'));
      expect(await store.remove('a'), isTrue);
      expect(store.byId('a'), isNull);
      expect(await store.remove('a'), isFalse);
    });

    test('all 是副本，外部 remove 不会改内部状态', () async {
      await store.install(_p('a'));
      final List<Plugin> view = store.all;
      expect(() => view.removeAt(0), throwsUnsupportedError);
      expect(store.all.length, 1);
    });
  });

  group('落盘往返', () {
    test('重新 load 后 id/名字/命令/启停/内置标记都还在', () async {
      await store.install(Plugin(
        id: 'round',
        name: '往返',
        description: '带中文与换行的描述',
        command: 'printf %s {{args}}\necho done',
        enabled: false,
        builtin: true,
      ));
      final PluginStore again = PluginStore(tmp.path);
      await again.load();
      expect(again.all.length, 1);
      final Plugin p = again.all.first;
      expect(p.id, 'round');
      expect(p.name, '往返');
      expect(p.description, '带中文与换行的描述');
      expect(p.command, 'printf %s {{args}}\necho done');
      expect(p.enabled, isFalse);
      expect(p.builtin, isTrue);
    });

    test('落盘格式是 {version, plugins}，且没有残留 .tmp', () async {
      await store.install(_p('a'));
      final Object? raw = jsonDecode(File(store.filePath).readAsStringSync());
      expect(raw, isA<Map<String, dynamic>>());
      expect((raw as Map<String, dynamic>)['plugins'], isA<List<dynamic>>());
      expect(File('${store.filePath}.tmp').existsSync(), isFalse);
    });
  });

  group('坏数据不崩', () {
    test('坏 JSON 当空库，不抛异常', () async {
      File('${tmp.path}/plugins.json').writeAsStringSync('{这不是 json');
      final PluginStore s = PluginStore(tmp.path);
      await s.load();
      expect(s.all, isEmpty);
      // 坏文件之后仍然能正常写：save 会整体覆盖掉
      await s.install(_p('ok'));
      expect(PluginStore(tmp.path).all, isEmpty); // 还没 load
      final PluginStore s2 = PluginStore(tmp.path);
      await s2.load();
      expect(s2.all.length, 1);
    });

    test('坏条目被跳过，好条目保留', () async {
      File('${tmp.path}/plugins.json').writeAsStringSync(jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          <String, Object?>{'id': 'ok', 'command': 'echo {{args}}', 'name': '好的'},
          <String, Object?>{'id': 'BAD ID', 'command': 'echo'},
          <String, Object?>{'id': 'no_cmd'},
          'not a map',
          null,
          <String, Object?>{'id': 'ok2', 'command': 'echo 2', 'enabled': 'yes'},
        ],
      }));
      final PluginStore s = PluginStore(tmp.path);
      await s.load();
      expect(s.all.map((Plugin p) => p.id).toList(), <String>['ok', 'ok2']);
      // enabled 类型不对时兜底为 true，而不是崩或变成 false
      expect(s.byId('ok2')?.enabled, isTrue);
      // 缺 name 时退化成 id，保证列表里不会出现空行
      expect(s.byId('ok2')?.name, 'ok2');
    });

    test('裸数组格式也能读（用户手写 / 别的工具生成）', () async {
      File('${tmp.path}/plugins.json').writeAsStringSync(jsonEncode(<Object?>[
        <String, Object?>{'id': 'bare', 'command': 'echo {{args}}'},
      ]));
      final PluginStore s = PluginStore(tmp.path);
      await s.load();
      expect(s.all.single.id, 'bare');
    });

    test('fromJson 对非 Map / 非法 id 返回 null', () {
      expect(Plugin.fromJson(null), isNull);
      expect(Plugin.fromJson('x'), isNull);
      expect(Plugin.fromJson(<String, Object?>{'id': 'UP', 'command': 'echo'}), isNull);
      expect(Plugin.fromJson(<String, Object?>{'id': 'ok'}), isNull); // 无 command
      expect(
        Plugin.fromJson(<String, Object?>{'id': 'ok', 'command': 'echo'})?.enabled,
        isTrue,
      );
    });
  });

  group('toolSpec', () {
    test('形状符合 OpenAI function-calling', () async {
      await store.install(_p('http_get', command: 'curl {{args}}'));
      final Map<String, dynamic> spec = store.toolSpec(store.all.first);
      expect(spec['type'], 'function');
      final Map<String, dynamic> fn = spec['function'] as Map<String, dynamic>;
      expect(fn['name'], 'plugin_http_get');
      expect(fn['description'], '测试用插件 http_get');
      final Map<String, dynamic> params = fn['parameters'] as Map<String, dynamic>;
      expect(params['type'], 'object');
      expect(params['required'], <String>['args']);
      final Map<String, dynamic> args =
          (params['properties'] as Map<String, dynamic>)['args'] as Map<String, dynamic>;
      expect(args['type'], 'object');
      expect(args['description'], '任意 JSON 参数');
    });

    test('spec 能被 jsonEncode（不会有非字符串 key 之类的坑）', () {
      final Map<String, dynamic> spec = store.toolSpec(_p('x'));
      expect(() => jsonEncode(spec), returnsNormally);
      expect(jsonEncode(spec), contains('"plugin_x"'));
    });
  });

  group('buildCommand 转义', () {
    test('普通参数走 jsonEncode，整体单引号包裹', () async {
      await store.install(_p('e'));
      final String cmd = store.buildCommand(store.all.first, <String, dynamic>{'url': 'https://a.b'});
      expect(cmd, 'echo \'{"url":"https://a.b"}\'');
    });

    test('值里有单引号：转义成 \'\\\'\' 而不是截断命令', () async {
      await store.install(_p('e'));
      final String cmd =
          store.buildCommand(store.all.first, <String, dynamic>{'text': "it's ok"});
      expect(cmd, 'echo \'{"text":"it\'\\\'\'s ok"}\'');
      expect(cmd.contains("'"), isTrue);
    });

    test('中文原样保留，不被转成 \\u 转义', () async {
      await store.install(_p('e'));
      final String cmd =
          store.buildCommand(store.all.first, <String, dynamic>{'text': '你好，世界'});
      expect(cmd, contains('你好，世界'));
      expect(cmd.contains(r'\u'), isFalse);
    });

    test('args.raw 优先于 jsonEncode', () async {
      await store.install(_p('e'));
      final String cmd = store.buildCommand(
        store.all.first,
        <String, dynamic>{'raw': 'a b\nc', 'other': 1},
      );
      expect(cmd, 'echo \'a b\nc\'');
    });

    test('多个占位符全部替换，没有占位符时原样返回', () async {
      await store.install(_p('two', command: 'f {{args}} {{args}}'));
      expect(
        store.buildCommand(store.byId('two')!, <String, dynamic>{}),
        'f \'{}\' \'{}\'',
      );
      await store.install(_p('plain', command: 'uname -a'));
      expect(store.buildCommand(store.byId('plain')!, <String, dynamic>{'a': 1}), 'uname -a');
    });

    test('拼出来的命令在真 shell 里回显与原文一致（含单引号/中文/\$/反引号）', () async {
      await store.install(_p('e', command: 'printf %s {{args}}'));
      final String payload = r'''it's 中文 $HOME `id` "双引号" \反斜杠''';
      final String cmd = store.buildCommand(store.all.first, <String, dynamic>{'raw': payload});
      final ProcessResult r = await Process.run('sh', <String>['-c', cmd]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, payload);
    }, skip: Platform.isWindows ? 'Windows 没有 sh' : false);
  });

  group('内置仓库', () {
    test('至少 8 个，id 全合法且唯一，命令都带 {{args}} 或明确免参数', () {
      final List<Plugin> g = builtinGallery();
      expect(g.length, greaterThanOrEqualTo(8));
      final Set<String> seen = <String>{};
      for (final Plugin p in g) {
        expect(Plugin.isValidId(p.id), isTrue, reason: '非法 id: ${p.id}');
        expect(seen.add(p.id), isTrue, reason: '重复 id: ${p.id}');
        expect(p.name.trim(), isNotEmpty);
        expect(p.description.trim(), isNotEmpty);
        expect(p.command.trim(), isNotEmpty);
        expect(p.builtin, isTrue);
        expect(p.enabled, isTrue);
      }
    });

    test('要求的 8 个 id 都在，且工具名不超限', () {
      final Set<String> ids = builtinGallery().map((Plugin p) => p.id).toSet();
      expect(
        ids,
        containsAll(<String>[
          'http_get',
          'notes',
          'todo',
          'sysinfo',
          'weather',
          'web_search',
          'url_short',
          'translate_stub',
        ]),
      );
      for (final Plugin p in builtinGallery()) {
        expect(p.toolName.length, lessThanOrEqualTo(64));
      }
    });

    test('全部内置插件都能装进空库并拼出可执行命令', () async {
      for (final Plugin p in builtinGallery()) {
        await store.install(p);
      }
      expect(store.all.length, builtinGallery().length);
      expect(store.enabled.length, store.all.length);
      for (final Plugin p in store.all) {
        final String cmd = store.buildCommand(p, <String, dynamic>{'x': "a'b中文"});
        expect(cmd.contains('{{args}}'), isFalse, reason: '${p.id} 还有未替换的占位符');
        expect(() => jsonEncode(store.toolSpec(p)), returnsNormally);
      }
    });

    test('占位翻译插件明说没翻译，不假装成功', () {
      final Plugin t = builtinGallery().firstWhere((Plugin p) => p.id == 'translate_stub');
      expect(t.command, contains('占位'));
      expect(t.command, contains('/root/.inbox.txt'));
      expect(t.description, contains('占位'));
    });
  });
}
