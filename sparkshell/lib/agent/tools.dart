import 'dart:io';

import '../linux_env.dart';

/// Agent 可用的四个动作。全部作用在 proot 容器里，宿主目录不暴露。
///
/// 文件读写直接走宿主路径（rootfs 前缀），比再套一层 proot 快一个数量级；
/// 只有 bash 必须进容器，否则 glibc 动态链接器对不上。
class Tools {
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
            'timeout': {'type': 'integer', 'description': '秒，默认 60，最大 300'},
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
  ];

  static Future<String> run(String name, Map<String, dynamic> args) async {
    try {
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
        case 'todo':
          return _todo(args);
        default:
          return '未知工具: $name';
      }
    } catch (e) {
      return '工具异常: $e';
    }
  }

  static Future<String> _bash(Map<String, dynamic> a) async {
    final cmd = (a['command'] as String? ?? '').trim();
    if (cmd.isEmpty) return '缺少 command';
    final secs = ((a['timeout'] as num?)?.toInt() ?? 60).clamp(5, 300);
    final r = await LinuxEnv.instance
        .execShell(cmd)
        .timeout(Duration(seconds: secs), onTimeout: () => ProcessResult(0, 124, '', '超时 ${secs}s'));
    final out = '${r.stdout}${r.stderr}'.trim();
    final body = out.length > 8000 ? '${out.substring(0, 8000)}\n…(截断)' : out;
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
    await f.writeAsString(a['content'] as String? ?? '', flush: true);
    final n = await f.length();
    return '已写入 ${f.path}，$n 字节';
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
    return '已替换 ${all ? hits : 1} 处，文件现 ${out.length} 字符';
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
}
