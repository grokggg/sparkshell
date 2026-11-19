import 'dart:convert';
import 'dart:io';

/// 一条后台任务的元数据。纯数据，不依赖 Flutter。
///
/// [logPath] / [pidPath] 都是 **宿主路径**（rootfs 前缀那套），调用方可以直接
/// `File(task.logPath).readAsString()`；容器里那条 nohup 命令用的是把这些路径
/// 映射进 rootfs 之后的容器路径（见 TaskStore._inContainer）。
class BackgroundTask {
  BackgroundTask({
    required this.id,
    required this.command,
    required this.logPath,
    required this.pidPath,
    required this.startedAt,
  });

  final String id;
  final String command;
  final String logPath;
  final String pidPath;
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'command': command,
        'log': logPath,
        'pid': pidPath,
        'startedAt': startedAt.toIso8601String(),
      };

  /// 元数据不完整（缺 id/log/pid）就当坏文件丢掉，别让 list() 崩。
  static BackgroundTask? fromJson(Map<String, dynamic> m) {
    final id = _str(m['id']);
    final log = _str(m['log']);
    final pid = _str(m['pid']);
    if (id.isEmpty || log.isEmpty || pid.isEmpty) return null;
    return BackgroundTask(
      id: id,
      command: _str(m['command']),
      logPath: log,
      pidPath: pid,
      startedAt: DateTime.tryParse(_str(m['startedAt'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static String _str(Object? v) => v is String ? v : '';
}

/// 容器内后台任务：命令扔进 nohup 里跑，日志和 pid 落盘，调用方轮询 tail/alive。
///
/// 为什么不用同步 bash 工具：手机锁屏后 App 被挂起，一条 `apk add` 卡在
/// 600 秒超时里既看不到进度、也会把整轮对话堵死。这里只负责「启动 + 读文件」，
/// 真正的命令在容器里独立跑，宿主侧每次只做几十毫秒的文件 IO。
class TaskStore {
  /// tasksDir 是宿主上的任务目录，例如 /data/.../files/rootfs/root/.tasks
  TaskStore(this.tasksDir);

  final String tasksDir;

  /// 可选：容器内执行器（一般注入 `LinuxEnv.instance.execShell`）。
  /// 设了就优先用容器里的 `kill -0` 判活；不设就直接查宿主 /proc ——
  /// proot 不隔离 PID，容器里 echo 出来的 pid 就是宿主 pid，读 /proc 更快，
  /// 也不用为了看一眼状态再起一个 proot。将来换成 PID namespace 的容器就得设它。
  Future<ProcessResult> Function(String shell)? containerExec;

  /// tail 单次最多回多少字符；读日志时最多回溯多少字节。
  static const _maxTailChars = 6000;
  static const _tailBytes = 256 * 1024;

  /// 把命令丢到后台。
  ///
  /// [exec] 负责在容器里跑一条 shell 字符串并返回 ProcessResult；它只需要
  /// 「把我们的启动脚本执行掉」，几十毫秒就该返回，不等真正的任务。
  Future<BackgroundTask> start(
    String command,
    Future<ProcessResult> Function(String shell) exec,
  ) async {
    final cmd = command.trim();
    final now = DateTime.now();
    // 取 id 也不许抛：万一目录读不了，退回裸时间戳，后面写文件失败会各自兜底
    var id = 't${now.millisecondsSinceEpoch ~/ 1000}';
    try {
      id = await _nextId(now);
    } catch (_) {}
    final task = BackgroundTask(
      id: id,
      command: cmd,
      logPath: _join(tasksDir, '$id.log'),
      pidPath: _join(tasksDir, '$id.pid'),
      startedAt: now,
    );

    try {
      // 宿主侧先建目录：后面 tail/list 读文件不依赖容器是否顺利起来
      await Directory(tasksDir).create(recursive: true);
      // 元数据先写：即使启动脚本炸了，list() 也能看到这条任务
      await _writeMeta(task);
    } catch (_) {
      return task; // 目录都建不了，tail/alive 会各自给友好提示
    }

    try {
      final r = await exec(_launchScript(cmd, task));
      if (r.exitCode != 0) {
        final msg = '${r.stdout}${r.stderr}'.trim();
        await _appendLog(
          task.logPath,
          '[启动失败 exit=${r.exitCode}] ${msg.isEmpty ? '无输出' : msg}',
        );
      }
    } catch (e) {
      // 不 throw 给调用方，但把原因写进日志，tail 能看到
      await _appendLog(task.logPath, '[启动异常] $e');
    }
    return task;
  }

  /// 读日志最后 [lines] 行。文件不存在 / 还没输出都返回 '(还没有输出)'。
  Future<String> tail(String id, {int lines = 60}) async {
    try {
      if (!_safeId(id)) return '(任务已丢失)';
      final meta = await _readMeta(id);
      final path = BackgroundTask._str(meta?['log']);
      final file = File(path.isEmpty ? _join(tasksDir, '$id.log') : path);
      if (!await file.exists()) return '(还没有输出)';

      final text = await _tailText(file, _tailBytes);
      final rows = text.split('\n');
      // 末尾换行会 split 出一个空串，扔掉，否则 tail 会白占一行
      if (rows.isNotEmpty && rows.last.trim().isEmpty) rows.removeLast();
      if (rows.isEmpty) return '(还没有输出)';

      final want = lines <= 0 ? 60 : (lines > 2000 ? 2000 : lines);
      final body = rows.length <= want
          ? rows.join('\n')
          : rows.sublist(rows.length - want).join('\n');
      if (body.trim().isEmpty) return '(还没有输出)';
      if (body.length <= _maxTailChars) return body;

      // 超长保留尾部：报错和进度都在最后几行
      const note = '…(仅显示最后 6000 字符)\n';
      final keep = _maxTailChars - note.length;
      return '$note${body.substring(body.length - keep)}';
    } catch (_) {
      return '(读取日志失败)';
    }
  }

  /// 进程是否还活着：读 pid 文件（可能带换行/空），解析失败一律当已结束。
  Future<bool> alive(String id) async {
    try {
      if (!_safeId(id)) return false;
      final pid = await _readPid(id);
      if (pid == null) return false;

      final hook = containerExec;
      if (hook != null) {
        try {
          final r = await hook('kill -0 $pid 2>/dev/null');
          return r.exitCode == 0;
        } catch (_) {
          return false;
        }
      }
      return _pidAlive(pid);
    } catch (_) {
      return false;
    }
  }

  /// 列出所有任务：按开始时间倒序，最多 20 条。
  /// 每项 {id, command, alive, bytes, startedAt}，值全是字符串。
  Future<List<Map<String, String>>> list() async {
    try {
      final dir = Directory(tasksDir);
      if (!await dir.exists()) return [];

      // 靠 *.json 枚举，不猜文件名
      final found = <BackgroundTask>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final raw = jsonDecode(await e.readAsString());
          if (raw is Map) {
            final t = BackgroundTask.fromJson(Map<String, dynamic>.from(raw));
            if (t != null) found.add(t);
          }
        } catch (_) {
          // 单个坏文件不影响整张列表
        }
      }

      found.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      final picked = found.length > 20 ? found.sublist(0, 20) : found;

      final pids = <int?>[];
      for (final t in picked) {
        pids.add(await _readPid(t.id));
      }
      final flags = await _aliveMany(pids);

      final rows = <Map<String, String>>[];
      for (var i = 0; i < picked.length; i++) {
        final t = picked[i];
        var bytes = 0;
        try {
          bytes = await File(t.logPath).length();
        } catch (_) {
          // 日志读不到（还没建/已删）：字节数按 0 报，列表照样出
        }
        rows.add({
          'id': t.id,
          'command': t.command,
          'alive': flags[i] ? 'true' : 'false',
          'bytes': '$bytes',
          'startedAt': t.startedAt.toIso8601String(),
        });
      }
      return rows;
    } catch (_) {
      return [];
    }
  }

  // ───────────────────────────── 内部实现 ─────────────────────────────

  /// 拼启动脚本。
  ///
  /// 几个细节：
  ///  - mkdir 用 `;` 串而不是 `&&`：`A && B & C` 会把整条链塞进子 shell，
  ///    `$!` 拿到的是子 shell 的 pid，不是任务本身；
  ///  - 三个路径都单引号包裹并转义内部单引号，command 里再花哨也注不进来；
  ///  - `< /dev/null` 防止容器里缺 tty 时 nohup 抱怨；
  ///  - `cd /root` 与工具层的默认工作目录保持一致，相对路径才不会写错地方。
  String _launchScript(String cmd, BackgroundTask t) {
    // sh 里的 $! = 上一个后台进程的 pid。先落成常量再插值，
    // 免得在长串里写转义（写成 \$! 会被 sh 当字面量，pid 文件就废了）
    const lastPid = r'$!';
    final dir = _inContainer(tasksDir) ?? tasksDir;
    final log = _inContainer(t.logPath) ?? t.logPath;
    final pid = _inContainer(t.pidPath) ?? t.pidPath;
    return 'mkdir -p ${_sq(dir)} 2>/dev/null; '
        'cd /root 2>/dev/null; '
        'nohup sh -c ${_sq(cmd)} > ${_sq(log)} 2>&1 < /dev/null & '
        'echo $lastPid > ${_sq(pid)}';
  }

  /// 宿主路径 → 容器路径：<appFiles>/rootfs/root/.tasks → /root/.tasks。
  /// 找不到 /rootfs/ 就返回 null，调用方退回原路径（测试里的临时目录走这条）。
  static String? _inContainer(String hostPath) {
    const marker = '/rootfs/';
    // 取最后一个：上层目录名里也可能出现 rootfs（如 /data/rootfs_backup/rootfs/...）
    final i = hostPath.lastIndexOf(marker);
    if (i >= 0) {
      final rest = hostPath.substring(i + marker.length);
      return rest.isEmpty ? '/' : '/$rest';
    }
    if (hostPath == '/rootfs' || hostPath.endsWith('/rootfs')) return '/';
    return null;
  }

  /// 单引号包裹；内部的 ' 写成 '\''。sh 里唯一 100% 安全的转义方式。
  static String _sq(String s) {
    const esc = r"'\''"; // 即 ' → '\''（关引号、转义一个引号、再开引号）
    final body = s.replaceAll("'", esc);
    return "'$body'";
  }

  Future<String> _nextId(DateTime now) async {
    final base = 't${now.millisecondsSinceEpoch ~/ 1000}';
    var id = base;
    var n = 1;
    // 同一秒连开多个任务：加 -2、-3 …，最多让到 -99
    while (await _metaExists(id) ||
        await File(_join(tasksDir, '$id.log')).exists()) {
      n++;
      id = '$base-$n';
      if (n > 99) break;
    }
    return id;
  }

  Future<bool> _metaExists(String id) async {
    try {
      return await File(_join(tasksDir, '$id.json')).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeMeta(BackgroundTask t) async {
    final f = File(_join(tasksDir, '${t.id}.json'));
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(t.toJson()), flush: true);
  }

  Future<Map<String, dynamic>?> _readMeta(String id) async {
    try {
      final f = File(_join(tasksDir, '$id.json'));
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      return Map<String, dynamic>.from(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _appendLog(String path, String text) async {
    try {
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString('$text\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 连日志都写不了就只能放弃：这层不允许把异常抛给调用方
    }
  }

  /// 读 pid：trim 后 parse，空文件/脏内容都当「没有 pid」。
  Future<int?> _readPid(String id) async {
    try {
      final meta = await _readMeta(id);
      final path = BackgroundTask._str(meta?['pid']);
      final f = File(path.isEmpty ? _join(tasksDir, '$id.pid') : path);
      final raw = (await f.readAsString()).trim();
      if (raw.isEmpty) return null;
      final pid = int.tryParse(raw);
      if (pid == null || pid <= 0) return null;
      return pid;
    } catch (_) {
      return null;
    }
  }

  /// 宿主侧判活：先看 /proc（顺手排掉僵尸），读不到再退回 kill -0。
  Future<bool> _pidAlive(int pid) async {
    try {
      final stat = await File('/proc/$pid/stat').readAsString();
      final close = stat.lastIndexOf(')');
      if (close >= 0) {
        // comm 里可能有空格和括号，所以从最后一个 ')' 之后切；第一列是状态
        final rest = stat.substring(close + 1).trim();
        final st = rest.isEmpty ? '' : rest.split(RegExp(r'\s+')).first;
        if (st == 'Z' || st == 'X' || st == 'x') return false;
        return true;
      }
      return true;
    } catch (_) {
      // /proc 不可读（Android 上偶发权限收紧），落到 kill -0
    }

    try {
      final r = await Process.run('kill', ['-0', '$pid']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 批量判活：设了 containerExec 就一条脚本查完，别为 20 个任务起 20 次 proot。
  Future<List<bool>> _aliveMany(List<int?> pids) async {
    final res = List<bool>.filled(pids.length, false);
    final valid = <int>[];
    final index = <int>[];
    for (var i = 0; i < pids.length; i++) {
      final p = pids[i];
      if (p != null && p > 0) {
        valid.add(p);
        index.add(i);
      }
    }
    if (valid.isEmpty) return res;

    final hook = containerExec;
    if (hook != null) {
      try {
        final joined = valid.join(' ');
        final r = await hook(
          'for p in $joined; do kill -0 \$p 2>/dev/null && echo 1 || echo 0; done',
        );
        final out = '${r.stdout}'
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        for (var i = 0; i < valid.length && i < out.length; i++) {
          res[index[i]] = out[i] == '1';
        }
        return res;
      } catch (_) {
        return res;
      }
    }

    final flags = await Future.wait(valid.map(_pidAlive));
    for (var i = 0; i < valid.length; i++) {
      res[index[i]] = flags[i];
    }
    return res;
  }

  /// 读文件尾部；文件比 [maxBytes] 大时只读最后一段，避免把几十 MB 日志读进内存。
  Future<String> _tailText(File f, int maxBytes) async {
    final len = await f.length();
    if (len <= maxBytes) {
      return utf8.decode(await f.readAsBytes(), allowMalformed: true);
    }
    final raf = await f.open();
    try {
      await raf.setPosition(len - maxBytes);
      final bytes = await raf.read(maxBytes);
      var text = utf8.decode(bytes, allowMalformed: true);
      // 从中间切进来，首行大概率是半截，丢掉
      final nl = text.indexOf('\n');
      if (nl >= 0) text = text.substring(nl + 1);
      return text;
    } finally {
      await raf.close();
    }
  }

  static bool _safeId(String id) {
    if (id.isEmpty || id.length > 64) return false;
    if (id.contains('/') || id.contains('\\') || id.contains('..')) return false;
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id);
  }

  static String _join(String a, String b) =>
      a.endsWith('/') ? '$a$b' : '$a/$b';
}
