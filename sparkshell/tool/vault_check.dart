// 模型档案库自检：纯 Dart，不依赖 package:test / flutter。
// 跑法（在 sparkshell/ 下）：dart run tool/vault_check.dart
// 全过退出码 0，有失败 1 —— 可以直接挂进 CI 或 build 脚本。
import 'dart:convert';
import 'dart:io';

import '../lib/chat/api_config.dart';
import '../lib/chat/model_vault.dart';

int _pass = 0;
final List<String> _fails = [];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fails.add(name);
    print('FAIL  $name${detail.isEmpty ? '' : '  → $detail'}');
  }
}

/// 档案库压成 id@baseUrl → 关键字段，用来比对序列化前后。
Map<String, String> snap(ModelVault v) => {
      for (final e in v.entries)
        '${e.id}@${e.baseUrl}': '${e.pinned}|${e.thinking}|${e.lastUsedAt}',
    };

final _tmpRoot = Directory(
    '/tmp/hermes-work/vault_check_tmp/${DateTime.now().microsecondsSinceEpoch}');

Future<void> main() async {
  userComplaint(); // 1
  eviction(); // 2
  pullDoesNotWipePinned(); // 3
  roundTrip(); // 4
  await legacyMigration(); // 5
  endpointScoping(); // 6
  chooseContainsCurrent(); // 7
  thinkingPrecedence(); // 8
  await saveLoadCycle(); // 9
  emptyAndDirtyInput(); // 10
  await upgradeThenPull(); // 11
  nameLevelOps(); // 12

  print('');
  print('—— ${_pass} PASS / ${_fails.length} FAIL');
  if (_fails.isNotEmpty) {
    print('失败用例：');
    for (final f in _fails) {
      print('  · $f');
    }
  }
  try {
    if (_tmpRoot.existsSync()) _tmpRoot.deleteSync(recursive: true);
  } catch (_) {}
  exit(_fails.isEmpty ? 0 : 1);
}

/// 1) 用户原话：「填完这个以后上一个就没了」—— 连着填两个必须都在。
void userComplaint() {
  final v = ModelVault();
  v.add('kilo-auto/free', baseUrl: 'https://api.x/v1');
  v.add('qiniu/conatus-free', baseUrl: 'https://api.x/v1');
  check(
    '1 连续 add 两个模型，两个都留在档案库',
    v.entries.length == 2 &&
        v.find('kilo-auto/free', baseUrl: 'https://api.x/v1') != null &&
        v.find('qiniu/conatus-free', baseUrl: 'https://api.x/v1') != null,
    'entries=${v.entries}',
  );

  // 同名同接入点重复 add 不该产生第二条，也不该把 pinned 冲掉
  v.pin('kilo-auto/free', baseUrl: 'https://api.x/v1');
  final added = v.add('kilo-auto/free', baseUrl: 'https://api.x/v1');
  check(
    '1b 重复 add 不产生重复项、不降级 pinned',
    !added &&
        v.entries.length == 2 &&
        v.find('kilo-auto/free', baseUrl: 'https://api.x/v1')!.pinned,
    'added=$added entries=${v.entries}',
  );
}

/// 2) 超上限：最早未固定的淘汰，pinned 一条不动。
void eviction() {
  final v = ModelVault(maxUnpinned: 2);
  v.add('m1');
  v.pin('m1');
  v.add('m2');
  v.add('m3');
  check('2a 未达上限时不淘汰', v.find('m1') != null && v.find('m2') != null);

  v.add('m4'); // 未固定 {m2,m3,m4} = 3 > 2，淘汰最久未用的 m2
  check(
    '2b 超出 maxUnpinned 淘汰最久未使用的未固定项',
    v.find('m2') == null && v.find('m3') != null && v.find('m4') != null,
    'entries=${v.entries}',
  );
  check(
    '2c 淘汰绝不碰 pinned 项',
    v.find('m1') != null && v.find('m1')!.pinned,
    'entries=${v.entries}',
  );

  // 全固定时上限不起作用
  final all = ModelVault(maxUnpinned: 1);
  for (var i = 0; i < 5; i++) {
    all.pin('p$i');
  }
  check('2d 全固定时不受上限影响', all.entries.length == 5,
      'entries=${all.entries.length}');
}

