import 'dart:io';

import '../linux_env.dart';
import '../term/terminal_bus.dart';
import '../skills/skill_tools.dart';
import '../ssh/ssh_exec.dart';
import 'task_store.dart';
import '../plugins/plugin.dart';
import '../plugins/plugin_store.dart';

/// Agent 可用的四个动作。全部作用在 proot 容器里，宿主目录不暴露。
///
/// 文件读写直接走宿主路径（rootfs 前缀），比再套一层 proot 快一个数量级；
/// 只有 bash 必须进容器，否则 glibc 动态链接器对不上。
class Tools {
  /// 已装插件（由 chat_page 在启动时注入）。插件工具名统一 `plugin_<id>`，
  /// 执行时把 JSON 参数塞进插件命令的 {{args}} 占位，走同一条容器通道。
  static PluginStore? plugins;

  /// 内置工具 + 已启用的插件工具。插件停用即从列表消失，模型也就不会去调。
  static List<Map<String, dynamic>> specsWithPlugins() {
    final ps = plugins;
    if (ps == null) return specs;
    return [
      ...specs,
      for (final p in ps.enabled) ps.toolSpec(p),
    ];
  }

  static Future<String> _runPlugin(String name, Map<String, dynamic> args) async {
    final ps = plugins;
    if (ps == null) return '插件系统没初始化';
    final id = name.substring('plugin_'.length);
    Plugin? p;
    for (final e in ps.all) {
      if (e.id == id) {
        p = e;
        break;
      }
    }
    if (p == null) return '没有这个插件: $id';
    if (!p.enabled) return '插件已停用: $id';
    final raw = (args['args'] is Map) ? (args['args'] as Map).cast<String, dynamic>() : args;
    final cmd = ps.buildCommand(p, raw);
    return _bash({'command': cmd, 'timeout': 120});
  }

