import 'dart:async';

import 'package:flutter/services.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import 'fs_service.dart';

/// 容器文件浏览器：能看、能改、能把手机里的文件放进来。
///
/// rootPath 是宿主侧 rootfs 绝对路径（filesDir/rootfs），
/// 容器路径 /root/x 与宿主一一对应，所以这里不做 proot 转发。
class FilePage extends StatefulWidget {
  const FilePage({
    super.key,
    required this.rootPath,
    this.startPath = '/root',
    this.onSendToChat,
  });

  /// 把文件路径发给 Chat（在输入框里变成 @路径 引用）。
  final void Function(String path)? onSendToChat;

  final String rootPath;
  final String startPath;

  @override
  State<FilePage> createState() => _FilePageState();
}

class _FilePageState extends State<FilePage> {
  late String _rootPath;
  late FsService _fs;
  late String _path = widget.startPath;
  List<FsEntry> _items = const [];
  bool _loading = true;
  String? _err;
  String _diag = '';
  String? _note;
  int _autoRetry = 0;

  @override
  void initState() {
    super.initState();
    _rootPath = _resolveRoot(widget.rootPath);
    _fs = FsService(_rootPath);
    if (!Directory(_rootPath).existsSync()) {
      _loading = false;
      _err = 'rootfs 路径不可用：${widget.rootPath}';
    } else {
      _load();
    }
  }

