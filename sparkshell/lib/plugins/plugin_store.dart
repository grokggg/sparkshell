// 插件仓库：`$dirPath/plugins.json` 的读写 + 工具规范拼装。纯 Dart，不碰 Flutter。
//
// 设计取舍：
// 1) 单文件存全部插件，而不是「一个插件一个 json」。插件数量是个位到几十的量级，
//    列表页要一次性全拿；单文件读一次就够，也方便用户整份备份/手改。代价是写放大，
//    但改一个 enabled 也就几 KB，手机上毫无压力。
// 2) 落盘用「临时文件 + rename」原子替换（和 SessionStore 一致）：写一半断电会留下
//    半截 JSON，而 plugins.json 是单文件 —— 坏了就是「所有插件全没了」。
// 3) 解析全程宽容：坏条目跳过、坏文件当空库。插件配置坏了不该让 App 起不来，
//    用户还能在内置仓库里一键装回来。
// 4) 执行不在这里。本模块只产出「一条命令 + 一份工具规范」，真正跑命令的是 agent
//    的 bash 工具；这样换执行通道（宿主/proot）不用动存储层。

import 'dart:convert';
import 'dart:io';

import 'plugin.dart';

/// 插件仓库。
class PluginStore {
  PluginStore(this.dirPath);

  /// 插件目录，plugins.json 就放在它下面。
  final String dirPath;

  /// 内存中的插件列表，顺序即 UI 顺序（先装的在前，重装原位覆盖）。
  final List<Plugin> _items = <Plugin>[];

  /// 单份 plugins.json 的读取上限。几十个插件不到 100KB，1MB 纯属防呆。
  static const int _maxBytes = 1024 * 1024;

  String get filePath => '$dirPath/plugins.json';

  /// 全部插件（不可变副本：调用方 sort/remove 不会污染内部状态）。
  List<Plugin> get all => List<Plugin>.unmodifiable(_items);

  /// 已启用的插件：只有这些会出现在模型的工具列表里。
  List<Plugin> get enabled =>
      List<Plugin>.unmodifiable(_items.where((Plugin p) => p.enabled));

  /// 按 id 查，没有就返回 null。
  Plugin? byId(String id) {
    for (final Plugin p in _items) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 从磁盘加载。文件不存在 = 空库（首次启动的正常状态，不抛异常）。
  ///
  /// 文件格式兼容两种：
  /// - `{"version":1,"plugins":[...]}`（本类写出的格式，留了 version 方便以后迁移）
  /// - `[...]`（用户手写/别的工具生成的裸数组）
  Future<void> load() async {
    _items.clear();
    final File f = File(filePath);
    try {
      if (!await f.exists()) return;
      if (await f.length() > _maxBytes) return; // 明显不是插件文件，当空库
      final Object? raw = jsonDecode(await f.readAsString());
      final Object? list = raw is Map ? raw['plugins'] : raw;
      if (list is! List) return;
      for (final Object? e in list) {
        final Plugin? p = Plugin.fromJson(e);
        if (p != null) _put(p); // 同 id 后面的覆盖前面的，顺手去重
      }
    } catch (_) {
      // 坏 JSON / 权限不足：容器是只读挂载时也会走到这里。空库比崩溃好。
      _items.clear();
    }
  }

  /// 安装（或覆盖同 id 的旧插件）。id 非法直接抛，属于调用方的 bug，不该静默。
  ///
  /// 同 id 覆盖而不是拒绝：用户「重装内置插件」时希望拿到最新版命令，
  /// 如果拒绝，就得先删再装，中间还有一步「插件消失」的窗口。
  Future<void> install(Plugin p) async {
    if (!Plugin.isValidId(p.id)) {
      throw ArgumentError('非法插件 id: ${p.id}（只允许小写字母/数字/下划线）');
    }
    if (p.command.trim().isEmpty) {
      throw ArgumentError('插件 ${p.id} 的命令为空');
    }
    _put(p);
    await save();
  }

  /// 删除。返回 false 表示本来就没有（UI 可以据此决定要不要提示）。
  Future<bool> remove(String id) async {
    final int i = _items.indexWhere((Plugin p) => p.id == id);
    if (i < 0) return false;
    _items.removeAt(i);
    await save();
    return true;
  }

  /// 启停。未知 id 静默忽略：UI 双击/并发刷新时不该抛。
  Future<void> setEnabled(String id, bool on) async {
    final Plugin? p = byId(id);
    if (p == null) return;
    if (p.enabled == on) return; // 状态没变就不写盘
    p.enabled = on;
    await save();
  }

  /// 落盘（原子替换）。
  Future<void> save() async {
    await Directory(dirPath).create(recursive: true);
    final File target = File(filePath);
    final File tmp = File('${target.path}.tmp');
    final String body = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'version': 1,
      'plugins': _items.map((Plugin p) => p.toJson()).toList(),
    });
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(target.path);
  }

  /// OpenAI function-calling 规范。
  ///
  /// 参数只有 `args` 一个对象：插件命令千差万别，为每个插件生成 JSON Schema
  /// 得让用户去写 schema，门槛比写 shell 高得多。统一「塞一个 JSON 对象进来」，
  /// 由插件自己的命令去解释字段，作者只需在 description 里写清楚要哪些字段。
  Map<String, dynamic> toolSpec(Plugin p) => <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': p.toolName,
          'description': p.description,
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'args': <String, dynamic>{
                'type': 'object',
                'description': '任意 JSON 参数',
              },
            },
            'required': <String>['args'],
          },
        },
      };

  /// 把模板里的 `{{args}}` 换成参数 JSON 的单引号安全形式。
  ///
  /// 替换值是 `args['raw'] ?? jsonEncode(args)`，再整个用单引号包起来、
  /// 内部单引号转义成 `'\''`。所以命令里**不要**给占位符自己加引号，
  /// 直接写 `python3 -c '...' {{args}}` 就是把 JSON 当成一个 argv 传进去。
  ///
  /// 为什么优先 raw：模型有时会直接给出「已经拼好的参数文本」（比如一段要写进
  /// 文件的原文），jsonEncode 会把它转义成 `"a\nb"`，插件读到的是转义后的字符串；
  /// raw 让调用方可以绕过 JSON 包装，按原样传。
  String buildCommand(Plugin p, Map<String, dynamic> args) {
    final String quoted = shellQuote(argsPayloadText(args));
    return p.command.replaceAll('{{args}}', quoted);
  }

  /// 装进去/覆盖，保持首次出现的位置。
  void _put(Plugin p) {
    final int i = _items.indexWhere((Plugin e) => e.id == p.id);
    if (i < 0) {
      _items.add(p);
    } else {
      _items[i] = p;
    }
  }
}
