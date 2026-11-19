// 技能工具面的行为测试：不是"函数存在"，而是真把 filesDir 指到临时目录、
// 真写 SKILL.md、真跑 SkillTools.run()，看模型会拿到什么字符串。
//
// 这里容易骗过自己：SkillStore 有独立自检，但"工具层"另有一层壳
// （filesDir 通道、skill_list 文案、skill_read 拼装）。壳错了，模型就看不到技能。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/skills/skill_store.dart';
import 'package:sparkshell/skills/skill_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const MethodChannel pty = MethodChannel('com.xinghuo.sparkshell/pty');

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skill_tools_test');
    messenger.setMockMethodCallHandler(pty, (MethodCall call) async {
      if (call.method == 'filesDir') return tmp.path;
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pty, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> writeSkill(String dir, String name, String content) async {
    final Directory d = Directory('${tmp.path}/skills/$dir');
    await d.create(recursive: true);
    await File('${d.path}/SKILL.md').writeAsString(content);
  }

  test('空技能库：提示目录 + 怎么加，不是一句冷冰冰的"空"', () async {
    final String out = await SkillTools.run('skill_list', <String, dynamic>{});
    expect(out, contains('技能库是空的'));
    expect(out, contains('${tmp.path}/skills'));
    expect(out, contains('SKILL.md'));
  });

  test('skill_list 列出一行 name — description，不吐正文', () async {
    await writeSkill('alpha', 'alpha', '---\nname: 装环境\ndescription: Debian 装 python3\ntags: debian, apt\n---\n\n第一步……');
    final String out = await SkillTools.run('skill_list', <String, dynamic>{});
    expect(out, contains('共 1 个技能'));
    expect(out, contains('装环境'));
    expect(out, contains('Debian 装 python3'));
    expect(out, isNot(contains('第一步')), reason: '列表不该把正文倒出来，浪费上下文');
  });

  test('skill_read 给正文 + 可用工具，大小写不敏感', () async {
    await writeSkill('beta', 'beta', '---\nname: NginxOps\ndescription: 看 nginx 状态\nallowed-tools: bash, ssh_exec\n---\n\nsystemctl status nginx');
    final String out = await SkillTools.run('skill_read', <String, dynamic>{'name': 'nginxops'});
    expect(out, contains('[技能] NginxOps'));
    expect(out, contains('可用工具：bash, ssh_exec'));
    expect(out, contains('systemctl status nginx'));
  });

  test('skill_read 读不到时给出现有清单，方便模型改口重试', () async {
    await writeSkill('gamma', 'gamma', '---\nname: 备份\ndescription: 打包 rootfs\n---\n');
    final String out = await SkillTools.run('skill_read', <String, dynamic>{'name': 'nope'});
    expect(out, contains('没有叫「nope」的技能'));
    expect(out, contains('备份'));
  });

  test('skill_read 缺 name 时不抛异常', () async {
    final String out = await SkillTools.run('skill_read', <String, dynamic>{});
    expect(out, contains('缺少 name'));
  });

  test('没写 frontmatter 的技能也能被列出（dirname 兜底）', () async {
    await writeSkill('delta', 'delta', '# 把日志清干净\n\nrm -rf 之前先 du -sh。');
    final String out = await SkillTools.run('skill_list', <String, dynamic>{});
    expect(out, contains('delta'));
  });

  test('store() 在拿不到 filesDir 时报中文错，而不是空指针', () async {
    messenger.setMockMethodCallHandler(pty, (MethodCall call) async => null);
    await expectLater(
      SkillTools.store(),
      throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains('拿不到应用目录'))),
    );
    // 兜底：真拿到目录时能 open
    final SkillStore s = await SkillStore.open(tmp.path);
    expect(s.dir, contains('skills'));
  });
}
