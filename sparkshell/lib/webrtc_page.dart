import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WebRTC 自检：同进程两条 PeerConnection 互连，建 DataChannel 收发消息。
/// 用来证明 WebRTC 栈（含 ICE/DTLS/SCTP）在设备上真实可用。
class WebRtcPage extends StatefulWidget {
  const WebRtcPage({super.key});

  @override
  State<WebRtcPage> createState() => _WebRtcPageState();
}

class _WebRtcPageState extends State<WebRtcPage> {
  final _log = <String>[];
  RTCPeerConnection? _a;
  RTCPeerConnection? _b;
  RTCDataChannel? _dc;
  bool _busy = false;

  void _say(String s) {
    setState(() => _log.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $s'));
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _log.clear();
    });
    try {
      final cfg = <String, dynamic>{
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'}
        ],
        'sdpSemantics': 'unified-plan',
      };
      final a = await createPeerConnection(cfg);
      final b = await createPeerConnection(cfg);
      _a = a;
      _b = b;

      a.onIceCandidate = (c) {
        if (c.candidate != null) b.addCandidate(c);
      };
      b.onIceCandidate = (c) {
        if (c.candidate != null) a.addCandidate(c);
      };
      b.onDataChannel = (ch) {
        _dc = ch;
        _say('B 收到 DataChannel: ${ch.label}');
        ch.messageStream.listen((m) => _say('B ← ${m.text}'));
      };

      final dc = await a.createDataChannel('spark-xfs1', RTCDataChannelInit());
      _dc = dc;
      dc.messageStream.listen((m) => _say('A ← ${m.text}'));
      dc.onDataChannelState = (s) => _say('A channel: $s');

      final offer = await a.createOffer();
      await a.setLocalDescription(offer);
      _say('offer 已生成 (${offer.sdp?.length ?? 0} 字节)');

      await b.setRemoteDescription(offer);
      final answer = await b.createAnswer();
      await b.setLocalDescription(answer);
      await a.setRemoteDescription(answer);
      _say('answer 已回填，等待 ICE/DTLS');

      // 等通道 open 再发消息
      for (var i = 0; i < 40; i++) {
        if (dc.state == RTCDataChannelState.RTCDataChannelOpen) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }
      _say('state = ${dc.state}');
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        dc.send(RTCDataChannelMessage('ping from A ${DateTime.now().millisecondsSinceEpoch}'));
        dc.send(RTCDataChannelMessage('XFS-1=020571c2…'));
      } else {
        _say('通道未打开（无网络/无 STUN 时正常）');
      }
    } catch (e) {
      _say('异常: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _dc?.close();
    _a?.close();
    _b?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              FilledButton.tonal(
                onPressed: _busy ? null : _run,
                child: Text(_busy ? '运行中…' : '跑 WebRTC 自检'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('同进程双 PeerConnection + DataChannel',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9AA7C7))),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _log.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(_log[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
        ),
      ],
    );
  }
}
