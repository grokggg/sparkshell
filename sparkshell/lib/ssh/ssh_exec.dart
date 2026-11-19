// SSH 命令执行层：给 Agent 的「在远端主机上跑一条命令」能力。
//
// 这里刻意不依赖任何 Flutter UI（不 import material/widgets）：
// 只在 execOnSaved 里用到 SshHostStore（它内部走 MethodChannel 读主机列表），
// 这样同一段逻辑既能被 Agent 工具调用，也能在纯 Dart 测试里跑。
//
// 安全约定（重要）：
//  - 密码 / 私钥 / 口令只作为参数在内存里传递，绝不写进异常文案、日志或返回值；
//  - 指纹不匹配时直接拒绝连接，不做「先连上再说」；
//  - 每条命令用一条独立连接，用完立刻关掉，不在后台留 keepalive。
//
// 典型用法：
//   final r = await SshExec().exec(
//     host: '10.0.0.5', user: 'root', privateKeyPem: pem, command: 'uname -a');
//   if (!r.ok) ... r.exitCode / r.brief
//   final r2 = await SshExec().execOnSaved('root@10.0.0.5:22', 'df -h');

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'host_store.dart';

/// 所有对外错误都收敛成这一种异常：message 一定是一句能直接给用户看的中文。
///
/// 为什么不直接把底层异常抛出去：dartssh2 的异常里可能带 PEM 片段、服务器
/// 原始报文，Agent 会把它原样回显到聊天里，等于把私钥/口令泄露给模型。
class SshException implements Exception {
  const SshException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次远端命令执行的结果。
///
/// [exitCode] 为 -1 表示服务器没有上报退出码（少数精简版 sshd）。
/// [fingerprint] 是本次连接实际看到的主机指纹，只在调用方没传期望指纹时用于
/// 「首次连接」的 TOFU 展示；本层不落盘，是否记住由上层决定。
class SshExecResult {
  const SshExecResult({
    required this.ok,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.ms,
    this.fingerprint,
  });

  final bool ok;
  final int exitCode;
  final String stdout;
  final String stderr;

  /// 从发起到命令结束的耗时（毫秒），方便模型判断命令是不是慢。
  final int ms;

  final String? fingerprint;

  /// 单次 brief 的上限。4000 字符大约是 1k~2k token，
  /// 足够模型看懂报错，又不至于一条 `yes` 把上下文撑爆。
  static const int _briefLimit = 4000;

  /// 给模型看的一行摘要：退出码 + 耗时 + 输出（过长截断）。
  String get brief {
    final buf = StringBuffer()
      ..write('exit=$exitCode  ${ok ? '成功' : '失败'}  ${ms}ms');
    if (stdout.trim().isNotEmpty) {
      buf.write('\n${stdout.trimRight()}');
    }
    if (stderr.trim().isNotEmpty) {
      buf.write('\n[stderr] ${stderr.trimRight()}');
    }
    final text = buf.toString();
    if (text.length <= _briefLimit) return text;

    // 不要从代理对中间切（emoji、部分生僻字），否则会留下半个字符。
    var cut = _briefLimit;
    final unit = text.codeUnitAt(cut - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) cut -= 1;
    return '${text.substring(0, cut)}\n…（输出过长，已截断：共 ${text.length} 字符）';
  }
}

/// 在 SSH 主机上执行单条命令。
///
/// 每次 [exec] 都新建连接再关闭：Agent 的命令是零散的，复用长连接要处理
/// 断线重连、并发串行化，收益不值得；反而一条挂死的连接会让后面的命令全超时。
class SshExec {
  SshExec({Duration? timeout, SshHostStore? store})
      : _connectTimeout = timeout ?? const Duration(seconds: 10),
        _store = store ?? SshHostStore();

  /// TCP 连接（含 DNS）超时。握手/认证的时间由 [exec] 的 timeoutSeconds 兜住。
  final Duration _connectTimeout;

  /// 已保存主机的读取入口，只在 [execOnSaved] / [aliases] 用到。
  final SshHostStore _store;

  /// 私钥文件大小上限：超过这个量级基本不是私钥，也避免一次读几十 MB 进内存。
  static const int _maxKeyBytes = 128 * 1024;

  // ------------------------------------------------------------------ 执行

