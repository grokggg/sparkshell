import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// SSH：dartssh2 起交互式 shell（带 PTY），输出直接喂给 xterm。
class SshTerminalPage extends StatefulWidget {
  const SshTerminalPage({super.key});

  @override
  State<SshTerminalPage> createState() => _SshTerminalPageState();
}

class _SshTerminalPageState extends State<SshTerminalPage> {
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _pass = TextEditingController();

  final _term = Terminal(maxLines: 5000);
  SSHClient? _client;
  SSHSession? _shell;
  String _status = '未连接';

  @override
  void dispose() {
    _shell?.close();
    _client?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _status = '连接中…');
    try {
      final sock = await SSHSocket.connect(
        _host.text.trim(),
        int.tryParse(_port.text.trim()) ?? 22,
        timeout: const Duration(seconds: 8),
      );
      final client = SSHClient(
        sock,
        username: _user.text.trim(),
        onPasswordRequest: () => _pass.text,
      );
      final shell = await client.shell(pty: const SSHPtyConfig(width: 100, height: 32));
      _client = client;
      _shell = shell;
      shell.stdout.listen((data) => _term.write(utf8.decode(data, allowMalformed: true)));
      shell.stderr.listen((data) => _term.write(utf8.decode(data, allowMalformed: true)));
      _term.onOutput = (d) => shell.stdin.add(utf8.encode(d));
      setState(() => _status = '已连接 ${_host.text}:${_port.text}');
    } catch (e) {
      setState(() => _status = '失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Column(
            children: [
              Row(children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    decoration: const InputDecoration(labelText: 'host', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: 'port', isDense: true),
                  ),
                ),
              ]),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _user,
                    decoration: const InputDecoration(labelText: 'user', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _pass,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'password', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _shell == null ? _connect : null,
                  child: const Text('连接'),
                ),
              ]),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_status,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9AA7C7))),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TerminalView(
            _term,
            backgroundOpacity: 0,
            textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
