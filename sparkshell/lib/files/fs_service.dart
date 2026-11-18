import 'dart:convert';
import 'dart:io';

/// 容器文件系统访问层。
///
/// 容器内的 `/root/a.txt` 物理上就是宿主 `filesDir/rootfs/root/a.txt`，
/// 所以这里不做 proot 转发，直接读写宿主路径——快一个数量级，也不怕 proot 挂掉。
/// 纯 Dart，不碰 Flutter，桌面可直接跑测试。
class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path; // 始终是容器内路径
  final bool isDir;
  final int size;
  final DateTime? modified;
}

class FsException implements Exception {
  FsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class FsService {
  FsService(this.rootPath);

  /// 宿主侧 rootfs 根目录（不带结尾斜杠）。
  final String rootPath;

  static const _maxRead = 300000;

  /// 归一化成 `a/b/c` 形式：折叠重复斜杠、去掉结尾斜杠；根目录返回空串。
  static String normalize(String guestPath) {
    final parts = <String>[];
    for (final seg in guestPath.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isEmpty) return '\u0000'; // 越界标记
        parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return parts.join('/');
  }

  bool isSafe(String guestPath) => normalize(guestPath) != '\u0000';

  String toHost(String guestPath) {
    final n = normalize(guestPath);
    if (n == '\u0000') throw FsException('路径非法');
    return n.isEmpty ? rootPath : '$rootPath/$n';
  }

  String toGuest(String hostPath) {
    final root = rootPath.endsWith('/') ? rootPath.substring(0, rootPath.length - 1) : rootPath;
    if (hostPath == root) return '/';
    if (hostPath.startsWith('$root/')) return '/${hostPath.substring(root.length + 1)}';
    return hostPath;
  }

  Future<List<FsEntry>> list(String guestPath) async {
    final dir = Directory(toHost(guestPath));
    if (!await dir.exists()) throw FsException('目录不存在: $guestPath');
    final out = <FsEntry>[];
    await for (final e in dir.list(followLinks: false)) {
      try {
        final name = e.path.split('/').last;
        final isDir = e is Directory;
        var size = 0;
        DateTime? modified;
        if (isDir) {
          modified = (await e.stat()).modified;
        } else {
          final st = await e.stat();
          size = st.size;
          modified = st.modified;
        }
        out.add(FsEntry(
          name: name,
          path: '${normalize(guestPath).isEmpty ? '' : '/${normalize(guestPath)}'}/$name',
          isDir: isDir,
          size: size,
          modified: modified,
        ));
      } catch (_) {
        // 无权限或已被删掉的条目直接跳过，不能拖垮整个列表
      }
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  Future<bool> exists(String guestPath) async {
    if (!isSafe(guestPath)) return false;
    final host = toHost(guestPath);
    return File(host).exists() || Directory(host).exists();
  }

  Future<bool> isBinary(String guestPath) async {
    final f = File(toHost(guestPath));
    if (!await f.exists()) return false;
    final raf = await f.open();
    try {
      final head = await raf.read(1024);
      if (head.contains(0)) return true;
      try {
        utf8.decode(head, allowMalformed: false);
        return false;
      } catch (_) {
        return true; // 前 1KB 都不是合法 UTF-8，八成是图片/压缩包
      }
    } finally {
      await raf.close();
    }
  }

  Future<String> readText(String guestPath, {int maxBytes = _maxRead}) async {
    final f = File(toHost(guestPath));
    if (!await f.exists()) throw FsException('文件不存在: $guestPath');
    final len = await f.length();
    if (len > maxBytes) {
      throw FsException('文件太大（${(len / 1024).toStringAsFixed(0)} KB），编辑上限 ${maxBytes ~/ 1024} KB');
    }
    if (await isBinary(guestPath)) throw FsException('二进制文件，不能按文本打开');
    return f.readAsString();
  }

  Future<void> writeText(String guestPath, String content) async {
    final f = File(toHost(guestPath));
    await f.parent.create(recursive: true);
    await f.writeAsString(content, flush: true);
  }

  Future<void> mkdir(String guestPath) async {
    await Directory(toHost(guestPath)).create(recursive: true);
  }

  Future<void> rename(String from, String to) async {
    final src = toHost(from);
    final dst = toHost(to);
    if (!await FileSystemEntity.type(src).then((t) => t != FileSystemEntityType.notFound)) {
      throw FsException('源不存在: $from');
    }
    if (await FileSystemEntity.type(dst).then((t) => t != FileSystemEntityType.notFound)) {
      throw FsException('目标已存在: $to');
    }
    await Directory(dst).parent.create(recursive: true);
    final t = await FileSystemEntity.type(src, followLinks: false);
    if (t == FileSystemEntityType.directory) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
  }

  Future<void> delete(String guestPath) async {
    final n = normalize(guestPath);
    if (n.isEmpty || n == '\u0000') throw FsException('拒绝删除根目录');
    final p = toHost(guestPath);
    final t = await FileSystemEntity.type(p, followLinks: false);
    if (t == FileSystemEntityType.notFound) return;
    if (t == FileSystemEntityType.directory) {
      await Directory(p).delete(recursive: true);
    } else {
      await File(p).delete();
    }
  }
}