  /// 直连执行：[host] 是 IP 或域名，认证二选一（密码 / 私钥）。
  ///
  /// [fingerprint] 传了就只接受完全一致的主机指纹；不传则按首次连接（TOFU）
  /// 放行，并把实际指纹放进 [SshExecResult.fingerprint] 回传，由上层决定是否记住。
  ///
  /// [timeoutSeconds] 覆盖「连接 + 认证 + 命令执行 + 收尾」的总时长，
  /// 超时会主动关掉连接并抛 [SshException]（中文提示）。
  Future<SshExecResult> exec({
    required String host,
    required String user,
    int port = 22,
    String? password,
    String? privateKeyPem,
    String? passphrase,
    String? fingerprint,
    required String command,
    int timeoutSeconds = 60,
  }) async {
    final target = host.trim();
    final login = user.trim();
    final hasPassword = password != null && password.isNotEmpty;
    final hasKey = privateKeyPem != null && privateKeyPem.trim().isNotEmpty;

    // 参数错误在联网前就报掉：既省一次握手，也让模型拿到可操作的提示。
    if (target.isEmpty) throw const SshException('主机地址不能为空');
    if (login.isEmpty) throw const SshException('用户名不能为空');
    if (command.trim().isEmpty) throw const SshException('命令不能为空');
    if (port < 1 || port > 65535) throw const SshException('端口要在 1-65535 之间');
    if (timeoutSeconds <= 0) throw const SshException('超时时间必须大于 0 秒');
    if (!hasPassword && !hasKey) {
      throw const SshException('没有可用的认证方式：请提供密码或私钥');
    }

    // 私钥先解析：格式/口令不对时立刻报错，不要连上服务器再被拒一次。
    // 解析失败的消息里只有「格式/口令」层面的描述，不会带出 PEM 内容。
    final identities = hasKey ? _parseKey(privateKeyPem, passphrase) : null;
    final expectedFp = fingerprint == null || fingerprint.trim().isEmpty
        ? null
        : fingerprint.trim();

    final watch = Stopwatch()..start();
    SSHSocket? sock;
    SSHClient? client;
    String? seenFp;
    var fpRejected = false;

    // 把「连接 + 握手 + 认证 + 执行」写成局部函数：
    // 外层只负责总超时和 finally 收尾；超时回调里也能直接拿到 sock/client 去关。
    Future<_RawRun> connectAndRun() async {
      final s = await SSHSocket.connect(target, port, timeout: _connectTimeout);
      sock = s;

      final c = SSHClient(
        s,
        username: login,
        // 单条命令的执行时长由总超时控制，不需要 keepalive 定时器：
        // 设 null 可以少一个后台 Timer，也少一条可能在上层已经超时后才冒出来的错误。
        keepAliveInterval: null,
        // 只注册真正会用到的认证方式。私钥模式下不挂密码回调，
        // 服务器就不会把 password 当成可用方法，认证失败时语义更清楚。
        onPasswordRequest: hasPassword ? () => password : null,
        identities: identities,
        // 指纹校验必须在握手阶段做：这是唯一能确认「对端是不是那台机器」的时机。
        // 返回 false 时 dartssh2 会以 SSHHostkeyError 关闭连接，不会继续认证，
        // 所以私钥签名/密码不会发给冒充者。
        onVerifyHostKey: (String type, Uint8List raw) async {
          final actual = _fingerprintText(raw);
          seenFp = actual;
          if (expectedFp == null) {
            // 首次连接没有参照物，只能先信（TOFU）；调用方拿 fingerprint 自行决定
            // 要不要让用户确认并写进主机记录——本层按约定不存储。
            return true;
          }
          if (_sameFingerprint(expectedFp, actual)) return true;
          // 指纹变了就是硬失败：宁可不连，也不能把凭据交给可能的中转者。
          fpRejected = true;
          return false;
        },
      );
      client = c;

      return _run(c, command);
    }

    try {
      final raw = await connectAndRun().timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () {
          // Future.timeout 只是「不再等」，底层 socket 和远端进程还活着；
          // 必须主动关掉，否则命令会在服务器上继续跑、本地也漏一个 fd。
          // finally 里还会再兜一次，close 本身是幂等的，多关一次没关系。
          unawaited(_closeQuietly(client, sock));
          throw SshException('命令超时（${timeoutSeconds}s），连接已关闭');
        },
      );

      watch.stop();
      final code = raw.exitCode ?? -1;
      return SshExecResult(
        ok: code == 0,
        exitCode: code,
        stdout: raw.stdout,
        stderr: raw.stderr,
        ms: watch.elapsedMilliseconds,
        fingerprint: seenFp ?? expectedFp,
      );
    } on SshException {
      // 自己抛的已经是中文，原样上抛，避免被下面的兜底再包一层。
      rethrow;
    } catch (e) {
      // 指纹不匹配时，dartssh2 可能以 SSHHostkeyError、也可能以「连接被关闭」的
      // 形式收场；只要是我们主动拒绝的，就统一报成明确的中间人告警，
      // 不让调用方误以为是网络抖动而去重试。
      if (fpRejected && expectedFp != null && seenFp != null) {
        throw SshException(
            '主机指纹变了，可能在中间人攻击：期望 $expectedFp，实际 $seenFp。已断开，未发送任何凭据');
      }
      throw SshException(_message(
        e,
        host: target,
        port: port,
        expectedFp: expectedFp,
        seenFp: seenFp,
        rejected: fpRejected,
      ));
    } finally {
      // 无论成功、超时、认证失败还是解析响应时炸掉，都从这里收连接。
      // 放在 finally 是因为上面有多条 return/throw 路径，任何一条漏关都会
      // 留下一条 TCP 连接和 dartssh2 的内部 StreamController，长时间跑会耗光电量。
      await _closeQuietly(client, sock);
    }
  }

