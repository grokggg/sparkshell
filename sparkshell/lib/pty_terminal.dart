import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// 本地 PTY：C 层 openpty + fork + execv("/system/bin/sh")，JNI 暴露 fd。
class PtyTerminalPage extends StatefulWidget {
  const PtyTerminalPage({
    super.key,
    this.title = '本地 PTY',
    this.commandProvider,
  });

  /// 启动前解析出要执行的程序（默认 /system/bin/sh）。
  /// 返回 null 表示准备失败。
  final Future<String?> Function(void Function(String))? commandProvider;
  final String title;

  @override
  State<PtyTerminalPage> createState() => _PtyTerminalPageState();
}

class _PtyTerminalPageState extends State<PtyTerminalPage> {
  static const _ch = MethodChannel('com.xinghuo.sparkshell/pty');

  final _term = Terminal(maxLines: 5000);
  int _fd = -1;
  Timer? _pump;
  String _status = '未启动';

  @override
  void dispose() {
    _pump?.cancel();
    if (_fd >= 0) {
      _ch.invokeMethod('close', {'fd': _fd});
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      var shell = '/system/bin/sh';
      if (widget.commandProvider != null) {
        setState(() => _status = '准备中…');
        final resolved = await widget.commandProvider!((m) {
          if (mounted) _term.write('\r\n$m\r\n');
        });
        if (resolved == null) {
          setState(() => _status = '准备失败');
          return;
        }
        shell = resolved;
      }
      final fd = await _ch.invokeMethod<int>('open', {'shell': shell});
      if (!mounted) return;
      setState(() {
        _fd = fd ?? -1;
        _status = _fd >= 0 ? 'fd=$_fd  $shell' : '打开失败';
      });
      _term.write('\r\n[sparkshell] pty opened, fd=$_fd\r\n');
      _term.onOutput = (data) {
        final bytes = Uint8List.fromList(utf8.encode(data));
        _ch.invokeMethod('write', {'fd': _fd, 'data': bytes});
      };
      _pump = Timer.periodic(const Duration(milliseconds: 40), (_) => _drain());
    } catch (e) {
      setState(() => _status = '异常: $e');
    }
  }

  Future<void> _drain() async {
    if (_fd < 0) return;
    try {
      final res = await _ch.invokeMethod<Uint8List>('read', {'fd': _fd, 'max': 8192});
      if (res != null && res.isNotEmpty) {
        _term.write(utf8.decode(res, allowMalformed: true));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: const Color(0xFF111A33),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(_status,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9AA7C7))),
              ),
              FilledButton.tonal(
                onPressed: _fd >= 0 ? null : _start,
                child: const Text('启动 PTY'),
              ),
            ],
          ),
        ),
        Expanded(
          child: TerminalView(
            _term,
            autofocus: true,
            backgroundOpacity: 0,
            textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
