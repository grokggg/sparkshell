/// WebRTC 远程终端页。
///
/// 主机（host）：把本机 PTY（容器里的 bash）接到 DataChannel 上，别的手机连进来就能敲。
/// 客户端（guest）：一个 xterm 终端，键盘输入经 DataChannel 送回主机。
///
/// 只依赖 lib/webrtc/rtc_remote.dart 与工程的 PTY 通道，不碰 main.dart。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../linux_env.dart';
import 'rtc_remote.dart';

class RtcRemotePage extends StatefulWidget {
  const RtcRemotePage({super.key});

  @override
  State<RtcRemotePage> createState() => _RtcRemotePageState();
}

class _RtcRemotePageState extends State<RtcRemotePage> {
  static const _ch = MethodChannel('com.xinghuo.sparkshell/pty');
  static const _maxLog = 200;

  final _baseCtrl =
      TextEditingController(text: 'https://discretion-stated-bargain-expect.trycloudflare.com/rtc');
  final _roomCtrl = TextEditingController(text: _randomRoom());

  final _term = Terminal(maxLines: 5000);
  final _log = <String>[];
  final _subs = <StreamSubscription<dynamic>>[];

  RtcLink? _link;
  String? _role; // 'host' / 'guest' / null
  bool _busy = false;
  bool _connected = false;
  int _peers = 0;
  String _status = '未连接';

  int _fd = -1;
  Timer? _pump;

  static String _randomRoom() {
    final r = Random();
    return '${100000 + r.nextInt(900000)}';
  }

  @override
  void dispose() {
    _pump?.cancel();
    _pump = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final link = _link;
    _link = null;
    if (link != null) unawaited(link.close());
    final fd = _fd;
    _fd = -1;
    if (fd >= 0) unawaited(_closeFd(fd));
    _term.onOutput = null;
    _baseCtrl.dispose();
    _roomCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 日志
  void _pushLog(String s) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    _log.add('$t  $s');
    while (_log.length > _maxLog) {
      _log.removeAt(0);
    }
  }

  void _fail(String msg) {
    _pushLog('✗ $msg');
    if (!mounted) return;
    setState(() {
      _err = msg;
      _status = msg;
    });
  }

  String? _err;