  /// 按已保存主机的别名执行命令。
  ///
  /// [alias] 接受 `user@host:port`（即 [SshHost.id]），也接受只写主机名/IP。
  /// 私钥从主机记录里的 keyPath 读取；密码从不落盘，所以密码认证的主机会
  /// 直接报中文错误，提示调用方改用 [exec] 显式传密码。
  Future<SshExecResult> execOnSaved(
    String alias,
    String command, {
    int timeoutSeconds = 60,
  }) async {
    final key = alias.trim();
    if (key.isEmpty) throw const SshException('主机别名不能为空');

    final hosts = await _store.load();
    SshHost? saved;
    for (final h in hosts) {
      if (h.id == key || h.label == key || h.host == key) {
        saved = h;
        break;
      }
    }
    if (saved == null) {
      final avail = hosts.map((h) => h.id).join('、');
      throw SshException(avail.isEmpty
          ? '没有找到已保存的主机「$key」（当前还没有保存任何主机）'
          : '没有找到已保存的主机「$key」，可用：$avail');
    }

    if (!saved.useKey) {
      // 密码只存在 SSH 页面的内存里，进程重启就没了，这里没有可用凭据。
      throw SshException(
          '主机「${saved.label}」保存的是密码认证，密码不落盘无法自动登录；'
          '请改用私钥认证的主机，或直接调用 exec 显式传 password');
    }

    final path = saved.keyPath;
    if (path == null || path.isEmpty) {
      throw SshException('主机「${saved.label}」没有记录私钥文件路径，请在 SSH 页面重新导入私钥');
    }

    // 只显示文件名：完整路径里带 app 私有目录结构，对模型没有意义。
    final name = path.split('/').last;
    final file = File(path);
    if (!await file.exists()) {
      throw SshException('私钥文件不存在（$name），可能已被清理，请在 SSH 页面重新导入');
    }

    String pem;
    try {
      if (await file.length() > _maxKeyBytes) {
        throw SshException('私钥文件（$name）太大，不像是私钥');
      }
      pem = await file.readAsString();
    } on SshException {
      rethrow;
    } catch (_) {
      // 不拼底层异常：FileSystemException 的 message 里带完整路径，没必要外泄。
      throw SshException('读不到私钥文件（$name），请检查文件权限或重新导入');
    }
    if (pem.trim().isEmpty) {
      throw SshException('私钥文件（$name）是空的，请重新导入');
    }

    return exec(
      host: saved.host,
      port: saved.port,
      user: saved.user,
      privateKeyPem: pem,
      // 已记住指纹的主机强制校验：这样即使私钥文件被换掉，连的也必须是同一台机器。
      fingerprint: saved.fingerprint,
      command: command,
      timeoutSeconds: timeoutSeconds,
    );
  }

