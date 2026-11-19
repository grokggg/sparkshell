import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'ssh/host_store.dart';

/// SSH 认证方式。UI 上二选一，决定连接时是用密码回调还是私钥 identities。
enum SshAuthType { password, key }

/// 主机指纹确认结果。对话框只能返回到这里三种状态之一。
enum _FpDecision { remember, once, cancel }

/// 私钥解析失败用的内部异常：把「用户能看懂的中文」和原始异常分开，
/// 避免把 PEM 内容或底层报错原样甩进对话框。
class _KeyProblem implements Exception {
  const _KeyProblem(this.message);

  final String message;
}

/// 一次连接所需的全部参数。
///
/// 密码 / 私钥口令只在这里（内存）存在，不写进 host_store 的 JSON；
/// 断线重连时直接复用这个对象，用户不用重新输入。
class _ConnParams {
  _ConnParams({
    required this.host,
    required this.port,
    required this.user,
    required this.auth,
    required this.password,
    required this.pem,
    required this.passphrase,
    required this.keyPath,
    required this.knownFingerprint,
    required this.remember,
  });

  final String host;
  final int port;
  final String user;
  final SshAuthType auth;
  final String password;
  final String pem;
  final String passphrase;
  final String? keyPath;

  /// 本地已记住的指纹，用来判断「首次 / 一致 / 变了」。
  final String? knownFingerprint;

  /// 连接成功后是否把这台主机写进 ssh_hosts.json。
  final bool remember;

  String get id => '$user@$host:$port';
}

/// 一条活跃连接。client 和 shell 绑定在一起，断开判断时用它做身份比对，
/// 防止旧连接的 done 回调把新连接误判成断开。
class _SshSession {
  _SshSession({required this.client, required this.shell});

  final SSHClient client;
  final SSHSession shell;
}

/// SSH 客户端：密码 / 私钥两种认证，主机指纹校验，保存主机，断线重连。
class SshTerminalPage extends StatefulWidget {
  const SshTerminalPage({super.key});

  @override
  State<SshTerminalPage> createState() => _SshTerminalPageState();
}

class _SshTerminalPageState extends State<SshTerminalPage> {
  /// 原生侧通道：pickAndImport 拉起系统文件选择器。
  /// （filesDir 由 SshHostStore 自己走 pty 通道取，这里不再重复声明。）
  static const _ioChannel = MethodChannel('sparkshell/io');

  /// 私钥导入到 rootfs 里的固定目录；Android 侧会复制到 filesDir/rootfs/root/sshkeys。
  static const _keyGuestDir = '/root/sshkeys';

  /// 私钥文本上限，超过就不像私钥了，也避免一次读几百 MB 进内存。
  static const _maxKeyBytes = 128 * 1024;

  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _pass = TextEditingController();
  final _pem = TextEditingController();
  final _passphrase = TextEditingController();

  final _term = Terminal(maxLines: 5000);
  final _store = SshHostStore();

  SshAuthType _auth = SshAuthType.password;
  bool _saveHost = true;
  bool _busy = false;

  /// 连接后自动把设置表单收起来，把手机屏幕让给终端。
  bool _showForm = true;

  List<SshHost> _hosts = const <SshHost>[];
  String? _selectedHostId;

  /// 私钥文件在 app 私有目录里的真实路径（不是 rootfs 内的 guest 路径）。
  String? _keyPath;

  /// 本次连接实际使用的主机指纹（SHA256:...），状态行展示用。
  String? _fingerprint;

  String _statusLine = '未连接';
  bool _disconnected = false;

  _SshSession? _session;
  _ConnParams? _lastParams;

