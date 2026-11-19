/// WebRTC 远程终端的纯逻辑层：信令客户端 + 一条 P2P 链接。
///
/// 这一层不碰 UI（不 import flutter/material），也不碰 PTY。
/// 页面上层拿到 [RtcLink]，用 [RtcLink.incoming] 收字节、[RtcLink.send] 发字节即可。
///
/// 数据通道的线格式（一条消息一个字符串）：
///   `d<base64>`   终端字节，base64 避免半截 UTF-8 多字节字符被写坏
///   `j<base64>`   控制/提示文本（JSON 或纯提示），只进 [RtcLink.states]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 信令层错误：带中文说明，页面直接显示。
class RtcSignalException implements Exception {
  RtcSignalException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次长轮询的结果。
class RtcPollResult {
  RtcPollResult(this.msgs, this.next, {this.closed = false});

  /// 本次新到的消息（已从 since 之后切片）。
  final List<Map<String, dynamic>> msgs;

  /// 下一次该带的游标。
  final int next;

  /// 房间已被关闭/过期，客户端应停止轮询。
  final bool closed;
}

/// HTTP 信令客户端。只依赖 dart:io（工程里没有 http 包）。
///
/// 服务端协议见 server/rtc_relay.py：
///   `POST base/room/<room>/<role>/<kind>`         -> 204
///   `GET  base/room/<room>/<role>/<kind>?since=`  -> `{"msgs":[...], "next":N}`
class RtcSignalClient {
  RtcSignalClient({
    required String base,
    required this.room,
    this.pollTimeout = const Duration(seconds: 45),
  }) : base = _normalize(base);

  /// 去掉末尾斜杠；没写协议就补 http://，免得上手先踩一次坑。
  static String _normalize(String raw) {
    var b = raw.trim();
    if (b.isEmpty) throw RtcSignalException('信令地址不能为空');
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'http://$b';
    }
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  final String base;

  /// 房间号，可在 join/host 前改写。
  String room;

  /// 长轮询的读超时，必须大于服务端的 25 秒挂起时间。
  final Duration pollTimeout;

  HttpClient? _http;

  HttpClient get _client {
    final c = _http;
    if (c != null) return c;
    final made = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 5);
    _http = made;
    return made;
  }

  Uri _uri(String role, String kind, {int? since}) {
    final u = Uri.parse('$base/room/$room/$role/$kind');
    if (since == null) return u;
    return u.replace(queryParameters: <String, String>{'since': '$since'});
  }

  /// 写入一条信令消息（offer/answer/ice）。
  Future<void> put(String role, String kind, Map<String, dynamic> data) async {
    final body = utf8.encode(jsonEncode(data));
    HttpClientRequest req;
    try {
      req = await _client
          .postUrl(_uri(role, kind))
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw RtcSignalException('连不上信令服务器 $base（10 秒超时）');
    } catch (e) {
      throw RtcSignalException('连不上信令服务器 $base：$e');
    }
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.connectionHeader, 'close');
    req.contentLength = body.length;
    req.add(body);

