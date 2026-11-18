import 'dart:io';

import 'package:flutter/services.dart';

/// 把 APK 里自带的 proot + Debian rootfs 释放到私有目录，并拼出启动命令。
///
/// 关键点：
///  - proot 的 loader 路径在二进制里写死为 /data/data/com.grokggg.sparkshell/files/proot/loader
///  - rootfs 是未压缩 tar（100+ MB），交给 Java 层用 AssetManager 流式拷出 + toybox tar 解包，
///    避免把 100 MB 读进 Dart 堆
///  - debootstrap --foreign 只解包不配置，首次要跑 --second-stage
class LinuxEnv {
  LinuxEnv._();

  static final LinuxEnv instance = LinuxEnv._();

  static const _ch = MethodChannel('com.xinghuo.sparkshell/pty');

  static const _prootFiles = [
    'proot/proot',
    'proot/loader',
    'proot/loader32',
    'proot/libtalloc.so.2',
    'proot/libandroid-shmem.so',
    'proot/libtermux-exec.so',
  ];

  bool _ready = false;
  bool get isReady => _ready;

  String? _rootfs;
  String? get rootfsPath => _rootfs;

  /// 指定一个已解包的 rootfs（测试/诊断用，跳过 assets 释放与第二阶段）。
  void attachRootfs(String path) => _rootfs = path;

  Future<String?> ensureReady(void Function(String) log) async {
    final files = await _filesDir();
    if (files == null) {
      log('拿不到私有目录');
      return null;
    }
    final prootDir = Directory('$files/proot');
    final rootfs = Directory('$files/rootfs');
    final tmp = Directory('$files/tmp');
    await tmp.create(recursive: true);

    // 1) proot 运行环境（小文件，走 rootBundle 即可）
    final prootBin = File('${prootDir.path}/proot');
    if (!await prootBin.exists()) {
      log('释放 proot 运行环境…');
      await prootDir.create(recursive: true);
      for (final name in _prootFiles) {
        final data = await rootBundle.load('assets/$name');
        await File('$files/$name').writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    }
    if (Platform.isAndroid) {
      await Process.run('/system/bin/chmod', ['700', prootBin.path]);
      for (final n in ['loader', 'loader32', 'start.sh']) {
        final f = File('${prootDir.path}/$n');
        if (await f.exists()) await Process.run('/system/bin/chmod', ['700', f.path]);
      }
    }

    // 2) rootfs（100 MB+，Java 层流式解包）
    final marker = File('${rootfs.path}/.sparkshell_ready');
    if (!await marker.exists()) {
      log('解压 Debian rootfs（首次约 1-3 分钟，请勿退出）…');
      final res = await _ch.invokeMethod<String>('prepareRootfs');
      if (res != 'ok') {
        log('rootfs 解压失败 → $res');
        return null;
      }
      // 只有 debootstrap --foreign 产出的 rootfs 才需要第二阶段；Alpine 没有这个目录
      if (await File('${rootfs.path}/debootstrap/debootstrap').exists()) {
        log('执行 debootstrap 第二阶段…');
        final r = await _proot(rootfs.path, tmp.path, [
          '/debootstrap/debootstrap',
          '--second-stage',
        ]);
        log('第二阶段退出码 ${r.exitCode}');
        final out = '${r.stdout}\n${r.stderr}'.trim();
        if (out.isNotEmpty) log(out.split('\n').take(8).join('\n'));
      } else {
        log('非 debootstrap rootfs，跳过第二阶段');
      }
      await marker.writeAsString(DateTime.now().toIso8601String());
    }

    await _writeResolvConf(rootfs.path); // 每次启动都刷，防止被镜像里的空文件覆盖
    final script = await _launchScript(files, rootfs.path, tmp.path);
    _rootfs = rootfs.path;
    _ready = true;
    return script;
  }

  /// 容器内的标准 PATH。宿主是 Android，PATH 指向 /system/bin，
  /// 不显式覆盖的话 guest 里 `ls`/`apk` 全都 not found（真机踩过）。
  static const guestPath =
      '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

  /// 给每条命令套上环境前缀，不依赖 /usr/bin/env 是否存在。
  static String shWrap(String cmd, {String workdir = '/root'}) =>
      'export PATH=$guestPath; export HOME=/root; export LANG=C.UTF-8; '
      'cd ${workdir.isEmpty ? '/' : workdir} 2>/dev/null || cd /; $cmd';

  /// 在容器内跑一条命令（供 Agent 工具调用）。stdout/stderr 合并返回。
  Future<ProcessResult> execShell(String cmd, {String workdir = '/root'}) async {
    final rootfs = _rootfs;
    final base = await _filesDir();
    if (rootfs == null || base == null) {
      return ProcessResult(0, 127, '', 'container not ready');
    }
    return _proot(rootfs, '$base/tmp',
        ['-w', workdir, '/bin/sh', '-c', shWrap(cmd, workdir: workdir)]);
  }

  Future<ProcessResult> _proot(String rootfs, String tmp, List<String> args) {
    final files = File(rootfs).parent.path;
    return Process.run(
      '$files/proot/proot',
      [
        '--link2symlink', '-0', '-r', rootfs,
        '-b', '/dev', '-b', '/proc', '-b', '/sys', '-b', '/sdcard', '-b', '/storage',
        ...args,
      ],
      environment: {
        'LD_LIBRARY_PATH': '$files/proot',
        'PROOT_TMP_DIR': tmp,
        'PROOT_L2S_DIR': '$files/.l2s',
        'PATH': '/system/bin:/system/xbin',
      },
    );
  }

  Future<void> _writeResolvConf(String rootfs) async {
    try {
      await File('$rootfs/etc/resolv.conf').writeAsString(
        'nameserver 223.5.5.5\nnameserver 119.29.29.29\n',
        flush: true,
      );
    } catch (_) {}
  }

  Future<String> _launchScript(String base, String rootfs, String tmp) async {
    final sh = File('$base/proot/start.sh');
    final body = '''#!/system/bin/sh
export LD_LIBRARY_PATH=$base/proot
export PROOT_TMP_DIR=$tmp
export PROOT_L2S_DIR=$base/.l2s
SHELL_BIN=/bin/bash
[ -x $rootfs/bin/bash ] || [ -x $rootfs/usr/bin/bash ] || SHELL_BIN=/bin/sh
exec $base/proot/proot --link2symlink -0 \\
  -r $rootfs \\
  -b /dev -b /proc -b /sys -b /storage -b /sdcard \\
  -w /root \\
  /usr/bin/env -i HOME=/root TERM=xterm-256color LANG=C.UTF-8 \\
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
  \$SHELL_BIN -l
''';
    await sh.writeAsString(body, flush: true);
    if (Platform.isAndroid) {
      await Process.run('/system/bin/chmod', ['700', sh.path]);
    }
    return sh.path;
  }

  Future<String?> _filesDir() async {
    try {
      return await _ch.invokeMethod<String>('filesDir');
    } catch (_) {
      return null;
    }
  }
}