  static const specs = <Map<String, dynamic>>[
    {
      'type': 'function',
      'function': {
        'name': 'bash',
        'description': '在 Debian/Alpine 容器内执行 shell 命令，返回 stdout+stderr。用于 ls、cat、apt、python3 等。',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {'type': 'string', 'description': '要执行的命令'},
            'timeout': {'type': 'integer', 'description': '秒，默认 120，最大 600'},
            'background': {'type': 'boolean', 'description': 'true 表示丢到后台跑（装大包/长脚本用），立刻返回任务 id'},
          },
          'required': ['command'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'read_file',
        'description': '读取容器内文本文件，最多返回 8000 字符。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '绝对路径，如 /root/a.py'},
            'offset': {'type': 'integer', 'description': '起始行，默认 1'},
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'write_file',
        'description': '写入（覆盖）容器内文本文件，自动建父目录。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_dir',
        'description': '列目录，返回名字/类型/大小。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '绝对路径，默认 /root'},
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'edit_file',
        'description': '把文件里的 old_string 精确替换成 new_string。old_string 必须在文件中唯一，'
            '出现多次会报错要你带更多上下文；想全部替换加 replace_all=true。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'old_string': {'type': 'string', 'description': '要被替换的原文，需唯一'},
            'new_string': {'type': 'string'},
            'replace_all': {'type': 'boolean', 'description': '是否替换全部，默认 false'},
          },
          'required': ['path', 'old_string', 'new_string'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_files',
        'description': '在容器内按正则搜文本，返回 path:line: 内容，最多 60 条。用于定位代码位置。',
        'parameters': {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string', 'description': '正则表达式'},
            'path': {'type': 'string', 'description': '搜索根目录，默认 /root'},
          },
          'required': ['pattern'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'apply_patch',
        'description': '一次改多处：edits 是 [{old_string,new_string}] 数组，按顺序在同一文件里做精确替换。'
            '任意一处找不到原文就整体不写（不会半途改坏文件）。适合重构、批量改名。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'edits': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'old_string': {'type': 'string'},
                  'new_string': {'type': 'string'},
                },
                'required': ['old_string', 'new_string'],
              },
            },
          },
          'required': ['path', 'edits'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'task_log',
        'description': '读后台任务（bash background=true 启动的）的最后若干行输出，并告知是否还在跑。',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '任务 id，如 t1750000000'},
            'lines': {'type': 'integer', 'description': '默认 60'},
          },
          'required': ['id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'task_list',
        'description': '列出所有后台任务：id、是否还在跑、日志字节数、命令。',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'todo',
        'description': '维护任务清单。传数组覆盖当前清单，传空数组清空。适合多步任务先列计划再逐项推进。',
        'parameters': {
          'type': 'object',
          'properties': {
            'items': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'title': {'type': 'string'},
                  'status': {'type': 'string', 'enum': ['pending', 'in_progress', 'done']},
                },
                'required': ['title'],
              },
            },
          },
          'required': ['items'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'ssh_hosts',
        'description': '列出用户在 SSH 页保存过的主机（别名、地址、认证方式）。要用远程机器前先看一眼有哪些。',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'ssh_exec',
        'description': '在已保存的 SSH 主机上执行一条命令，返回 stdout/stderr 和退出码。'
            '适合管服务器：看服务状态、查日志、重启进程。'
            '别名来自 ssh_hosts；不传 host 就必须传 alias。',
        'parameters': {
          'type': 'object',
          'properties': {
            'alias': {'type': 'string', 'description': '已保存主机的别名，如 root@1.2.3.4:22'},
            'command': {'type': 'string', 'description': '要执行的远程命令'},
            'timeout': {'type': 'integer', 'description': '秒，默认 60，最大 300'},
          },
          'required': ['alias', 'command'],
        },
      },
    },
    ...SkillTools.specs,
  ];

  /// 非 bash 工具也在终端留一行痕迹：文件页/终端里能看到 AI 到底动了什么，
  /// 否则「它说 /root 是空的」和「它真的 ls 过」看起来一样。
  static void _trace(String name, Map<String, dynamic> a) {
    final p = a['path'] ?? a['file'] ?? '';
    switch (name) {
      case 'read_file':
        TerminalBus.instance.echoCommand('cat $p');
        break;
      case 'write_file':
        TerminalBus.instance.echoCommand('write $p');
        break;
      case 'edit_file':
        TerminalBus.instance.echoCommand('edit $p');
        break;
      case 'apply_patch':
        TerminalBus.instance.echoCommand('patch $p');
        break;
      case 'list_dir':
        TerminalBus.instance.echoCommand('ls ${p == '' ? '/' : p}');
        break;
      case 'search_files':
        TerminalBus.instance.echoCommand('grep ${a['pattern'] ?? ''} ${p == '' ? '.' : p}');
        break;
      case 'task_log':
        TerminalBus.instance.echoCommand('tail ${a['id'] ?? ''}.log');
        break;
    }
  }

  static Future<String> run(String name, Map<String, dynamic> args) async {
    try {
      if (name != 'bash') _trace(name, args);
      switch (name) {
        case 'bash':
          return _bash(args);
        case 'read_file':
          return _read(args);
        case 'write_file':
          return _write(args);
        case 'list_dir':
          return _list(args);
        case 'edit_file':
          return _edit(args);
        case 'search_files':
          return _search(args);
        case 'apply_patch':
          return _patch(args);
        case 'task_log':
          return _taskLog(args);
        case 'task_list':
          return _taskList();
        case 'todo':
          return _todo(args);
        case 'ssh_hosts':
          return await _sshHosts();
        case 'ssh_exec':
          return await _sshExec(args);
        case 'skill_list':
        case 'skill_read':
          return await SkillTools.run(name, args);
        default:
          if (name.startsWith('plugin_')) return _runPlugin(name, args);
          return '未知工具: $name';
      }
    } catch (e) {
      return '工具异常: $e';
    }
  }

  static Future<String> _bash(Map<String, dynamic> a) async {
    final cmd = (a['command'] as String? ?? '').trim();
    if (cmd.isEmpty) return '缺少 command';
    if (a['background'] == true) return _bashBackground(cmd);
    TerminalBus.instance.echoCommand(cmd);
    final secs = ((a['timeout'] as num?)?.toInt() ?? 120).clamp(5, 600);
    final r = await LinuxEnv.instance
        .execShell(cmd)
        .timeout(Duration(seconds: secs), onTimeout: () => ProcessResult(0, 124, '', '超时 ${secs}s'));
    final out = '${r.stdout}${r.stderr}'.trim();
    final body = out.length > 8000 ? '${out.substring(0, 8000)}\n…(截断)' : out;
    // 同一个入口：命令和结果都回灌到 Linux 页的终端屏幕
    TerminalBus.instance.echoResult(out);
    return '[exit ${r.exitCode}]\n${body.isEmpty ? '(无输出)' : body}';
  }

  static Future<String> _read(Map<String, dynamic> a) async {
    final f = _resolve(a['path'] as String?);
    if (f == null) return '路径非法';
    if (!await f.exists()) return '文件不存在: ${a['path']}';
    final lines = await f.readAsLines();
    final off = ((a['offset'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
    final slice = lines.skip(off - 1).take(400).join('\n');
    return slice.length > 8000 ? '${slice.substring(0, 8000)}\n…(截断)' : slice;
  }

  static Future<String> _write(Map<String, dynamic> a) async {
    final f = _resolve(a['path'] as String?);
    if (f == null) return '路径非法';
    await f.parent.create(recursive: true);
    final body = a['content'] as String? ?? '';
    var before = '';
    if (await f.exists()) {
      try {
        before = await f.readAsString();
      } catch (_) {}
    }
    await f.writeAsString(body, flush: true);
    final n = await f.length();
    final d = _diffText(before, body);
    return '已写入 ${f.path}，$n 字节${d.isEmpty ? '' : '\n$d'}';
  }

  static Future<String> _list(Map<String, dynamic> a) async {
    final f = _resolve(a['path'] as String? ?? '/root');
    if (f == null) return '路径非法';
    final dir = Directory(f.path);
    if (!await dir.exists()) return '目录不存在';
    final rows = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      final name = e.path.split('/').last;
      if (e is Directory) {
        rows.add('d  $name/');
      } else if (e is Link) {
        rows.add('l  $name -> ${await e.target()}');
      } else {
        final len = await (e as File).length();
        rows.add('f  ${len.toString().padLeft(8)}  $name');
      }
    }
    rows.sort();
    return rows.isEmpty ? '(空目录)' : rows.take(200).join('\n');
  }

  static List<Map<String, String>> _todos = [];

  static Future<String> _edit(Map<String, dynamic> a) async {
    final f = _resolve(a['path'] as String?);
    if (f == null) return '路径非法';
    if (!await f.exists()) return '文件不存在: ${a['path']}';
    final oldS = a['old_string'] as String? ?? '';
    if (oldS.isEmpty) return 'old_string 不能为空';
    final newS = a['new_string'] as String? ?? '';
    final text = await f.readAsString();
    final hits = oldS.allMatches(text).length;
    if (hits == 0) return '未找到 old_string，先 read_file 看清原文';
    final all = a['replace_all'] == true;
    if (hits > 1 && !all) {
      return 'old_string 出现 $hits 次，不唯一：补上下文，或加 replace_all=true';
    }
    final out = all ? text.replaceAll(oldS, newS) : text.replaceFirst(oldS, newS);
    await f.writeAsString(out, flush: true);
    final d = _diffText(text, out);
    return '已替换 ${all ? hits : 1} 处，文件现 ${out.length} 字符${d.isEmpty ? '' : '\n$d'}';
  }


  static TaskStore? _taskStore() {
    final root = LinuxEnv.instance.rootfsPath;
    if (root == null) return null;
    return TaskStore('$root/root/.tasks');
  }

  /// 长任务丢后台：立刻返回 id，锁屏/切后台也不会被系统砍掉。
  static Future<String> _bashBackground(String cmd) async {
    final store = _taskStore();
    if (store == null) return '容器还没准备好，先 ensureReady';
    TerminalBus.instance.echoCommand('$cmd   # 后台');
    final t = await store.start(cmd, (sh) => LinuxEnv.instance.execShell(sh));
    TerminalBus.instance.echoResult('[后台任务 ${t.id} 已启动，日志 ${t.logPath}]');
    return '已在后台启动：${t.id}\n命令：${t.command}\n'
        '日志：${t.logPath}\n稍后用 task_log(id="${t.id}") 看输出，task_list 看全部。';
  }

  static Future<String> _taskLog(Map<String, dynamic> a) async {
    final id = (a['id'] as String? ?? '').trim();
    if (id.isEmpty) return '缺少 id';
    final store = _taskStore();
    if (store == null) return '容器还没准备好';
    final lines = ((a['lines'] as num?)?.toInt() ?? 60).clamp(5, 400);
    final alive = await store.alive(id);
    final body = await store.tail(id, lines: lines);
    return '[${alive ? '运行中' : '已结束'}] $id 最后 $lines 行：\n$body';
  }

  static Future<String> _taskList() async {
    final store = _taskStore();
    if (store == null) return '容器还没准备好';
    final all = await store.list();
    if (all.isEmpty) return '还没有后台任务';
    final sb = StringBuffer();
    for (final t in all) {
      sb.writeln('${t['id']}  ${t['alive'] == 'true' ? '运行中' : '已结束'}  '
          '${t['bytes']}B  ${t['command']}');
    }
    return sb.toString();
  }

  /// 多段补丁：全部命中才写盘，避免改一半。
  static Future<String> _patch(Map<String, dynamic> a) async {
    final p = (a['path'] as String? ?? '').trim();
    final raw = a['edits'] as List? ?? const [];
    if (p.isEmpty || raw.isEmpty) return '缺少 path 或 edits';
    final f = _resolve(p);
    if (f == null) return '路径不合法：$p';
    if (!await f.exists()) return '文件不存在：$p';
    var text = await f.readAsString();
    final before = text;
    var idx = 0;
    for (final e in raw) {
      idx++;
      final oldS = (e as Map)['old_string'] as String? ?? '';
      final newS = e['new_string'] as String? ?? '';
      if (oldS.isEmpty) return '第 $idx 段 old_string 为空';
      final hits = oldS.allMatches(text).length;
      if (hits == 0) return '第 $idx 段找不到原文，整份文件未改动：${oldS.length > 60 ? '${oldS.substring(0, 60)}…' : oldS}';
      if (hits > 1) return '第 $idx 段原文出现 $hits 次，需要带更多上下文才能唯一定位';
      text = text.replaceFirst(oldS, newS);
    }
    if (text == before) return '内容没有变化';
    await f.writeAsString(text, flush: true);
    final d = _diffText(before, text);
    return '已应用 ${raw.length} 处修改，文件现 ${text.length} 字符\n$d';
  }

  /// 极简行级 diff（LCS）：给 Chat 的 diff 卡片用，最多 80 行。
  static String _diffText(String before, String after) {
    if (before == after) return '';
    final a = before.split('\n');
    final b = after.split('\n');
    var start = 0;
    while (start < a.length && start < b.length && a[start] == b[start]) {
      start++;
    }
    var endA = a.length;
    var endB = b.length;
    while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
      endA--;
      endB--;
    }
    final midA = a.sublist(start, endA);
    final midB = b.sublist(start, endB);
    final out = <String>['@@ -${start + 1},${midA.length} +${start + 1},${midB.length} @@'];
    final n = midA.length;
    final m = midB.length;
    if (n * m > 40000) {
      out.addAll(midA.map((l) => '-$l'));
      out.addAll(midB.map((l) => '+$l'));
      return out.take(80).join('\n');
    }
    final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        dp[i][j] = midA[i] == midB[j]
            ? dp[i + 1][j + 1] + 1
            : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (midA[i] == midB[j]) {
        out.add(' ${midA[i]}');
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        out.add('-${midA[i]}');
        i++;
      } else {
        out.add('+${midB[j]}');
        j++;
      }
    }
    while (i < n) {
      out.add('-${midA[i++]}');
    }
    while (j < m) {
      out.add('+${midB[j++]}');
    }
    return out.take(80).join('\n');
  }

  static const _skipDirs = {'.git', 'node_modules', '.dart_tool', 'build', '__pycache__', '.cache'};
  static const _maxLine = 200;

  static Future<String> _search(Map<String, dynamic> a) async {
    final root = _resolve(a['path'] as String? ?? '/root');
    if (root == null) return '路径非法';
    final pat = a['pattern'] as String? ?? '';
    if (pat.isEmpty) return 'pattern 不能为空';
    final RegExp re;
    try {
      re = RegExp(pat);
    } catch (e) {
      return '正则非法: $e';
    }
    if (!await Directory(root.path).exists()) return '目录不存在';
    final rows = <String>[];
    var bytes = 0;
    Future<void> walk(Directory dir, int depth) async {
      if (rows.length >= 60 || bytes > 8000 || depth > 12) return;
      List<FileSystemEntity> kids;
      try {
        kids = await dir.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      kids.sort((x, y) => x.path.compareTo(y.path));
      for (final e in kids) {
        if (rows.length >= 60 || bytes > 8000) return;
        final name = e.path.split('/').last;
        if (e is Directory) {
          if (_skipDirs.contains(name) || name.startsWith('.')) continue;
          await walk(e, depth + 1);
        } else if (e is File) {
          try {
            if (await e.length() > 2 * 1024 * 1024) continue;
            final head = await e.openRead(0, 1024).first;
            if (head.contains(0)) continue; // 二进制
            final lines = await e.readAsLines();
            for (var i = 0; i < lines.length && rows.length < 60; i++) {
              if (!re.hasMatch(lines[i])) continue;
              final shown = lines[i].length > _maxLine
                  ? '${lines[i].substring(0, _maxLine)}…'
                  : lines[i];
              final row = '${e.path}:${i + 1}: $shown';
              rows.add(row);
              bytes += row.length;
              if (bytes > 8000) break;
            }
          } catch (_) {}
        }
      }
    }

    await walk(Directory(root.path), 0);
    return rows.isEmpty ? '(无命中)' : rows.join('\n');
  }

  static Future<String> _todo(Map<String, dynamic> a) async {
    final raw = a['items'];
    if (raw is! List) return 'items 必须是数组';
    _todos = raw.whereType<Map>().map((e) {
      final st = '${e['status'] ?? 'pending'}';
      return {
        'title': '${e['title'] ?? ''}',
        'status': ['pending', 'in_progress', 'done'].contains(st) ? st : 'pending',
      };
    }).where((e) => e['title']!.isNotEmpty).toList();
    if (_todos.isEmpty) return '(清单已清空)';
    const mark = {'pending': '[ ]', 'in_progress': '[~]', 'done': '[x]'};
    final done = _todos.where((e) => e['status'] == 'done').length;
    final body = _todos
        .asMap()
        .entries
        .map((e) => '${mark[e.value['status']]} ${e.key + 1}. ${e.value['title']}')
        .join('\n');
    return '$body\n进度 $done/${_todos.length}';
  }

  /// 把容器内绝对路径映射到宿主 rootfs 下，拒绝 `..` 逃逸。
  static File? _resolve(String? path) {
    final root = LinuxEnv.instance.rootfsPath;
    if (root == null || path == null || path.isEmpty) return null;
    final parts = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    return File('$root/${parts.join('/')}');
  }

  /// 远程执行：真连 SSH，不是模拟。密钥/密码都由 SshHostStore 里存的配置决定。
  static Future<String> _sshHosts() async {
    final list = await SshExec().aliases();
    if (list.isEmpty) {
      return '还没有保存的 SSH 主机。让用户去 SSH 页连一次，连上后点「保存主机」。';
    }
    return '已保存 ${list.length} 台：\n${list.map((e) => '- $e').join('\n')}';
  }

  static Future<String> _sshExec(Map<String, dynamic> a) async {
    final alias = (a['alias'] as String? ?? '').trim();
    final cmd = (a['command'] as String? ?? '').trim();
    if (alias.isEmpty) return '缺少 alias（先用 ssh_hosts 看有哪些主机）';
    if (cmd.isEmpty) return '缺少 command';
    var t = (a['timeout'] as num?)?.toInt() ?? 60;
    if (t < 5) t = 5;
    if (t > 300) t = 300;

    TerminalBus.instance.echoCommand('ssh $alias: $cmd');
    final sw = Stopwatch()..start();
    try {
      final r = await SshExec().execOnSaved(alias, cmd, timeoutSeconds: t);
      sw.stop();
      // 输出也镜像进终端，用户在 Linux 页能直接看到远程结果
      TerminalBus.instance.echoResult('${r.stdout}${r.stderr}');
      return r.brief;
    } on SshException catch (e) {
      sw.stop();
      TerminalBus.instance.echoResult('ssh 失败: ${e.message}');
      return 'SSH 失败: ${e.message}';
    }
  }
}