    HttpClientResponse resp;
    try {
      resp = await req.close().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw RtcSignalException('信令写入超时（$role/$kind）');
    } catch (e) {
      throw RtcSignalException('信令写入失败（$role/$kind）：$e');
    }
    final text = await utf8.decoder.bind(resp).join();
    if (resp.statusCode != 204 && resp.statusCode != 200) {
      throw RtcSignalException(
          '信令写入被拒绝 HTTP ${resp.statusCode}：${_short(text)}');
    }
  }

  /// 长轮询：没新消息就挂最多 25 秒，服务端一有新消息立刻返回。
  Future<RtcPollResult> poll(String role, String kind, {int since = 0}) async {
    HttpClientRequest req;
    try {
      req = await _client
          .getUrl(_uri(role, kind, since: since))
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw RtcSignalException('连不上信令服务器 $base（10 秒超时）');
    } catch (e) {
      throw RtcSignalException('连不上信令服务器 $base：$e');
    }
    req.headers.set(HttpHeaders.connectionHeader, 'close');

    HttpClientResponse resp;
    try {
      resp = await req.close().timeout(pollTimeout);
    } on TimeoutException {
      throw RtcSignalException('信令轮询超时（${pollTimeout.inSeconds} 秒没有响应）');
    } catch (e) {
      throw RtcSignalException('信令轮询中断：$e');
    }
    final text = await utf8.decoder.bind(resp).join();
    if (resp.statusCode != 200) {
      throw RtcSignalException(
          '信令轮询被拒绝 HTTP ${resp.statusCode}：${_short(text)}');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw RtcSignalException('信令返回不是 JSON：${_short(text)}');
    }
    if (decoded is! Map) {
      throw RtcSignalException('信令返回格式不对：${_short(text)}');
    }
    final msgs = <Map<String, dynamic>>[];
    final raw = decoded['msgs'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) msgs.add(Map<String, dynamic>.from(item));
      }
    }
    final n = decoded['next'];
    final next = n is num ? n.toInt() : since + msgs.length;
    return RtcPollResult(msgs, next, closed: decoded['closed'] == true);
  }

  /// 销毁房间（主机退出时调用），挂在上面的对端会被唤醒。
  Future<void> closeRoom() async {
    final body = utf8.encode('{}');
    try {
      final req = await _client
          .postUrl(Uri.parse('$base/room/$room/close'))
          .timeout(const Duration(seconds: 8));
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      req.contentLength = body.length;
      req.add(body);
      await req.close().timeout(const Duration(seconds: 8));
    } catch (_) {
      // 清理失败无所谓，房间 10 分钟后自己过期。
    }
  }

  void dispose() {
    _http?.close(force: true);
    _http = null;
  }

  static String _short(String s) {
    final t = s.trim();
    if (t.length <= 160) return t;
    return '${t.substring(0, 160)}…';
  }
}

/// 一个对端：主机可能同时挂多台手机，每台一个 [_Peer]。
class _Peer {
  _Peer(this.id);

  final String id;
  RTCPeerConnection? pc;
  RTCDataChannel? dc;
  bool remoteSet = false;
  bool open = false;

  /// 远端描述还没设好时先攒着候选，设好再补交。
  final List<RTCIceCandidate> pending = <RTCIceCandidate>[];
}

/// 一条 P2P 链接：主机侧 [host]，客户端侧 [join]，SDP/ICE 全自动交换。
class RtcLink {
  RtcLink({
    required String base,
    required String room,
    List<Map<String, dynamic>>? iceServers,
  })  : _signal = RtcSignalClient(base: base, room: room),
        _iceServers = iceServers ??
            const <Map<String, dynamic>>[
              <String, dynamic>{'urls': 'stun:stun.l.google.com:19302'},
              <String, dynamic>{'urls': 'stun:stun1.l.google.com:19302'},
            ];

  final RtcSignalClient _signal;
  final List<Map<String, dynamic>> _iceServers;

  final Map<String, _Peer> _peers = <String, _Peer>{};

  final StreamController<String> _states =
      StreamController<String>.broadcast();
  final StreamController<String> _incoming =
      StreamController<String>.broadcast();
  final StreamController<List<int>> _incomingBytes =
      StreamController<List<int>>.broadcast();

  /// 把字节流按 UTF-8 增量解码：跨消息被劈开的多字节汉字不会变成乱码。
  late final ByteConversionSink _textSink =
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(
    StringConversionSink.withCallback((String chunk) {
      if (!_incoming.isClosed) _incoming.add(chunk);
    }),
  );

  bool _isHost = false;
  bool _closed = false;
  bool _polling = true;
  bool _answerLoop = false;
  bool _iceLoop = false;
  int _peerSeq = 0;
  String? _lastIceState;

  String get room => _signal.room;
  bool get isHost => _isHost;
  bool get isClosed => _closed;

  /// 已连上的手机台数。
  int get connectedPeers => _peers.values.where((p) => p.open).length;

  /// 状态文本流（中文），页面底部直接显示。
  Stream<String> get states => _states.stream;

