// 插件（Plugin）：把「一条在容器里跑的 shell 命令」包装成模型可调用的工具。
//
// 设计取舍：
// 1) 纯数据。这里不执行任何命令，也不碰 Flutter —— 执行由 agent 的 bash 通道负责，
//    这样插件模块可以在桌面 `dart run` 里直接测，不需要真机。
// 2) id 只允许 [a-z0-9_]，因为工具名是 `plugin_<id>`：OpenAI function-calling 的
//    name 只接受字母数字下划线，且长度有上限；用户随手写「我的插件」当场就会被
//    模型 API 拒掉，不如在落盘这一层就拦住。
// 3) 命令模板统一用 {{args}} 占位（JSON 参数对象），替换逻辑在 PluginStore.buildCommand，
//    模板里不要再自己加引号 —— 见那里的说明。

import 'dart:convert';

/// 一个插件 = 名字 + 一句话说明 + 一段 shell 模板。
class Plugin {
  Plugin({
    required this.id,
    required this.name,
    required this.description,
    required this.command,
    this.enabled = true,
    this.builtin = false,
  });

  /// 稳定标识，只允许 `[a-z0-9_]`（1~32 个字符）。工具名会变成 `plugin_<id>`。
  final String id;

  /// 中文显示名，给人看的。
  final String name;

  /// 给模型看的一句话：写「什么时候该用它」，不要写实现细节。
  final String description;

  /// 在容器里执行的 shell，用 `{{args}}` 占位（会被替换成 JSON 参数的单引号安全形式）。
  final String command;

  /// 是否启用。只有启用的插件才会进入工具列表。
  bool enabled;

  /// 内置插件：来自 gallery，删掉也能重新装回来，UI 上可以做区分。
  final bool builtin;

  /// id 合法性：只允许小写字母、数字、下划线，长度 1~32。
  ///
  /// 长短都拦：空 id 会拼出工具名 `plugin_`；超长 id 会让 function name 超出
  /// 各家 API 的 64 字符限制，报错信息还很难懂。
  static final RegExp _idRe = RegExp(r'^[a-z0-9_]{1,32}$');

  static bool isValidId(String id) => _idRe.hasMatch(id);

  /// 工具名（`plugin_<id>`）。调用方拼 function name 时不要自己再拼一遍。
  String get toolName => 'plugin_$id';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'command': command,
        'enabled': enabled,
        'builtin': builtin,
      };

  /// 宽容解析：任何字段类型不对都当插件无效返回 null，绝不让一条脏数据把
  /// 整份 plugins.json 拖垮（plugins.json 是单文件，比会话目录更容易被手改坏）。
  ///
  /// 只有 id / command 是硬性要求：没有 id 无法去重，没有 command 装了也没用。
  /// name / description 缺失时退化出可读文案，用户手写 JSON 时少写两行也能用。
  static Plugin? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || !isValidId(id)) return null;
    final Object? command = raw['command'];
    if (command is! String || command.trim().isEmpty) return null;
    final Object? name = raw['name'];
    final Object? description = raw['description'];
    return Plugin(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : id,
      description: description is String ? description.trim() : '',
      command: command,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      builtin: raw['builtin'] is bool ? raw['builtin'] as bool : false,
    );
  }

  /// 列表里的一行：`名字 — 说明`。UI 直接用，别再自己拼。
  String get oneLine => description.isEmpty ? name : '$name — $description';

  /// 复制一份（改 enabled 时用，避免 UI 直接改到 store 里的对象）。
  Plugin copyWith({bool? enabled}) => Plugin(
        id: id,
        name: name,
        description: description,
        command: command,
        enabled: enabled ?? this.enabled,
        builtin: builtin,
      );

  @override
  String toString() => 'Plugin($id)';
}

/// 把任意字符串变成 shell 里「绝对安全」的单引号字面量。
///
/// 单引号里唯一不能出现的字符就是单引号本身，所以把 `'` 换成 `'\''`
/// （收尾 → 转义单引号 → 重新开引号）就闭合了。中文、emoji、`$`、反引号、
/// 换行在单引号里都是普通字符，不需要额外处理。
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 把参数对象发给插件的默认 JSON 文本：优先用 `raw`（调用方已经拼好的原文），
/// 否则整体 jsonEncode。抽出来是为了 buildCommand 里只有一处规则。
String argsPayloadText(Map<String, dynamic> args) {
  final Object? raw = args['raw'];
  if (raw is String) return raw;
  return jsonEncode(args);
}