/// 3) 「从接入点拉取」一次灌几百个，不能冲掉用户固定的项。
void pullDoesNotWipePinned() {
  final v = ModelVault(); // 默认 200
  v.add('my/hand-typed', baseUrl: 'https://api.x/v1');
  v.pin('my/hand-typed', baseUrl: 'https://api.x/v1');
  for (var i = 0; i < 500; i++) {
    v.add('pulled/model-$i', baseUrl: 'https://api.x/v1');
  }
  final unpinned = v.entries.where((e) => !e.pinned).length;
  check(
    '3 拉取式批量 add 不冲掉已固定项',
    v.find('my/hand-typed', baseUrl: 'https://api.x/v1') != null &&
        v.find('my/hand-typed', baseUrl: 'https://api.x/v1')!.pinned,
    'entries=${v.entries.length}',
  );
  check('3b 未固定项仍受上限约束', unpinned <= 200, 'unpinned=$unpinned');

  // 走一遍真实入口：ApiConfig.rememberModel 循环（chat_page 拉取时就是这句）
  final cfg = ApiConfig()..baseUrl = 'https://api.x/v1';
  cfg.model = 'my/hand-typed';
  cfg.pinModel('my/hand-typed');
  for (var i = 0; i < 300; i++) {
    cfg.rememberModel('pulled/model-$i');
  }
  check(
    '3c rememberModel 灌 300 条后手填的模型还在且仍固定',
    cfg.vault.find('my/hand-typed', baseUrl: 'https://api.x/v1')?.pinned ==
        true,
    'entries=${cfg.vault.entries.length}',
  );
  check('3d 旧 models 字段仍可用（旧版只读兼容）',
      cfg.models.isNotEmpty && cfg.models.length <= 80, '${cfg.models.length}');
}

/// 4) 序列化往返：字段一个不丢。
void roundTrip() {
  final v = ModelVault()..maxUnpinned = 7;
  v.add('a/plain', baseUrl: 'https://api.x/v1');
  v.add('b/think', baseUrl: 'https://api.y/v1', thinking: true);
  v.add('c/off', thinking: false);
  v.pin('b/think', baseUrl: 'https://api.y/v1');
  v.markUsed('a/plain', baseUrl: 'https://api.x/v1');

  final back = ModelVault.fromJson(jsonDecode(jsonEncode(v.toJson())));
  final a = snap(v), b = snap(back);
  check(
    '4 序列化往返内容一致',
    a.length == b.length && a.keys.every((k) => a[k] == b[k]),
    'before=$a after=$b',
  );
  check('4b 上限也跟着往返', back.maxUnpinned == 7, '${back.maxUnpinned}');
  check(
    '4c thinking=false 不被当成 null 丢掉',
    back.find('c/off')?.thinking == false,
    '${back.find('c/off')?.thinking}',
  );
}

/// 5) 老用户的 chat_config.json（只有 models 数组）：不许丢，当前模型必须 pinned。
Future<void> legacyMigration() async {
  final dir = Directory('${_tmpRoot.path}/legacy')..createSync(recursive: true);
  File('${dir.path}/chat_config.json').writeAsStringSync(jsonEncode({
    'baseUrl': 'https://old.example/v1',
    'apiKey': 'sk-old',
    'model': 'keep/me',
    'visionModel': 'qwen-vl-max',
    'systemPrompt': 'hi',
    'temperature': 0.2,
    'reasoning': 'high',
    'models': ['pulled/a', 'pulled/b', 'keep/me'],
    'thinking': {'pulled/b': true},
  }));

  final cfg = await ApiConfig.load(dir.path);
  final names = cfg.vault.entries.map((e) => e.id).toSet();
  check(
    '5 旧格式 models 全部迁移进档案库',
    names.containsAll(['pulled/a', 'pulled/b', 'keep/me']) && names.length == 3,
    '$names',
  );
  check(
    '5b 旧配置里的当前模型被固定（升级后不会消失）',
    cfg.vault.find('keep/me')?.pinned == true,
    '${cfg.vault.entries}',
  );
  check(
    '5c 旧 thinking 表并进对应条目',
    cfg.vault.find('pulled/b')?.thinking == true,
    '${cfg.vault.find('pulled/b')}',
  );
  check(
    '5d 其余配置项没被迁移弄坏',
    cfg.baseUrl == 'https://old.example/v1' &&
        cfg.model == 'keep/me' &&
        cfg.visionModel == 'qwen-vl-max' &&
        cfg.reasoning == 'high' &&
        cfg.temperature == 0.2,
    '${cfg.baseUrl} ${cfg.model} ${cfg.visionModel} ${cfg.reasoning} ${cfg.temperature}',
  );
  check(
    '5e selectableModels 含当前模型，且旧的 models 字段仍非空',
    cfg.selectableModels.contains('keep/me') && cfg.models.isNotEmpty,
    '${cfg.selectableModels}',
  );
}