  bool get _connected => _session != null;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHosts());
  }

  @override
  void dispose() {
    // 页面没了就把连接收掉，否则后台会留一条 keepalive 在跑。
    _term.onOutput = null;
    unawaited(_teardown());
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    _pem.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 保存主机

  Future<void> _loadHosts() async {
    final list = await _store.load();
    if (!mounted) return;
    setState(() => _hosts = list);
  }

  /// 把当前参数写入 ssh_hosts.json。
  ///
  /// [fingerprint] 只在「信任并记住」时传；普通保存主机时传 null 表示沿用旧指纹，
  /// 不能覆盖成 null，否则用户刚记住的指纹会被下一次连接抹掉。
  Future<void> _saveHostRecord(_ConnParams p, {String? fingerprint}) async {
    SshHost? old;
    for (final h in _hosts) {
      if (h.id == p.id) {
        old = h;
        break;
      }
    }
    final rec = SshHost(
      host: p.host,
      port: p.port,
      user: p.user,
      auth: p.auth == SshAuthType.key ? 'key' : 'password',
      keyPath: p.auth == SshAuthType.key ? p.keyPath : null,
      fingerprint: fingerprint ?? old?.fingerprint,
      updatedAt: DateTime.now().toIso8601String(),
    );
    await _store.upsert(rec);
    final list = await _store.load(force: true);
    if (!mounted) return;
    setState(() {
      _hosts = list;
      _selectedHostId = rec.id;
    });
  }

  Future<void> _deleteSelectedHost() async {
    final id = _selectedHostId;
    if (id == null) return;
    try {
      await _store.remove(id);
      final list = await _store.load(force: true);
      if (!mounted) return;
      setState(() {
        _hosts = list;
        _selectedHostId = null;
      });
      _toast('已删除保存的主机');
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  /// 选中一条保存的主机：把字段填回去，私钥从私有目录读回文本框。
  void _applyHost(SshHost h) {
    setState(() {
      _selectedHostId = h.id;
      _host.text = h.host;
      _port.text = '${h.port}';
      _user.text = h.user;
      _auth = h.useKey ? SshAuthType.key : SshAuthType.password;
      _keyPath = h.keyPath;
      _fingerprint = h.fingerprint;
      // 密码从不落盘，切换主机必须清空，避免串号。
      _pass.clear();
      _pem.clear();
      _passphrase.clear();
    });
    final path = h.keyPath;
    if (h.useKey && path != null) {
      unawaited(_loadKeyFromPath(path));
    }
  }

  Future<void> _loadKeyFromPath(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        _toast('私钥文件已不存在，请重新导入');
        return;
      }
      if (await f.length() > _maxKeyBytes) {
        _toast('文件太大，不像是私钥');
        return;
      }
      final text = await f.readAsString();
      if (!mounted) return;
      setState(() {
        _pem.text = text;
        _keyPath = path;
      });
    } catch (e) {
      // 只报文件层面的错误，绝不把 key 内容打进日志/提示。
      _toast('读私钥失败：$e');
    }
  }

  /// 用系统文件选择器挑一个文件，Android 侧会把它复制进 app 私有目录，
  /// 返回的是 rootfs 内的 guest 路径（见 MainActivity.importOne）。
  Future<void> _pickKeyFile() async {
    try {
      final res = await _ioChannel.invokeMethod<List<dynamic>>(
        'pickAndImport',
        <String, dynamic>{'destDir': _keyGuestDir},
      );
      final paths = (res ?? const <dynamic>[]).whereType<String>().toList();
      if (paths.isEmpty) {
        _toast('没有选择文件');
        return;
      }
      final dir = await _store.filesDir();
      if (dir == null) {
        _toast('读不到应用私有目录，请改为直接粘贴私钥内容');
        return;
      }
      final guest = paths.first;
      // importOne 是把文件写到 filesDir/rootfs/<guest>，这里反推出手机上的真实路径。
      final hostPath = '$dir/rootfs${guest.startsWith('/') ? '' : '/'}$guest';
      await _loadKeyFromPath(hostPath);
      if (!mounted) return;
      final name = hostPath.split('/').last;
      _toast(paths.length > 1 ? '已导入 ${paths.length} 个文件，使用 $name' : '已导入 $name');
    } on PlatformException catch (e) {
      _toast('选择私钥失败：${e.message ?? e.code}');
    } on MissingPluginException {
      _toast('当前平台不支持系统文件选择，请直接粘贴私钥');
    } catch (e) {
      _toast('选择私钥失败：$e');
    }
  }

  // ------------------------------------------------------------------ 连接

  _ConnParams? _collectParams() {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim());

    if (host.isEmpty) {
      _setError('请填写主机地址');
      return null;
    }
    if (port == null || port < 1 || port > 65535) {
      _setError('端口要在 1-65535 之间');
      return null;
    }
    if (user.isEmpty) {
      _setError('请填写用户名');
      return null;
    }
    if (_auth == SshAuthType.password && _pass.text.isEmpty) {
      _setError('请填写密码');
      return null;
    }
    if (_auth == SshAuthType.key && _pem.text.trim().isEmpty) {
      _setError('请粘贴私钥，或点「从文件导入」选私钥');
      return null;
    }

    return _ConnParams(
      host: host,
      port: port,
      user: user,
      auth: _auth,
      password: _auth == SshAuthType.password ? _pass.text : '',
      pem: _auth == SshAuthType.key ? _pem.text : '',
      passphrase: _auth == SshAuthType.key ? _passphrase.text : '',
      keyPath: _auth == SshAuthType.key ? _keyPath : null,
      knownFingerprint: _knownFingerprint(host, port, user),
      remember: _saveHost,
    );
  }

  String? _knownFingerprint(String host, int port, String user) {
    final id = '$user@$host:$port';
    for (final h in _hosts) {
      if (h.id == id) return h.fingerprint;
    }
    return null;
  }

  /// 解析 PEM。dartssh2 4.x 的 `SSHKeyPair.fromPem` 返回 **List**（一个文件里
  /// 可能有多把 key），不是单个对象；所有异常都翻译成中文，绝不外抛。
  List<SSHKeyPair> _parsePrivateKey(_ConnParams p) {
    final pem = p.pem.trim();
    if (pem.isEmpty) {
      throw const _KeyProblem('私钥内容为空');
    }

    // 先判断是否加密：没有口令时能给出「请填口令」这种可操作的提示，
    // 而不是笼统的「解析失败」。判断本身失败也无所谓，继续往下走。
    bool encrypted = false;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } catch (_) {}

    try {
      final keys = SSHKeyPair.fromPem(pem, p.passphrase.isEmpty ? null : p.passphrase);
      if (keys.isEmpty) {
        throw const _KeyProblem('这个私钥文件里没有可用的密钥');
      }
      return keys;
    } catch (e) {
      if (e is _KeyProblem) rethrow;
      if (encrypted && p.passphrase.isEmpty) {
        throw const _KeyProblem('这个私钥有口令保护，请填写「私钥口令」后再连接');
      }
      throw _KeyProblem(_keyProblemText(e));
    }
  }

  String _keyProblemText(Object e) {
    if (e is FormatException) {
      return '私钥解析失败：不是完整的 PEM 文本'
          '（要有 -----BEGIN ... PRIVATE KEY----- 和对应的 END 行）';
    }
    if (e is SSHKeyDecryptError) {
      return '私钥解密失败：口令不对，或私钥本身已损坏';
    }
    if (e is SSHKeyDecodeError) {
      return '私钥解析失败：内容损坏，或不是支持的私钥格式';
    }
    if (e is UnsupportedError) {
      final msg = e.message;
      if ('$msg'.contains('ENCRYPTED')) {
        return '不支持 PKCS#8 加密私钥，请用 ssh-keygen 转成 OpenSSH 格式';
      }
      return '不支持的私钥类型：$msg';
    }
    if (e is ArgumentError) {
      return '私钥解析失败：传入的内容不像私钥';
    }
    // 兜底不拼 e.toString()，避免某些底层异常把密钥片段带进 UI。
    return '私钥解析失败：${e.runtimeType}';
  }

  Future<void> _connect({_ConnParams? params}) async {
    if (_busy) return;
    final p = params ?? _collectParams();
    if (p == null) return;

    // 先解私钥：格式不对就没必要去连网，报错也更快。
    List<SSHKeyPair>? identities;
    if (p.auth == SshAuthType.key) {
      try {
        identities = _parsePrivateKey(p);
      } on _KeyProblem catch (e) {
        _setError(e.message);
        return;
      }
    }

    setState(() {
      _busy = true;
      _disconnected = false;
      _statusLine = params == null ? '连接中…' : '重新连接中…';
      _showForm = false;
    });

    await _teardown();

    SSHSocket? sock;
    try {
      sock = await SSHSocket.connect(
        p.host,
        p.port,
        timeout: const Duration(seconds: 8),
      );

      String? seenFingerprint;
      final client = SSHClient(
        sock,
        username: p.user,
        // 4.1.0 的参数名是 keepAliveInterval（不是 keepAlive），默认 10 秒；
        // 这里按需求显式设成 20 秒，走 transport 自带的 ping，不用自己开 Timer。
        keepAliveInterval: const Duration(seconds: 20),
        // 4.1.0 的签名是 (String type, Uint8List fingerprint)，
        // fingerprint 是 UTF-8 编码的 "SHA256:base64"（不是 32 字节裸摘要）。
        onVerifyHostKey: (String type, Uint8List fingerprint) async {
          final fp = _fingerprintToString(fingerprint);
          seenFingerprint = fp;
          return _confirmHostKey(
            type: type,
            fingerprint: fp,
            expected: p.knownFingerprint,
            p: p,
          );
        },
        identities: identities,
        // 密码只在这次连接的内存里用；私钥模式下不注册密码回调，
        // 服务器就不会把「密码」当成可用方法，认证失败也更明确。
        onPasswordRequest:
            p.auth == SshAuthType.password ? () => p.password : null,
      );

      // shell() 内部会等认证完成，这里再加一层超时，防止网络半死时一直转圈。
      final shell = await client
          .shell(pty: const SSHPtyConfig(width: 100, height: 32))
          .timeout(const Duration(seconds: 20));

      final session = _SshSession(client: client, shell: shell);
      _session = session;
      _lastParams = p;
      _fingerprint = seenFingerprint ?? p.knownFingerprint;

      shell.stdout.listen(
        (data) => _term.write(utf8.decode(data, allowMalformed: true)),
        onError: (_) {},
      );
      shell.stderr.listen(
        (data) => _term.write(utf8.decode(data, allowMalformed: true)),
        onError: (_) {},
      );

      _term.onOutput = (data) {
        try {
          shell.stdin.add(Uint8List.fromList(utf8.encode(data)));
        } catch (_) {
          // 断线后 sink 已关闭，吞掉异常，别让一次键盘输入把 app 打崩。
        }
      };

      // 两个 done 任一完成都表示连接结束：shell.done 是远端 shell 退出，
      // client.done 是整条 transport 断开（断网、被踢、keepalive 超时）。
      _watchDone(shell.done, session);
      _watchDone(client.done, session);

      if (!mounted) {
        // 连接过程中用户切走了页面：dispose 里的 _teardown 早跑过了，
        // 这条新连接没人管，必须在这里自己收掉，否则会留下一条常驻 keepalive。
        await _teardown();
        return;
      }
      setState(() {
        _busy = false;
        _statusLine = _connectedLine(p);
      });
      _term.write('\r\n\x1b[32m[已连接 ${p.host}:${p.port}]\x1b[0m\r\n');

      if (p.remember) {
        try {
          await _saveHostRecord(p);
        } catch (e) {
          _toast('主机没能保存：$e');
        }
      }
    } catch (e) {
      // 失败时把半开的 socket 收干净，否则下次连接会占到已失效的 fd。
      try {
        await sock?.close();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _disconnected = false;
        // 失败后把表单放出来，用户要改地址/密码才有地方改。
        _showForm = true;
        _statusLine = '连接失败：${_errorText(e, p)}';
      });
    }
  }

  /// 断线重连：完全复用上次成功连接的参数（含内存里的密码/PEM）。
  Future<void> _reconnect() async {
    final p = _lastParams;
    if (p == null) {
      _toast('没有上次的连接参数，请重新填写再连接');
      setState(() => _showForm = true);
      return;
    }
    await _connect(params: p);
  }

  Future<void> _disconnect() async {
    await _teardown();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _disconnected = false;
      _statusLine = '已断开';
    });
    _term.write('\r\n\x1b[33m[已断开]\x1b[0m\r\n');
  }

  DateTime? _lastDisconnectAt;

  void _watchDone(Future<void> done, _SshSession session) {
    done
        .then<void>((_) {}, onError: (Object e, StackTrace st) {})
        .whenComplete(() => _handleDisconnect(session));
  }

  void _handleDisconnect(_SshSession session) {
    // 身份比对：旧连接迟到的 done 不能影响新连接。
    if (!identical(_session, session)) return;
    _session = null;
    _term.onOutput = null;
    try {
      session.shell.close();
    } catch (_) {}
    unawaited(session.client.close());

    if (!mounted) return;
    // shell 退出和 client 断开可能几乎同时到，防一下重复提示。
    final now = DateTime.now();
    if (_lastDisconnectAt != null &&
        now.difference(_lastDisconnectAt!).inMilliseconds < 300) {
      return;
    }
    _lastDisconnectAt = now;
    setState(() {
      _busy = false;
      _disconnected = true;
      _statusLine = '连接已断开，点重连';
    });
    _term.write('\r\n\x1b[33m[连接已断开，可点底部「重连」]\x1b[0m\r\n');
  }

  Future<void> _teardown() async {
    final s = _session;
    _session = null;
    // 先摘掉输入回调，再关 sink；顺序反了终端里敲一个字就会往已关闭的流里写。
    _term.onOutput = null;
    if (s == null) return;
    try {
      s.shell.close();
    } catch (_) {}
    try {
      await s.client.close();
    } catch (_) {}
  }

  String _errorText(Object e, _ConnParams p) {
    if (e is SSHHostkeyError) return '主机指纹校验未通过，已取消连接';
    if (e is SSHAuthFailError) {
      return p.auth == SshAuthType.key ? '认证失败：这把私钥不被服务器接受' : '认证失败：用户名或密码不对';
    }
    if (e is SSHAuthError) return '认证失败：${e.message}';
    if (e is TimeoutException) return '连接超时，检查网络和端口';
    if (e is SocketException) return '连不上 ${p.host}:${p.port}（网络不可达或端口没开）';
    // 4.1.0 的 SSHSocketError 只暴露 error 字段（没有 message）。
    if (e is SSHSocketError) return '网络错误：${e.error}';
    if (e is SSHHandshakeError) return 'SSH 握手失败：${e.message}';
    return '$e';
  }

  // -------------------------------------------------------------- 主机指纹

  String _fingerprintToString(Uint8List raw) {
    try {
      final text = utf8.decode(raw);
      if (text.startsWith('SHA256:')) return text;
    } catch (_) {}
    // 兼容万一给了 32 字节裸摘要的版本：转成同样的 OpenSSH 写法。
    return 'SHA256:${base64.encode(raw).replaceAll('=', '')}';
  }

  /// 状态行只显示前 16 位，太长会把手机宽度撑爆。
  String _shortFingerprint(String fp) {
    final body = fp.startsWith('SHA256:') ? fp.substring(7) : fp;
    final head = body.length <= 16 ? body : body.substring(0, 16);
    return 'SHA256:$head';
  }

  /// 返回 true 表示放行。已记住且一致的指纹静默通过，等价于 known_hosts 命中。
  Future<bool> _confirmHostKey({
    required String type,
    required String fingerprint,
    required String? expected,
    required _ConnParams p,
  }) async {
    // 重连时 _ConnParams 是上一次连接时快照的，里面可能还没有刚记住的指纹；
    // 所以先看参数，再回查界面上的主机列表，避免「刚记住又弹一次」。
    final remembered = (expected != null && expected.isNotEmpty)
        ? expected
        : _knownFingerprint(p.host, p.port, p.user);
    final known = remembered != null && remembered.isNotEmpty;
    if (known && remembered == fingerprint) return true;
    if (!mounted) return false;

    final changed = known && remembered != fingerprint;
    final decision = await showDialog<_FpDecision>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text(changed ? '主机指纹已变化' : '确认主机指纹'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${p.host}:${p.port}'),
                const SizedBox(height: 10),
                Text('密钥类型：$type',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9AA7C7))),
                const SizedBox(height: 6),
                const Text('SHA256 指纹：', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                SelectableText(
                  fingerprint,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                if (changed) ...[
                  const SizedBox(height: 12),
                  Text(
                    '这台主机之前记录的指纹是：\n$remembered\n\n'
                    '如果服务器没重装过系统，指纹变化可能意味着有人在中间劫持连接。',
                    style: const TextStyle(fontSize: 12, color: Color(0xFFFF8A80)),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  const Text(
                    '首次连接没有参照，请自行核对指纹是否与服务器一致。',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9AA7C7)),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_FpDecision.cancel),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(_FpDecision.once),
              child: const Text('本次信任'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(_FpDecision.remember),
              child: Text(changed ? '更新并记住' : '信任并记住'),
            ),
          ],
        );
      },
    );

    if (decision == null || decision == _FpDecision.cancel) return false;

    if (decision == _FpDecision.remember) {
      // 「记住」与「保存主机」开关无关：用户点了记住就是要存指纹。
      try {
        await _saveHostRecord(p, fingerprint: fingerprint);
      } catch (e) {
        // 存不下不影响本次连接，但要告诉用户，否则下次还会再问。
        _toast('指纹没能写入本地：$e');
      }
    }
    return true;
  }

  String _connectedLine(_ConnParams p) {
    final authText = p.auth == SshAuthType.key ? '私钥认证' : '密码认证';
    final fp = _fingerprint;
    final fpText = fp == null || fp.isEmpty ? '指纹未知' : _shortFingerprint(fp);
    return '已连接 ${p.host}:${p.port} · $authText · $fpText';
  }

  // --------------------------------------------------------------- 小工具

  void _setError(String message) {
    if (!mounted) return;
    setState(() => _statusLine = message);
    _toast(message);
  }

  void _toast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 3),
    ));
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_showForm) _buildForm() else _buildCollapsedBar(),
        const Divider(height: 1),
        Expanded(
          child: TerminalView(
            _term,
            backgroundOpacity: 0,
            textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        _buildStatusBar(),
      ],
    );
  }

  Widget _buildCollapsedBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.terminal, size: 16, color: Color(0xFF9AA7C7)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${_user.text}@${_host.text}:${_port.text}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA7C7)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _showForm = true),
            child: const Text('设置'),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return ConstrainedBox(
      // 表单最多占 300 逻辑像素，键盘弹起或小屏时内部滚动，不挤压下面的终端。
      constraints: const BoxConstraints(maxHeight: 300),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSavedHostRow(),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                    labelText: 'host',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'port',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                    labelText: 'user',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<SshAuthType>(
                segments: const [
                  ButtonSegment(
                    value: SshAuthType.password,
                    label: Text('密码'),
                    icon: Icon(Icons.password, size: 16),
                  ),
                  ButtonSegment(
                    value: SshAuthType.key,
                    label: Text('私钥'),
                    icon: Icon(Icons.key, size: 16),
                  ),
                ],
                selected: {_auth},
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (s) {
                  if (s.isEmpty) return;
                  setState(() => _auth = s.first);
                },
              ),
            ]),
            const SizedBox(height: 6),
            if (_auth == SshAuthType.password)
              TextField(
                controller: _pass,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'password（只在本次连接内存里，不落盘）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _connect(),
              )
            else
              _buildKeySection(),
            const SizedBox(height: 4),
            Row(children: [
              Switch(
                value: _saveHost,
                onChanged: (v) => setState(() => _saveHost = v),
              ),
              const Text('保存主机', style: TextStyle(fontSize: 12)),
              const Spacer(),
              if (_connected)
                OutlinedButton(
                  onPressed: _disconnect,
                  child: const Text('断开'),
                )
              else
                FilledButton(
                  onPressed: _busy ? null : () => _connect(),
                  child: Text(_busy ? '连接中…' : '连接'),
                ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedHostRow() {
    final ids = _hosts.map((h) => h.id).toSet();
    final value = _selectedHostId != null && ids.contains(_selectedHostId)
        ? _selectedHostId
        : null;

    return Row(
      children: [
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              isDense: true,
              value: value,
              hint: const Text('已保存的主机', style: TextStyle(fontSize: 13)),
              items: [
                for (final h in _hosts)
                  DropdownMenuItem<String>(
                    value: h.id,
                    child: Text(
                      '${h.label}  ${h.auth == 'key' ? '私钥' : '密码'}',
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) {
                if (id == null) return;
                for (final h in _hosts) {
                  if (h.id == id) {
                    _applyHost(h);
                    return;
                  }
                }
              },
            ),
          ),
        ),
        if (value != null)
          IconButton(
            tooltip: '删除这条主机',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: _deleteSelectedHost,
          ),
        IconButton(
          tooltip: _showForm ? '收起设置' : '展开设置',
          visualDensity: VisualDensity.compact,
          icon: Icon(_showForm ? Icons.expand_less : Icons.expand_more, size: 20),
          onPressed: () => setState(() => _showForm = !_showForm),
        ),
      ],
    );
  }

  Widget _buildKeySection() {
    final keyName = _keyPath?.split('/').last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _pem,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          decoration: const InputDecoration(
            labelText: '私钥 PEM（粘贴 -----BEGIN ... PRIVATE KEY----- 全文）',
            isDense: true,
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _pickKeyFile,
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('从文件导入', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                // 只显示文件名，不显示完整路径里的用户目录细节。
                keyName ?? '未导入文件',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9AA7C7)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _passphrase,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '私钥口令（私钥没加密就留空）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    final Color dot;
    if (_connected) {
      dot = const Color(0xFF6BD98A);
    } else if (_disconnected) {
      dot = const Color(0xFFFFB86B);
    } else if (_busy) {
      dot = const Color(0xFF7DE2D1);
    } else {
      dot = const Color(0xFF5A6480);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: const BoxDecoration(
        color: Color(0xFF101733),
        border: Border(top: BorderSide(color: Color(0xFF1E2A4A))),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusLine,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA7C7)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_disconnected && !_busy)
            TextButton.icon(
              onPressed: _reconnect,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重连'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
        ],
      ),
    );
  }
}