  /// 列出已保存主机的别名（`user@host:port`），供模型挑选。
  ///
  /// 每次都强制读盘：主机可能刚在 SSH 页面里被增删，缓存里的是旧列表。
  Future<List<String>> aliases() async {
    try {
      final hosts = await _store.load(force: true);
      final list = hosts.map((h) => h.id).toList()..sort();
      return list;
    } catch (_) {
      // load() 本身已经很容错，走到这里基本是通道/IO 异常，给一句人话就行。
      throw const SshException('读取已保存主机失败，请检查应用存储权限');
    }
  }

  // -------------------------------------------------------------- 内部实现

  /// 执行命令并拿到退出码 / stdout / stderr。
  ///
  /// 4.1.0 的 `run()` 只是 `runWithResult().output`：把 stdout+stderr 合并成
  /// 一个 Uint8List，退出码被丢掉了。Agent 必须能区分「命令失败」和「没输出」，
  /// 所以用同一通道的 `runWithResult`（= run + 退出码），不会多执行一次命令。
  Future<_RawRun> _run(SSHClient client, String command) async {
    try {
      final r = await client.runWithResult(command);
      return _RawRun(
        r.exitCode,
        utf8.decode(r.stdout, allowMalformed: true),
        utf8.decode(r.stderr, allowMalformed: true),
      );
    } on NoSuchMethodError {
      // 兜底：万一依赖被换成没有 runWithResult 的版本（或平台实现裁剪了它），
      // 退回 execute() 手工收流。这里只在「一调用就失败」时回退——命令尚未执行，
      // 所以不会出现同一条命令跑两遍的副作用。
      return _runViaSession(client, command);
    }
  }

  /// 旧式通道：`execute()` 拿 SSHSession，自己监听 stdout/stderr 并等退出码。
  Future<_RawRun> _runViaSession(SSHClient client, String command) async {
    final session = await client.execute(command);
    try {
      final out = <int>[];
      final err = <int>[];

      // 必须先订阅再等结束：通道 close 之后缓冲区里还可能有没读完的字节，
      // 先 await session.done 再收流会丢最后一段输出（尤其是命令末尾的报错）。
      final outDone = session.stdout
          .handleError((Object _) {})
          .forEach((Uint8List data) => out.addAll(data));
      final errDone = session.stderr
          .handleError((Object _) {})
          .forEach((Uint8List data) => err.addAll(data));

      // 两个流一起等：先等一个再等另一个，后一个的错误会在这段时间里没人接，
      // 变成未捕获的异步异常。
      await Future.wait(<Future<void>>[outDone, errDone]);
      await session.done;

      return _RawRun(
        session.exitCode,
        utf8.decode(out, allowMalformed: true),
        utf8.decode(err, allowMalformed: true),
      );
    } finally {
      // 命令已经跑完（或炸了）就关掉这条会话通道，不然服务器端会挂着执行进程。
      try {
        session.close();
      } catch (_) {}
    }
  }

  /// 解析私钥。返回的是列表，因为一个 PEM 文件里可能有多把 key。
  List<SSHKeyPair> _parseKey(String? pem, String? passphrase) {
    final text = (pem ?? '').trim();
    if (text.isEmpty) throw const SshException('私钥内容为空');

    final secret = passphrase == null || passphrase.isEmpty ? null : passphrase;

    // 先判断是否加密：没给口令时能直接说「需要口令」，比笼统的解析失败有用。
    // 判断失败不影响后续，继续往下的解析会给出更准确的错误。
    var encrypted = false;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(text);
    } catch (_) {}

