// 技能库的工具面：让模型自己发现"我会干什么"，而不是把所有说明书塞进 system。
//
// 设计取舍：技能正文按需读（skill_read），不是启动就全量注入。
// 一个技能 2-5 KB，装 20 个就 60 KB，每轮都塞会把便宜模型的上下文吃光。

import 'package:flutter/services.dart';

import 'skill_store.dart';

class SkillTools {
  static const MethodChannel _ch = MethodChannel('com.xinghuo.sparkshell/pty');

  static const List<Map<String, dynamic>> specs = <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'skill_list',
        'description': '列出本机已安装的技能（名字 + 一句话说明）。干活前先看一眼有没有现成方法论。',
        'parameters': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
      },
    },
    <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'skill_read',
        'description': '读取某个技能的完整正文（步骤、命令、注意事项）。按 skill_list 返回的名字取。',
        'parameters': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'name': <String, dynamic>{'type': 'string', 'description': '技能名，如 debian-toolchain'},
          },
          'required': <String>['name'],
        },
      },
    },
  ];

  /// 技能目录：<filesDir>/skills/<name>/SKILL.md。放进去就生效，不用重装。
  static Future<SkillStore> store() async {
    final String? dir = await _ch.invokeMethod<String>('filesDir');
    if (dir == null || dir.isEmpty) {
      throw StateError('拿不到应用目录，技能库不可用');
    }
    return SkillStore.open(dir);
  }

  static Future<String> run(String name, Map<String, dynamic> args) async {
    final SkillStore s = await store();
    if (name == 'skill_list') {
      if (s.all.isEmpty) {
        return '技能库是空的。目录：${s.dir}\n'
            '放一个 <名字>/SKILL.md（开头写 ---\\nname: ...\\ndescription: ...\\n---）就能用。';
      }
      final String lines = s.all.map((e) => '- ${e.oneLine}').join('\n');
      return '共 ${s.all.length} 个技能（目录 ${s.dir}）：\n$lines\n\n要哪份细节就 skill_read。';
    }
    if (name == 'skill_read') {
      final String want = (args['name'] as String? ?? '').trim();
      if (want.isEmpty) return '缺少 name';
      final Skill? hit = s.byName(want);
      if (hit == null) {
        return '没有叫「$want」的技能。现有：${s.names.join('、')}';
      }
      final String tools = hit.allowedTools.isEmpty ? '不限' : hit.allowedTools.join(', ');
      return '[技能] ${hit.name}\n${hit.description}\n可用工具：$tools\n\n${hit.body}';
    }
    return '未知技能工具: $name';
  }
}