/// 6) 换接入点不串味：只返回本接入点 + 通用项。
void endpointScoping() {
  final v = ModelVault();
  v.add('x/a', baseUrl: 'https://api.x/v1');
  v.add('y/a', baseUrl: 'https://api.y/v1');
  v.add('any/a'); // 通用
  final got = v.forEndpoint('https://api.x/v1').map((e) => e.id).toList();
  check(
    '6 forEndpoint 只给本接入点 + 通用项',
    got.contains('x/a') && got.contains('any/a') && !got.contains('y/a'),
    '$got',
  );
  check(
    '6b 空 baseUrl 只给通用项',
    v.forEndpoint('').every((e) => e.baseUrl.isEmpty),
    '${v.forEndpoint('').map((e) => e.id)}',
  );
  final none = v.forEndpoint('https://api.z/v1').map((e) => e.id).toList();
  check('6c 没见过的接入点只看到通用项', none.length == 1 && none.first == 'any/a',
      '$none');
}

/// 7) chooseList：current 永远可选可显示。
void chooseContainsCurrent() {
  final v = ModelVault();
  v.pin('pinned/one', baseUrl: 'https://api.x/v1');
  v.add('plain/two', baseUrl: 'https://api.x/v1');
  v.markUsed('plain/two', baseUrl: 'https://api.x/v1');

  final withCur =
      v.chooseList(baseUrl: 'https://api.x/v1', current: 'plain/two');
  check('7 current 已在列表里时保持存在', withCur.contains('plain/two'), '$withCur');
  check('7b 固定项排在前面', withCur.first == 'pinned/one', '$withCur');

  final missing = v.chooseList(
      baseUrl: 'https://api.x/v1', current: 'typed/but/never/saved');
  check('7c current 不在列表里时插到最前',
      missing.first == 'typed/but/never/saved' && missing.length == 3,
      '$missing');

  final empty = ModelVault().chooseList(current: 'only/one');
  check('7d 空档案库也不吞掉当前模型', empty.length == 1 && empty.first == 'only/one',
      '$empty');
}

/// 8) 思考支持：手动标注 > 名字正则。
void thinkingPrecedence() {
  final v = ModelVault();
  check('8 名字命中正则 → 支持', v.supportsThinking('deepseek-r1'));
  check('8b 名字不命中 → 不支持', !v.supportsThinking('qiniu/conatus-free'));
  v.annotate('qiniu/conatus-free', true);
  check('8c 手动标 true 覆盖正则', v.supportsThinking('qiniu/conatus-free'));
  v.annotate('gpt-5-mini', false);
  check('8d 手动标 false 覆盖正则', !v.supportsThinking('gpt-5-mini'));

  final cfg = ApiConfig();
  cfg.thinkingSupport['legacy/model'] = true; // 老 UI 直接写 map，仍要生效
  check('8e ApiConfig 仍认旧的 thinkingSupport map',
      cfg.supportsThinking('legacy/model'));
}

/// 9) 真落盘：save → load，vault 段完整回来。
Future<void> saveLoadCycle() async {
  final dir = Directory('${_tmpRoot.path}/cycle')..createSync(recursive: true);
  final cfg = ApiConfig()..baseUrl = 'https://api.x/v1';
  cfg.model = 'fixed/one';
  cfg.pinModel('fixed/one');
  cfg.rememberModel('loose/two');
  cfg.vault.annotate('loose/two', true);
  await cfg.save(dir.path);

  final raw = jsonDecode(File('${dir.path}/chat_config.json').readAsStringSync())
      as Map<String, dynamic>;
  check('9 落盘文件里有 vault 段', raw['vault'] is Map, '${raw.keys}');
  check('9b 落盘文件里仍保留旧 models 数组', raw['models'] is List,
      '${raw['models']}');

  final back = await ApiConfig.load(dir.path);
  check(
    '9c 重新 load 后固定项与标注都还在',
    back.vault.find('fixed/one', baseUrl: 'https://api.x/v1')?.pinned == true &&
        back.vault.find('loose/two', baseUrl: 'https://api.x/v1')?.thinking ==
            true,
    '${back.vault.entries}',
  );
  check('9d load 后 models 旧字段与 vault 不打架',
      back.models.contains('fixed/one'), '${back.models}');
}

