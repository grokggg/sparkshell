import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'term/terminal_bus.dart';

/// 本地 PTY：C 层 openpty + fork + execv("/system/bin/sh")，JNI 暴露 fd。
class PtyTerminalPage extends StatefulWidget {
  const PtyTerminalPage({
    super.key,
    this.title = '本地 PTY',
    this.commandProvider,
    this.toolchainCommand,
  });

  /// 一键把常用开发工具装上（Alpine 用 apk、Debian 用 apt），null 表示不显示按钮。
  final String? toolchainCommand;

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
  final _ai = TextEditingController();
  int _fd = -1;
  Timer? _pump;
  String _status = '未启动';

  @override
  void dispose() {
    _pump?.cancel();
    TerminalBus.instance.detach();
    _ai.dispose();
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
      // AI 的动作从这里流进终端屏幕：一个入口，不再两套世界
      TerminalBus.instance.attach(_term.write);
      _term.onOutput = (data) {
        final bytes = Uint8List.fromList(utf8.encode(data));
        _ch.invokeMethod('write', {'fd': _fd, 'data': bytes});
      };
      _pump = Timer.periodic(const Duration(milliseconds: 40), (_) => _drain());
    } catch (e) {
      setState(() => _status = '异常: $e');
    }
  }

  bool _installing = false;

  /// 一键装 python3/git/curl/vim：直接打进当前 PTY，用户在终端里能看到进度。
  Future<void> _installToolchain() async {
    final cmd = widget.toolchainCommand;
    if (cmd == null || _fd < 0) return;
    setState(() => _installing = true);
    await _send('$cmd\r');
    // apk/apt 是同步阻塞的，等提示符回来就当作结束；这里只做按钮防抖。
    await Future.delayed(const Duration(seconds: 25));
    if (mounted) setState(() => _installing = false);
  }

  /// 点 ✨ 弹一行输入：问题交给 Chat 的 Agent，回答同步镜像回这块屏幕。
  /// 不再常驻一个大输入框——一个页面只留终端 + 一行按钮，视觉上不打架。
  void _promptAi() {
    _ai.clear();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E1526),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 12,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
        ),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _ai,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) {
                _askAi();
                Navigator.of(ctx).pop();
              },
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.auto_awesome, size: 18),
                hintText: '让 AI 干活：装 python3 / 看看 /root / 写个脚本…',
                hintStyle: TextStyle(fontSize: 12),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            onPressed: () {
              _askAi();
              Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.send),
          ),
        ]),
      ),
    );
  }

  void _askAi() {
    final q = _ai.text.trim();
    if (q.isEmpty) return;
    _ai.clear();
    _term.write('\r\n\x1b[35m? 你\x1b[0m $q\r\n');
    TerminalBus.instance.askAi(q);
  }

  /// 中文输入法常把回车吃掉（先确认候选词），所以按钮直发字节，绕开 IME。
  Future<void> _send(String seq) async {
    if (_fd < 0) return;
    try {
      await _ch.invokeMethod('write',
          {'fd': _fd, 'data': Uint8List.fromList(utf8.encode(seq))});
    } catch (_) {}
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

  Widget _key(String label, String seq) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: OutlinedButton(
        onPressed: _fd < 0 ? null : () => _send(seq),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 34),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
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
              if (widget.toolchainCommand != null && _fd >= 0) ...[
                OutlinedButton.icon(
                  onPressed: _installing ? null : _installToolchain,
                  icon: const Icon(Icons.build_outlined, size: 16),
                  label: Text(_installing ? '装工具链…' : '装工具链',
                      style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
              ],
              if (_fd >= 0)
                IconButton(
                  tooltip: '问 AI（在同一个终端里干活）',
                  onPressed: _promptAi,
                  icon: const Icon(Icons.auto_awesome, size: 20),
                ),
              FilledButton.tonal(
                onPressed: _fd >= 0 ? null : _start,
                child: const Text('启动 PTY'),
              ),
            ],
          ),
        ),
        Container(
          color: const Color(0xFF0B1220),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            _key('⏎ 回车', '\r'),
            _key('Tab', '\t'),
            _key('Ctrl-C', '\x03'),
            _key('Ctrl-D', '\x04'),
            _key('清屏', '\x0c'),
          ]),
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