  /// 传进来的必须是 rootfs 根目录。历史 bug 会把 proot 的 start.sh 当根目录传进来，
  /// 这种情况下往上找几层，把同级的 rootfs/ 认回来，别让用户对着报错页干瞪眼。
  static String _resolveRoot(String p) {
    if (Directory(p).existsSync()) return p;
    var dir = File(p).parent;
    for (var i = 0; i < 4; i++) {
      final cand = Directory('${dir.path}/rootfs');
      if (cand.existsSync()) return cand.path;
      final up = dir.parent;
      if (up.path == dir.path) break;
      dir = up;
    }
    return p;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      // rootfs 里没有 /root 时别把用户卡死在报错页，直接退到根目录
      if (_path == '/root' && !await Directory(_fs.toHost('/root')).exists()) {
        // 首次解包还没跑到 /root 时，等一下再来，别急着报"目录不存在"
        final marker = File('$_rootPath/.sparkshell_ready');
        if (!await marker.exists() && _autoRetry < 8) {
          _autoRetry++;
          if (mounted) {
            setState(() {
              _loading = false;
              _err = null;
              _items = const [];
              _diag = 'rootfs 正在解包（第 $_autoRetry 次等待）…';
            });
          }
          await Future.delayed(const Duration(seconds: 4));
          if (mounted) return _load();
          return;
        }
        _path = '/';
        _note = 'rootfs 里没有 /root，已切到根目录';
      }
      final list = await _fs.list(_path);
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
      final note = _note;
      if (note != null) {
        _note = null;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
      }
    } catch (e) {
      final diag = await _diagnose();
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _diag = diag;
        _loading = false;
      });
    }
  }

  /// 出错时把"我到底在看哪个目录"摆出来，真机截图就能定位。
  Future<String> _diagnose() async {
    final root = _rootPath;
    final host = '${root.endsWith('/') ? root.substring(0, root.length - 1) : root}'
        '${_path == '/' ? '' : _path}';
    final sb = StringBuffer('rootPath = $root\n目标宿主路径 = $host\n');
    try {
      final d = Directory(root);
      sb.writeln('rootfs 存在 = ${await d.exists()}');
      if (await d.exists()) {
        final names = <String>[];
        await for (final e in d.list(followLinks: false).take(12)) {
          names.add(e.path.split('/').last + (e is Directory ? '/' : ''));
        }
        sb.writeln('rootfs 下前 12 项 = ${names.join(', ')}');
      }
    } catch (err) {
      sb.writeln('诊断失败 = $err');
    }
    return sb.toString().trimRight();
  }

  /// 目录确实不存在时，给一个"建出来再读"的出口（导入过的 /root 常被误判）。
  Future<void> _createHere() async {
    try {
      await _fs.mkdir(_path);
      await _load();
    } catch (e) {
      _toast('创建失败：$e');
    }
  }

  void _go(String path) {
    setState(() => _path = path.isEmpty ? '/' : path);
    _load();
  }

  void _up() {
    if (_path == '/' || _path.isEmpty) return;
    final idx = _path.lastIndexOf('/');
    _go(idx <= 0 ? '/' : _path.substring(0, idx));
  }

  /// 面包屑：/root/a/b → [('/', '/'), ('root', '/root'), ('a', '/root/a'), ('b', '/root/a/b')]
  List<(String, String)> get _crumbs {
    final out = <(String, String)>[('/', '/')];
    if (_path == '/' || _path.isEmpty) return out;
    final parts = _path.split('/').where((e) => e.isNotEmpty).toList();
    var acc = '';
    for (final p in parts) {
      acc = '$acc/$p';
      out.add((p, acc));
    }
    return out;
  }

  Future<void> _open(FsEntry e) async {
    if (e.isDir) {
      _go(e.path);
      return;
    }
    try {
      if (await _fs.isBinary(e.path)) {
        _toast('二进制文件，暂不支持预览（可长按复制路径）');
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => EditorPage(fs: _fs, path: e.path),
      ));
      _load();
    } catch (err) {
      _toast('打不开：$err');
    }
  }

  Future<void> _import() async {
    try {
      final res = await const MethodChannel('sparkshell/io')
          .invokeMethod<List<dynamic>>('pickAndImportTo', {'destDir': _path});
      final n = res?.length ?? 0;
      _toast(n == 0 ? '没有选择文件' : '已导入 $n 个文件到 $_path');
      if (n > 0) _load();
    } on PlatformException catch (e) {
      _toast('导入失败：${e.message ?? e.code}');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 新建空文件并直接进编辑器。之前只能用"新建文件夹"，于是 hello.py 变成了目录。
  /// 名字里带空壳/斜杠/.. 的，直接拦下来——真机上已经出现过"文件名（如 hello.py）"这种鬼名字。
  String? _checkName(String raw) {
    final n = raw.trim();
    if (n.isEmpty) return '名字不能为空';
    if (n.contains('/') || n.contains('\\')) return '名字里不能有斜杠';
    if (n == '.' || n == '..') return '这个名字不能用';
    if (n.length > 120) return '名字太长了';
    return null;
  }

  Future<void> _newFile() async {
    final name = await _ask('新建文件', hint: '例如 hello.py');
    if (name == null) return;
    final bad = _checkName(name);
    if (bad != null) {
      _toast(bad);
      return;
    }
    final clean = name.trim();
    final path = '$_path/$clean'.replaceAll('//', '/');
    try {
      final exists = await _fs.exists(path);
      if (exists) {
        _toast('已存在同名文件/目录');
        return;
      }
      await _fs.writeText(path, '');
      _toast('已创建 $path（0 字节）');
      await _load();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => EditorPage(fs: _fs, path: path),
      ));
      _load();
    } catch (e) {
      _toast('创建失败：$e');
    }
  }

  Future<void> _newFolder() async {
    final name = await _ask('新建文件夹', hint: '文件夹名');
    if (name == null) return;
    final bad = _checkName(name);
    if (bad != null) {
      _toast(bad);
      return;
    }
    try {
      await _fs.mkdir('$_path/${name.trim()}'.replaceAll('//', '/'));
      _load();
    } catch (e) {
      _toast('创建失败：$e');
    }
  }

  Future<void> _sheet(FsEntry e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('重命名'),
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('删除'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('复制路径'),
            onTap: () => Navigator.pop(context, 'copy'),
          ),
          if (widget.onSendToChat != null)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('发给 Agent'),
              subtitle: Text(e.isDir ? '把目录路径放进 Chat 输入框' : '把文件路径放进 Chat 输入框'),
              onTap: () => Navigator.pop(context, 'chat'),
            ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        final name = await _ask('重命名', initial: e.name);
        if (name == null || name.trim().isEmpty || name.trim() == e.name) return;
        final bad = _checkName(name);
        if (bad != null) {
          _toast(bad);
          return;
        }
        try {
          await _fs.rename(e.path, '$_path/${name.trim()}'.replaceAll('//', '/'));
          _load();
        } catch (err) {
          _toast('重命名失败：$err');
        }
        break;
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('删除 ${e.name}？'),
            content: Text(e.isDir ? '目录及其中所有内容都会被删除，不可恢复。' : '文件将被删除，不可恢复。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await _fs.delete(e.path);
          _load();
        } catch (err) {
          _toast('删除失败：$err');
        }
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: e.path));
        _toast('已复制 ${e.path}');
        break;
      case 'chat':
        widget.onSendToChat!(e.path);
        _toast('已放进 Chat 输入框：${e.path}');
        break;
    }
  }

  Future<String?> _ask(String title, {String initial = '', String hint = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint.isEmpty ? '输入名称' : hint),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('确定')),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _time(DateTime? t) {
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件'),
        actions: [
          IconButton(
            tooltip: '上一级',
            onPressed: _path == '/' ? null : _up,
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: '新建文件', onPressed: _newFile, icon: const Icon(Icons.note_add_outlined)),
          IconButton(tooltip: '新建文件夹', onPressed: _newFolder, icon: const Icon(Icons.create_new_folder_outlined)),
          IconButton(tooltip: '导入手机文件', onPressed: _import, icon: const Icon(Icons.upload_file)),
        ],
      ),
      body: Column(children: [
        _breadcrumb(),
        const Divider(height: 1),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _breadcrumb() {
    final crumbs = _crumbs;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: crumbs.length,
        separatorBuilder: (_, __) => const Icon(Icons.chevron_right, size: 14),
        itemBuilder: (_, i) {
          final (label, full) = crumbs[i];
          final last = i == crumbs.length - 1;
          return Center(
            child: InkWell(
              onTap: last ? null : () => _go(full),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: last ? Theme.of(context).colorScheme.primary : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (_err != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 40),
          const SizedBox(height: 12),
          Text(_err!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          if (_diag.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _diag,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(spacing: 12, children: [
            FilledButton(onPressed: _load, child: const Text('重试')),
            OutlinedButton(onPressed: _createHere, child: const Text('建出来再读')),
          ]),
        ]),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.folder_open, size: 40, color: Colors.white38),
          const SizedBox(height: 12),
          const Text('空目录'),
          const SizedBox(height: 4),
          Text('点右上角上传，把手机文件放进这里',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
      itemBuilder: (_, i) {
        final e = _items[i];
        return ListTile(
          leading: Icon(
            e.isDir ? Icons.folder : Icons.description_outlined,
            color: e.isDir ? Colors.amber : null,
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: e.isDir ? null : Text('${_size(e.size)} · ${_time(e.modified)}'),
          trailing: e.isDir ? const Icon(Icons.chevron_right, size: 18) : null,
          onTap: () => _open(e),
          onLongPress: () => _sheet(e),
        );
      },
    );
  }
}

/// 文本编辑页。保存走 FsService.writeText，未保存返回会拦一下。
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.fs, required this.path});

  final FsService fs;
  final String path;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final _ctrl = TextEditingController();
  bool _loading = true;
  bool _dirty = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = await widget.fs.readText(widget.path);
      if (!mounted) return;
      _ctrl.text = text;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    try {
      // 末尾没有换行的文本，cat 之后提示符会黏在内容后面，补一个。
      var body = _ctrl.text;
      if (body.isNotEmpty && !body.endsWith('\n')) body = '$body\n';
      await widget.fs.writeText(widget.path, body);
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已保存 ${_ctrl.text.length} 字符')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('有未保存的改动，返回将丢失。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('继续编辑')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('放弃')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.path.split('/').last, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: '保存', onPressed: _loading || _err != null ? null : _save, icon: const Icon(Icons.save_outlined)),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _err != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_err!, textAlign: TextAlign.center)))
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: _ctrl,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        hintText: '空文件，直接输入内容',
                      ),
                      onChanged: (_) {
                        if (!_dirty) setState(() => _dirty = true);
                      },
                    ),
                  ),
      ),
    );
  }
}