    try {
      final keys = SSHKeyPair.fromPem(text, secret);
      if (keys.isEmpty) throw const SshException('这个私钥文件里没有可用的密钥');
      return keys;
    } on SshException {
      rethrow;
    } on SSHKeyDecryptError {
      throw const SshException('私钥解密失败：口令不对，或私钥本身已损坏');
    } on SSHKeyDecodeError {
      throw const SshException('私钥解析失败：内容损坏，或不是支持的私钥格式');
    } on FormatException {
      throw const SshException('私钥解析失败：不是完整的 PEM 文本（缺少 BEGIN/END 行）');
    } on UnsupportedError {
      // 不拼底层 message：UnsupportedError 里可能带算法/参数细节，也可能带密钥片段。
      if (encrypted && secret == null) {
        throw const SshException('这个私钥有口令保护，请填写 passphrase 后再连接');
      }
      throw const SshException('不支持的私钥格式（PKCS#8 加密私钥请先转成 OpenSSH 格式）');
    } catch (e) {
      if (encrypted && secret == null) {
        throw const SshException('这个私钥有口令保护，请填写 passphrase 后再连接');
      }
      // 兜底异常也不拼 e.toString()，只报类型，防止底层把密钥原文带进 message。
      throw SshException('私钥解析失败（${e.runtimeType}）');
    }
  }

  /// 关连接：任何一步失败都吞掉，收尾阶段再抛异常只会盖住真正的错误。
  ///
  /// client.close() 内部会关掉 transport（也就关了 socket），所以 sock.close()
  /// 通常是一次无效操作，但连接在握手阶段就失败时 client 可能还没建起来，
  /// 这时必须靠 sock.close() 把半开的 fd 收掉——两边都关才不漏。
  Future<void> _closeQuietly(SSHClient? client, SSHSocket? sock) async {
    final c = client;
    if (c != null) {
      try {
        await c.close().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    final s = sock;
    if (s != null) {
      try {
        await s.close().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  /// 把底层异常翻译成一句中文。
  ///
  /// 原则：只用「类型 + 我们自己产生的上下文」，从不拼 e.toString()——
  /// dartssh2 的部分异常会把服务器报文/密钥材料带进 message。
  String _message(
    Object e, {
    required String host,
    required int port,
    String? expectedFp,
    String? seenFp,
    bool rejected = false,
  }) {
    if (e is SSHHostkeyError) {
      if (rejected && expectedFp != null && seenFp != null) {
        return '主机指纹变了，可能在中间人攻击：期望 $expectedFp，实际 $seenFp。已断开，未发送任何凭据';
      }
      return '主机指纹校验失败，已断开连接';
    }
    if (e is SSHAuthFailError) {
      return '认证失败：用户名、密码或私钥不被服务器接受';
    }
    if (e is SSHAuthAbortError) {
      return '认证中断：连接在认证过程中被关闭，请重试';
    }
    if (e is SSHAuthError) {
      return '认证失败：服务器拒绝了当前认证方式';
    }
    if (e is TimeoutException) {
      return '连接 $host:$port 超时，请检查网络和端口';
    }
    if (e is SocketException) {
      return '连不上 $host:$port：网络不可达或端口未开放';
    }
    if (e is SSHSocketError) {
      return '网络错误：连接在传输层中断';
    }
    if (e is SSHHandshakeError) {
      return 'SSH 握手失败：对端可能不是 SSH 服务，或加密算法不兼容';
    }
    if (e is SSHChannelOpenError) {
      return '打开 SSH 会话失败：服务器拒绝分配通道';
    }
    if (e is SSHChannelRequestError) {
      return '服务器拒绝执行命令：可能不允许 exec 请求';
    }
    if (e is SSHDisconnectError) {
      return '服务器主动断开了连接';
    }
    if (e is SSHKeyDecodeError) {
      return '私钥解析失败，请检查私钥格式和口令';
    }
    return 'SSH 操作失败（${e.runtimeType}）';
  }

  /// dartssh2 4.x 的指纹是 UTF-8 编码的 `SHA256:base64`（不是 32 字节裸摘要）。
  /// 兼容万一给裸摘要的实现：统一转成 OpenSSH 写法，才能和保存的指纹直接比。
  String _fingerprintText(Uint8List raw) {
    try {
      final text = utf8.decode(raw);
      if (text.startsWith('SHA256:')) return text;
    } catch (_) {}
    return 'SHA256:${base64.encode(raw).replaceAll('=', '')}';
  }

  /// 指纹比对：忽略首尾空白、`=` padding 和可选的前缀，
  /// 但不忽略大小写（base64 大小写敏感，忽略就等于放宽校验）。
  bool _sameFingerprint(String expected, String actual) {
    String body(String s) {
      final t = s.trim();
      final noPad = t.replaceAll('=', '');
      return noPad.startsWith('SHA256:') ? noPad.substring(7) : noPad;
    }

    final a = body(expected);
    final b = body(actual);
    return a.isNotEmpty && a == b;
  }
}

/// 内部用的原始结果：退出码可能为 null（服务器没上报）。
class _RawRun {
  const _RawRun(this.exitCode, this.stdout, this.stderr);

  final int? exitCode;
  final String stdout;
  final String stderr;
}
