// 路径文案回归：技能目录曾经提示成 .../files/skills/skills，
// 用户按提示放文件会放进 skills 下的第二层，SkillStore 扫不到，AI 永远说"没技能"。
//
// 这类错不会让编译失败、也不会让测试红——只有一个人真去建目录才会踩到。
// 所以直接断言提示里的路径必须等于 store.dir、且不含重复的 skills/skills。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/skills/skill_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const MethodChannel pty = MethodChannel('com.xinghuo.sparkshell/pty');

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skill_path_test');
    messenger.setMockMethodCallHandler(pty, (MethodCall call) async {
      if (call.method == 'filesDir') return tmp.path;
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pty, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('空库提示里的目录不含 skills/skills', () async {
    final String out = await SkillTools.run('skill_list', <String, dynamic>{});
    final String dir = (await SkillTools.store()).dir;

    expect(out, contains(dir));
    expect(out.contains('skills${Platform.pathSeparator}skills'), isFalse,
        reason: '路径重复会把用户带进错目录');
    expect(out.contains('skills/skills'), isFalse);
  });

  test('装了技能后，列表头里的目录同样不重复', () async {
    final Directory d = Directory('${tmp.path}/skills/demo')..createSync(recursive: true);
    File('${d.path}/SKILL.md')
        .writeAsStringSync('---\nname: demo\ndescription: 演示\n---\n\n正文');

    final String out = await SkillTools.run('skill_list', <String, dynamic>{});
    expect(out, contains('共 1 个技能'));
    expect(out.contains('skills/skills'), isFalse);
    expect(out.contains('skills${Platform.pathSeparator}skills'), isFalse);
  });
}