  /// 收到的终端输出（已按 UTF-8 解码）。
  Stream<String> get incoming => _incoming.stream;

  /// 收到的原始字节（主机写 PTY 用，二进制更安全）。
  Stream<List<int>> get incomingBytes => _incomingBytes.stream;

  void _emit(String text) {
    if (_states.isClosed) return;
    _states.add(text);
  }

  // ------------------------------------------------------------- 主机
  /// 作为主机开房：发布 offer，等客户端来答。
  Future<void> host([String? room]) async {
    if (_closed) throw RtcSignalException('链接已关闭，请重新创建');
    if (room != null && room.trim().isNotEmpty) {
      _signal.room = room.trim();
    }
    _isHost = true;
    _polling = true;
    _emit('房间 ${_signal.room}：正在创建主机…');
    await _spawnHostPeer();
    _startPolls();
  }

  /// 再发一个 offer，允许第二台手机加入（v1 默认只等一台，按需调用）。
  Future<void> addGuest() async {
    if (!_isHost) throw RtcSignalException('只有主机才能加手机');
    if (_peers.values.where((p) => p.open).length >= 4) {
      throw RtcSignalException('最多 4 台手机');
    }
    _polling = true;
    _startPolls();
    await _spawnHostPeer();
  }

  Future<void> _spawnHostPeer() async {
    final id = 'h${++_peerSeq}-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final peer = _Peer(id);
    _peers[id] = peer;

    final pc = await _newPeerConnection(peer);
    peer.pc = pc;

    final dc = await pc.createDataChannel('spark-terminal', RTCDataChannelInit());
    peer.dc = dc;
    _bindChannel(peer, dc);

    _emit('正在生成本机 offer…');
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await _signal.put('host', 'offer', <String, dynamic>{
      'peer': id,
      'type': 'offer',
      'sdp': offer.sdp ?? '',
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    _emit('offer 已发布，等客户端加入（房间 ${_signal.room}）');
  }

  // ------------------------------------------------------------- 客户端
  /// 作为客户端加入房间：等主机 offer，回 answer。
  Future<void> join([String? room]) async {
    if (_closed) throw RtcSignalException('链接已关闭，请重新加入');
    if (room != null && room.trim().isNotEmpty) {
      _signal.room = room.trim();
    }
    _isHost = false;
    _polling = true;
    _emit('房间 ${_signal.room}：等待主机 offer…');

    Map<String, dynamic>? offer;
    var since = 0;
    var waits = 0;
    while (!_closed && offer == null) {
      final r = await _signal.poll('host', 'offer', since: since);
      since = r.next;
      if (r.closed) {
        throw RtcSignalException('房间已关闭，请让主机重新创建');
      }
      if (r.msgs.isNotEmpty) {
        // 主机可能挂着多个待配对 offer（addGuest），取最新那个。
        offer = r.msgs.last;
        break;
      }
      waits++;
      if (waits % 4 == 0) {
        _emit('还没收到 offer（房间号 ${_signal.room} 对吗？）');
      }
    }
    if (offer == null) throw RtcSignalException('已取消');

    final id = (offer['peer'] as String?) ?? 'h1';
    final sdp = (offer['sdp'] as String?) ?? '';
    if (sdp.isEmpty) throw RtcSignalException('主机 offer 是空的');

    final peer = _Peer(id);
    _peers[id] = peer;
    _emit('收到 offer，正在交换 SDP…');

    final pc = await _newPeerConnection(peer);
    peer.pc = pc;
    _startPolls();

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    peer.remoteSet = true;
    _flushPending(peer);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await _signal.put('guest', 'answer', <String, dynamic>{
      'peer': id,
      'type': 'answer',
      'sdp': answer.sdp ?? '',
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    _emit('answer 已回传，正在打洞…');
  }

  // ------------------------------------------------------------- 连接
  Future<RTCPeerConnection> _newPeerConnection(_Peer peer) async {
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });

    pc.onIceCandidate = (RTCIceCandidate c) {
      final cand = c.candidate;
      if (cand == null || cand.isEmpty) return;
      _postIce(peer, cand, c.sdpMid, c.sdpMLineIndex).catchError((Object e) {
        _emit('候选发送失败：$e');
      });
    };

    pc.onIceConnectionState = (RTCIceConnectionState s) {
      final text = _iceText(s);
      if (text != _lastIceState) {
        _lastIceState = text;
        _emit(text);
      }
      if (s == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          s == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _maybeStopPolls();
      }
    };

    pc.onConnectionState = (RTCPeerConnectionState s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _emit('连接失败：可能双方都在对称 NAT 后面（需要 TURN）');
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _emit('连接断开，等待恢复…');
      }
    };

    // 客户端会从这条回调拿到主机建的通道
    pc.onDataChannel = (RTCDataChannel ch) {
      peer.dc = ch;
      _bindChannel(peer, ch);
    };
    return pc;
  }

  Future<void> _postIce(
      _Peer peer, String candidate, String? mid, int? index) {
    return _signal.put(_isHost ? 'host' : 'guest', 'ice', <String, dynamic>{
      'peer': peer.id,
      'candidate': candidate,
      'sdpMid': mid ?? '',
      'sdpMLineIndex': index ?? 0,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _bindChannel(_Peer peer, RTCDataChannel dc) {
    dc.onDataChannelState = (RTCDataChannelState s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        peer.open = true;
        _emit('通道已打开');
        if (_isHost) {
          _emit('已连接手机 $connectedPeers 台');
        } else {
          _emit('已连上主机，可以操作远端终端了');
        }
        _maybeStopPolls();
      } else if (s == RTCDataChannelState.RTCDataChannelClosed ||
          s == RTCDataChannelState.RTCDataChannelClosing) {
        peer.open = false;
        _emit('通道已关闭');
      }
    };
    dc.messageStream.listen(
      (RTCDataChannelMessage m) => _onMessage(m.text),
      onError: (Object e) {
        _emit('通道错误：$e');
      },
    );
  }

  void _onMessage(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final tag = raw.substring(0, 1);
    final payload = raw.substring(1);
    if (tag == 'd') {
      List<int> bytes;
      try {
        bytes = base64.decode(payload);
      } catch (e) {
        _emit('收到损坏的数据帧：$e');
        return;
      }
      if (!_incomingBytes.isClosed) _incomingBytes.add(bytes);
      if (!_incoming.isClosed) _textSink.add(bytes);
      return;
    }
    if (tag == 'j') {
      try {
        _emit(utf8.decode(base64.decode(payload), allowMalformed: true));
      } catch (e) {
        _emit('收到对端提示（解码失败）：$e');
      }
      return;
    }
    // 兼容裸文本（手工调试 nc 时用得上）
    if (!_incoming.isClosed) _incoming.add(raw);
  }

  /// 发一段终端数据给所有已连上的对端。
  void send(String data) => sendBytes(utf8.encode(data));

  /// 发原始字节（主机转发 PTY 输出时用它，避免二次编解码）。
  void sendBytes(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    _broadcast('d${base64.encode(bytes)}');
  }

  /// 发一条提示文本（只进对端的状态流，不写终端）。
  void sendNotice(String text) {
    if (_closed) return;
    _broadcast('j${base64.encode(utf8.encode(text))}');
  }

  bool _broadcast(String msg) {
    var sent = 0;
    for (final p in _peers.values) {
      final dc = p.dc;
      if (dc == null || !p.open) continue;
      try {
        dc.send(RTCDataChannelMessage(msg)).catchError((Object e) {
          _emit('发送失败：$e');
        });
        sent++;
      } catch (e) {
        _emit('发送失败：$e');
      }
    }
    return sent > 0;
  }

  // ------------------------------------------------------------- 轮询
  void _startPolls() {
    if (_closed) return;
    _polling = true;
    if (_isHost && !_answerLoop) {
      _answerLoop = true;
      unawaited(_loopAnswers());
    }
    if (!_iceLoop) {
      _iceLoop = true;
      unawaited(_loopIce(_isHost ? 'guest' : 'host'));
    }
  }

  /// 连接建立且没有待配对 offer 时停掉长轮询，省电省流量。
  void _maybeStopPolls() {
    if (_closed) return;
    if (!_isHost) {
      if (connectedPeers > 0) _polling = false;
      return;
    }
    final pending = _peers.values.any((p) => !p.open);
    if (connectedPeers > 0 && !pending) _polling = false;
  }

  Future<void> _loopAnswers() async {
    var since = 0;
    while (!_closed && _polling) {
      try {
        final r = await _signal.poll('guest', 'answer', since: since);
        since = r.next;
        for (final m in r.msgs) {
          await _applyAnswer(m);
        }
        if (r.closed) {
          _emit('房间已被主机关闭');
          break;
        }
      } catch (e) {
        if (_closed || !_polling) break;
        _emit('$e');
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    _answerLoop = false;
  }

  Future<void> _loopIce(String remoteRole) async {
    var since = 0;
    while (!_closed && _polling) {
      try {
        final r = await _signal.poll(remoteRole, 'ice', since: since);
        since = r.next;
        for (final m in r.msgs) {
          await _applyIce(m);
        }
        if (r.closed) break;
      } catch (e) {
        if (_closed || !_polling) break;
        _emit('$e');
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    _iceLoop = false;
  }

  Future<void> _applyAnswer(Map<String, dynamic> m) async {
    final id = (m['peer'] as String?) ?? '';
    final peer = _peers[id];
    if (peer == null || peer.pc == null || peer.remoteSet) return;
    final sdp = (m['sdp'] as String?) ?? '';
    if (sdp.isEmpty) return;
    try {
      await peer.pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      peer.remoteSet = true;
      _emit('收到 answer，正在打洞…');
      await _flushPending(peer);
    } catch (e) {
      _emit('设置 answer 失败：$e');
    }
  }

  Future<void> _applyIce(Map<String, dynamic> m) async {
    final id = (m['peer'] as String?) ?? '';
    final peer = _peers[id];
    final cand = (m['candidate'] as String?) ?? '';
    if (peer == null || peer.pc == null || cand.isEmpty) return;
    final c = RTCIceCandidate(
      cand,
      (m['sdpMid'] as String?) ?? '',
      (m['sdpMLineIndex'] as num?)?.toInt() ?? 0,
    );
    if (!peer.remoteSet) {
      peer.pending.add(c);
      return;
    }
    try {
      await peer.pc!.addCandidate(c);
    } catch (e) {
      _emit('加候选失败：$e');
    }
  }

  Future<void> _flushPending(_Peer peer) async {
    if (peer.pending.isEmpty) return;
    final list = List<RTCIceCandidate>.from(peer.pending);
    peer.pending.clear();
    for (final c in list) {
      try {
        await peer.pc?.addCandidate(c);
      } catch (_) {
        // 单个候选无效不影响其它候选
      }
    }
  }

  static String _iceText(RTCIceConnectionState s) {
    switch (s) {
      case RTCIceConnectionState.RTCIceConnectionStateNew:
        return 'ICE 新建';
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        return 'ICE 检查中…';
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        return 'ICE 已连上';
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        return 'ICE 失败（对称 NAT/防火墙，需要 TURN）';
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        return 'ICE 断开';
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        return 'ICE 已关闭';
      default:
        return 'ICE 状态 $s';
    }
  }

  // ------------------------------------------------------------- 收尾
  /// 关闭链接并释放所有 peer / 流。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _polling = false;

    for (final p in _peers.values.toList()) {
      try {
        await p.dc?.close();
      } catch (_) {}
      try {
        await p.pc?.close();
      } catch (_) {}
    }
    _peers.clear();

    try {
      _textSink.close(); // ByteConversionSink.close() 返回 void
    } catch (_) {}
    _signal.dispose();

    if (!_incoming.isClosed) await _incoming.close();
    if (!_incomingBytes.isClosed) await _incomingBytes.close();
    if (!_states.isClosed) await _states.close();
  }

  /// 主动销毁服务端房间（主机退出时调用，客户端会立刻收到"已关闭"）。
  Future<void> closeRoom() => _signal.closeRoom();
}
