import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 一台保存过的 SSH 主机。
///
/// 这里**只存连接元数据**：密码永远不落盘（只在 SshTerminalPage 的内存里活一次），
/// 私钥也只保存「文件路径」而不是内容——私钥文件本身在 app 私有目录里，
/// 由导入时复制进去。指纹保存成 OpenSSH 风格的 `SHA256:xxxx`。
class SshHost {
  SshHost({
    required this.host,
    required this.port,
    required this.user,
    required this.auth,
    this.keyPath,
    this.fingerprint,
    this.updatedAt,
  });

  final String host;
  final int port;
  final String user;

  /// 'password' 或 'key'，保持字符串存盘，避免以后枚举改名读不回老数据。
  final String auth;

  /// 私钥文件在手机私有目录中的绝对路径；密码认证时为 null。
  final String? keyPath;

  /// 上次「信任并记住」的主机指纹，形如 `SHA256:abc...`。
  final String? fingerprint;

  final String? updatedAt;

  /// 唯一标识：同机同端口同用户视为同一台主机。
  String get id => '$user@$host:$port';

  String get label => '$user@$host:$port';

  bool get useKey => auth == 'key';

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'user': user,
        'auth': auth,
        if (keyPath != null) 'keyPath': keyPath,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };

  /// 容错解析：坏了一条记录就跳过它，不要整份配置读不出来。
  static SshHost? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final host = raw['host'];
    final user = raw['user'];
    if (host is! String || host.isEmpty || user is! String || user.isEmpty) {
      return null;
    }
    final portRaw = raw['port'];
    final port = portRaw is int ? portRaw : int.tryParse('$portRaw') ?? 22;
    final auth = raw['auth'] == 'key' ? 'key' : 'password';
    final keyPath = raw['keyPath'];
    final fp = raw['fingerprint'];
    final ts = raw['updatedAt'];
    return SshHost(
      host: host,
      port: port < 1 || port > 65535 ? 22 : port,
      user: user,
      auth: auth,
      keyPath: keyPath is String && keyPath.isNotEmpty ? keyPath : null,
      fingerprint: fp is String && fp.isNotEmpty ? fp : null,
      updatedAt: ts is String ? ts : null,
    );
  }
}

/// 主机列表的本地存储。
///
/// 为什么不写 `getApplicationDocumentsDirectory()`：项目里没有 path_provider
/// 依赖（也不能新增），所以直接用原生 PTY 通道里已有的 `filesDir` 方法，
/// 拿到 `/data/data/com.xinghuo.sparkshell/files`。放在这里的好处是：
/// 属于 app 私有目录、卸载即清理、rootfs 之外的普通文件也能被 File API 直接读写。
/// 文件固定叫 `ssh_hosts.json`。
class SshHostStore {
  SshHostStore({MethodChannel? channel})
      : _pty = channel ?? const MethodChannel(_ptyChannel);

  static const _ptyChannel = 'com.xinghuo.sparkshell/pty';
  static const _fileName = 'ssh_hosts.json';

  final MethodChannel _pty;

  /// 内存缓存：一次连接里会多次读（选主机、记指纹、写回），没必要反复读盘。
  List<SshHost>? _cache;

  /// 取 app 私有文件目录；平台不支持（通道缺失、非 Android）时返回 null。
  Future<String?> filesDir() async {
    try {
      final dir = await _pty.invokeMethod<String>('filesDir');
      if (dir == null || dir.isEmpty) return null;
      return dir;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<File?> _file() async {
    final dir = await filesDir();
    if (dir == null) return null;
    return File('$dir/$_fileName');
  }

  /// 读全部主机。文件不存在、JSON 损坏、无权限，一律当空列表处理，
  /// 避免一个坏文件把 SSH 页整个卡死。
  Future<List<SshHost>> load({bool force = false}) async {
    if (!force && _cache != null) return List<SshHost>.from(_cache!);

    final file = await _file();
    if (file == null) {
      _cache = <SshHost>[];
      return <SshHost>[];
    }

    try {
      if (!await file.exists()) {
        _cache = <SshHost>[];
        return <SshHost>[];
      }
      final text = await file.readAsString();
      if (text.trim().isEmpty) {
        _cache = <SshHost>[];
        return <SshHost>[];
      }
      final decoded = jsonDecode(text);
      final rawList = decoded is Map ? decoded['hosts'] : decoded;
      final hosts = <SshHost>[];
      if (rawList is List) {
        for (final item in rawList) {
          final h = SshHost.fromJson(item);
          if (h != null) hosts.add(h);
        }
      }
      _cache = hosts;
      return List<SshHost>.from(hosts);
    } catch (_) {
      // 解析失败不覆盖原文件：用户还能手动去看一眼，别被我们静默清空。
      _cache = <SshHost>[];
      return <SshHost>[];
    }
  }

  /// 覆盖写回。先写临时文件再 rename，避免写到一半掉电留下半个 JSON。
  Future<void> saveAll(List<SshHost> hosts) async {
    final file = await _file();
    if (file == null) {
      throw StateError('读不到应用私有目录，无法保存主机');
    }
    final data = <String, Object?>{
      'version': 1,
      'hosts': hosts.map((h) => h.toJson()).toList(),
    };
    final text = const JsonEncoder.withIndent('  ').convert(data);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
    _cache = List<SshHost>.from(hosts);
  }

  /// 按 [SshHost.id] 新增或更新一条记录。
  Future<void> upsert(SshHost host) async {
    final hosts = await load();
    final idx = hosts.indexWhere((h) => h.id == host.id);
    if (idx >= 0) {
      hosts[idx] = host;
    } else {
      hosts.add(host);
    }
    await saveAll(hosts);
  }

  Future<void> remove(String id) async {
    final hosts = await load();
    hosts.removeWhere((h) => h.id == id);
    await saveAll(hosts);
  }

  /// 清掉缓存，下次 [load] 读盘。从别处改过文件时用得上。
  void invalidate() => _cache = null;
}