/// 10) 脏数据：空名字、坏 json 不该炸。
void emptyAndDirtyInput() {
  final v = ModelVault();
  check('10 空名字不建档', !v.add('   ') && v.entries.isEmpty);
  v.add('  spaced/name  ');
  check('10b 名字两端空白被裁掉', v.find('spaced/name') != null,
      '${v.entries}');

  final dirty = ModelVault.fromJson({
    'entries': [
      {'id': ''},
      {'nope': 1},
      'a-string',
      {'id': 'ok/one', 'pinned': 'yes', 'thinking': 'maybe', 'lastUsedAt': 5},
    ],
  });
  check(
    '10c 坏记录被丢掉，好的照收',
    dirty.entries.length == 1 &&
        dirty.find('ok/one') != null &&
        dirty.find('ok/one')!.pinned == false &&
        dirty.find('ok/one')!.thinking == null,
    '${dirty.entries}',
  );
  check('10d fromJson(null) 得到空库', ModelVault.fromJson(null).entries.isEmpty);
}

/// 11) 全链路：老配置升级 → 从接入点拉 400 条 → 落盘 → 重载，手填的模型还在。
/// 这就是用户抱怨的完整路径，必须整条走通。
Future<void> upgradeThenPull() async {
  final dir = Directory('${_tmpRoot.path}/upgrade')..createSync(recursive: true);
  File('${dir.path}/chat_config.json').writeAsStringSync(jsonEncode({
    'baseUrl': 'https://api.x/v1',
    'apiKey': 'sk-old',
    'model': 'kilo-auto/free',
    'models': ['kilo-auto/free', 'old/one'],
  }));

  final cfg = await ApiConfig.load(dir.path);
  for (var i = 0; i < 400; i++) {
    cfg.rememberModel('pulled/m-$i'); // chat_page 拉取式写入
  }
  await cfg.save(dir.path);

  final back = await ApiConfig.load(dir.path);
  final alive = back.vault.entries.where((e) => e.id == 'kilo-auto/free');
  check(
    '11 升级 → 拉 400 条 → 落盘重载，手填模型仍在且固定',
    alive.isNotEmpty && alive.any((e) => e.pinned),
    '${alive.toList()}',
  );
  check(
    '11b 重载后它仍在选择器里，且模型名没被改',
    back.selectableModels.contains('kilo-auto/free') &&
        back.model == 'kilo-auto/free',
    '${back.selectableModels.length} 项 / model=${back.model}',
  );
  check('11c 未固定项没有无限膨胀', back.vault.entries.length <= 202,
      'entries=${back.vault.entries.length}');
}

/// 12) UI 只拿得到模型名时（markUsed / pinModel 不传 baseUrl），
/// 不能多存一条、也不能只改到看不见的那一份。
void nameLevelOps() {
  final cfg = ApiConfig()..baseUrl = 'https://api.x/v1';
  cfg.vault.add('dup/model'); // 升级迁移来的通用档
  cfg.vault.add('dup/model', baseUrl: 'https://api.x/v1'); // 后来拉到的接入点档

  cfg.vault.markUsed('dup/model'); // 界面只给名字
  check('12 只给名字 markUsed 不会多存一条', cfg.vault.entries.length == 2,
      '${cfg.vault.entries}');
  check('12b 名字级 markUsed 命中了条目',
      cfg.vault.entries.any((e) => e.lastUsedAt > 0), '${cfg.vault.entries}');

  cfg.pinModel('dup/model');
  check(
    '12c cfg.pinModel 固定同名所有副本',
    cfg.vault.entries.every((e) => e.pinned),
    '${cfg.vault.entries}',
  );
  cfg.unpinModel('dup/model');
  check('12d cfg.unpinModel 同样穿透', cfg.vault.entries.every((e) => !e.pinned),
      '${cfg.vault.entries}');

  cfg.pinModel('brand/new'); // 库里没有：按当前接入点建档并固定
  check(
    '12e 固定一个没见过的模型会建档并固定',
    cfg.vault.find('brand/new', baseUrl: 'https://api.x/v1')?.pinned == true,
    '${cfg.vault.entries}',
  );

  cfg.removeModel('dup/model');
  check('12f cfg.removeModel 清掉该名字所有副本',
      cfg.vault.entries.every((e) => e.id != 'dup/model'), '${cfg.vault.entries}');
}