  // ------------------------------------------------------------------ 启动
  Future<void> _start({required bool isHost}) async {
    if (_busy) return;
    final base = _baseCtrl.text.trim();
    final room = _roomCtrl.text.trim();
    if (base.isEmpty) {
      _fail('信令地址不能为空');
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(room)) {
      _fail('房间号只能用字母、数字、下划线、减号（1–64 位）');
      return;
    }

    await _teardown();
    if (!mounted) return;
    setState(() {
      _busy = true;
      _err = null;
      _role = isHost ? 'host' : 'guest';
      _connected = false;
      _peers = 0;
      _status = isHost ? '正在启动主机…' : '正在加入房间…';
      _log.clear();
    });
    _term.write('\x1b[2J\x1b[H');

    final link = RtcLink(base: base, room: room);
    _link = link;
    _subs.add(link.states.listen(_onState));
    _subs.add(link.incoming.listen(
      (s) => _term.write(s),
      onError: (Object e) => _fail('接收数据出错：$e'),
    ));
    if (isHost) {
      // 主机：对端发来的原始字节直接灌回本机 PTY
      _subs.add(link.incomingBytes.listen(
        (b) => _writePty(b),
        onError: (Object e) => _fail('接收数据出错：$e'),
      ));
    }

    try {
      if (isHost) {
        await _openPty();
        // 主机自己也能在本地敲（输出会同时发给了所有连上的手机）
        _term.onOutput = (data) => _writePty(utf8.encode(data));
        await link.host();
        _term.write('\r\n\x1b[36m[远程终端] 主机已就绪，房间 ${link.room}\x1b[0m\r\n');
      } else {
        _term.write('\r\n\x1b[36m[远程终端] 正在连接 ${link.room}…\x1b[0m\r\n');
        await link.join();
        // 客户端：键盘输入原样发给主机
        _term.onOutput = (data) {
          link.send(data);
        };
      }
    } catch (e) {
      _fail('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onState(String s) {
    _pushLog(s);
    if (!mounted) return;
    setState(() {
      _status = s;
      _peers = _link?.connectedPeers ?? _peers;
      if (s.contains('通道已打开')) {
        _connected = true;
        _err = null;
      }
      if (s.contains('通道已关闭') ||
          s.contains('连接断开') ||
          s.contains('连接失败') ||
          s.contains('ICE 失败')) {
        _connected = false;
      }
    });
  }

  Future<void> _teardown() async {
    _pump?.cancel();
    _pump = null;
    final subs = List<StreamSubscription<dynamic>>.from(_subs);
    _subs.clear();
    for (final s in subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    final link = _link;
    _link = null;
    final wasHost = _role == 'host';
    if (link != null) {
      if (wasHost) {
        try {
          await link.closeRoom();
        } catch (_) {}
      }
      try {
        await link.close();
      } catch (_) {}
    }
    final fd = _fd;
    _fd = -1;
    if (fd >= 0) await _closeFd(fd);
    _term.onOutput = null;
  }

  Future<void> _closeFd(int fd) async {
    try {
      await _ch.invokeMethod('close', <String, dynamic>{'fd': fd});
    } catch (_) {}
  }

  Future<void> _stop() async {
    await _teardown();
    if (!mounted) return;
    setState(() {
      _role = null;
      _connected = false;
      _peers = 0;
      _status = '已断开';
      _busy = false;
    });
  }

  // ------------------------------------------------------------------ PTY
  Future<void> _openPty() async {
    var shell = '/system/bin/sh';
    try {
      final resolved = await LinuxEnv.instance.ensureReady((m) {
        _pushLog(m);
        if (mounted) setState(() => _status = m);
      });
      if (resolved != null && resolved.isNotEmpty) {
        shell = resolved;
      } else {
        _pushLog('容器没起来，退回系统 shell');
      }
    } catch (e) {
      _pushLog('容器启动失败，退回系统 shell：$e');
    }
    final fd = await _ch.invokeMethod<int>('open', <String, dynamic>{'shell': shell});
    _fd = fd ?? -1;
    if (_fd < 0) {
      throw StateError('PTY 打开失败（fd=$_fd）');
    }
    _pushLog('PTY 已打开 fd=$_fd → $shell');
    _pump = Timer.periodic(const Duration(milliseconds: 40), (_) => _drain());
  }

  Future<void> _drain() async {
    final fd = _fd;
    if (fd < 0) return;
    try {
      final res =
          await _ch.invokeMethod<Uint8List>('read', <String, dynamic>{'fd': fd, 'max': 8192});
      if (res == null || res.isEmpty) return;
      _term.write(utf8.decode(res, allowMalformed: true));
      _link?.sendBytes(res);
    } catch (e) {
      _pump?.cancel();
      _pump = null;
      _fail('PTY 读取失败：$e');
    }
  }

  Future<void> _writePty(List<int> bytes) async {
    final fd = _fd;
    if (fd < 0 || bytes.isEmpty) return;
    try {
      await _ch.invokeMethod('write', <String, dynamic>{
        'fd': fd,
        'data': Uint8List.fromList(bytes),
      });
    } catch (e) {
      _fail('写入 PTY 失败：$e');
    }
  }

  void _sendKeys(String seq) {
    if (_role == 'host') {
      _writePty(utf8.encode(seq));
    } else if (_role == 'guest') {
      _link?.send(seq);
    }
  }

  Future<void> _addGuest() async {
    final link = _link;
    if (link == null) return;
    try {
      await link.addGuest();
    } catch (e) {
      _fail('$e');
    }
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildForm(),
        _buildStatusBar(),
        if (_err != null) _buildError(),
        Expanded(child: _buildBody()),
        if (_role != null) _buildKeyBar(),
      ],
    );
  }

  Widget _buildForm() {
    final locked = _role != null;
    return Container(
      color: const Color(0xFF0E1526),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                width: 62,
                child: Text('信令', style: TextStyle(fontSize: 12, color: Color(0xFF9AA7C7))),
              ),
              Expanded(
                child: TextField(
                  controller: _baseCtrl,
                  enabled: !locked && !_busy,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'http://IP:8899',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(
                width: 62,
                child: Text('房间号', style: TextStyle(fontSize: 12, color: Color(0xFF9AA7C7))),
              ),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _roomCtrl,
                  enabled: !locked && !_busy,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (!locked)
                IconButton(
                  tooltip: '换一个随机房间号',
                  onPressed: _busy ? null : () => setState(() => _roomCtrl.text = _randomRoom()),
                  icon: const Icon(Icons.casino_outlined, size: 18),
                ),
              const Spacer(),
              if (!locked) ...[
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _start(isHost: true),
                  child: const Text('创建（主机）'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : () => _start(isHost: false),
                  child: const Text('加入（客户端）'),
                ),
              ] else
                OutlinedButton.icon(
                  onPressed: _busy ? null : _stop,
                  icon: const Icon(Icons.link_off, size: 16),
                  label: const Text('断开'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    final color = _err != null
        ? const Color(0xFFFF7A7A)
        : (_connected ? const Color(0xFF7DE2D1) : const Color(0xFF9AA7C7));
    return Container(
      color: const Color(0xFF111A33),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(
            _connected ? Icons.link : Icons.link_off,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _busy ? '$_status …' : _status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
          if (_role == 'host')
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '手机 $_peers 台',
                style: const TextStyle(fontSize: 12, color: Color(0xFF7DE2D1)),
              ),
            ),
          if (_role == 'host' && _connected)
            TextButton(
              onPressed: _addGuest,
              child: const Text('再加一台', style: TextStyle(fontSize: 12)),
            ),
          if (_role != null && !_connected && !_busy)
            TextButton(
              onPressed: () => _start(isHost: _role == 'host'),
              child: const Text('重连', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Container(
      width: double.infinity,
      color: const Color(0x33FF5252),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFFF7A7A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _err ?? '',
              style: const TextStyle(fontSize: 12, color: Color(0xFFFF9C9C)),
            ),
          ),
          IconButton(
            tooltip: '收起',
            onPressed: () => setState(() => _err = null),
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_role == null) {
      return _log.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '一台手机点「创建（主机）」，另一台填同一个房间号点「加入（客户端）」。\n'
                  '主机共享的是本机的容器终端；两台手机需要先能访问同一个信令地址。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Color(0xFF9AA7C7)),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  _log[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            );
    }
    return Container(
      color: const Color(0xFF0B1220),
      child: TerminalView(
        _term,
        autofocus: _role == 'guest',
        backgroundOpacity: 0,
        textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
      ),
    );
  }

  Widget _buildKeyBar() {
    return Container(
      color: const Color(0xFF111A33),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _key('⏎ 回车', '\r'),
          _key('Tab', '\t'),
          _key('Ctrl-C', '\x03'),
          _key('Ctrl-D', '\x04'),
          _key('清屏', '\x0c'),
          const Spacer(),
          const Text(
            '中文输入法可能吃掉回车，用按钮兜底',
            style: TextStyle(fontSize: 10, color: Color(0xFF6B7899)),
          ),
        ],
      ),
    );
  }

  Widget _key(String label, String seq) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: OutlinedButton(
        onPressed: () => _sendKeys(seq),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 30),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      ),
    );
  }
}
