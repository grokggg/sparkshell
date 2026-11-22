import 'dart:convert';

import 'package:flutter/services.dart';

/// 自检验结果（3.9.0）：签名自校验 + XFS-1 自检 + 设备凭证。
///
/// Java 侧实现在 `android/app/src/main/java/com/xinghuo/sparkshell/SelfCheck.java`，
/// 算法本体在 `.../com/xinghuo/xfs1/Xfs1.java`（与 server/xfs1_server.py 同一份算法）。
class SelfCheckResult {
  /// 本包签名证书 DER 的 SHA-256（来自 keystore，编译期常量比对的值也在这里）
  final String cert;

  /// 签名与编译期常量一致 → 没被二次打包
  final bool certOk;

  /// XFS-1 发令牌再解回来一致 → 算法/密钥没被改
  final bool xfsOk;

  /// 设备指纹（品牌/型号/设备/指纹/API/ANDROID_ID/APK-SHA256 的 SHA-256）
  final String fp;

  /// 设备凭证令牌，形如 `xfs1.xxx.yyy`，可直接 POST 给自建校验服务
  final String token;

  final String pkg;
  final String ver;

  /// ok / repackaged / xfs-broken / error
  final String verdict;
  final String err;

  const SelfCheckResult({
    this.cert = '',
    this.certOk = false,
    this.xfsOk = false,
    this.fp = '',
    this.token = '',
    this.pkg = '',
    this.ver = '',
    this.verdict = 'error',
    this.err = '',
  });

  factory SelfCheckResult.fromJson(Map<String, dynamic> j) => SelfCheckResult(
        cert: (j['cert'] ?? '').toString(),
        certOk: j['certOk'] == true,
        xfsOk: j['xfsOk'] == true,
        fp: (j['fp'] ?? '').toString(),
        token: (j['token'] ?? '').toString(),
        pkg: (j['pkg'] ?? '').toString(),
        ver: (j['ver'] ?? '').toString(),
        verdict: (j['verdict'] ?? 'error').toString(),
        err: (j['err'] ?? '').toString(),
      );

  factory SelfCheckResult.error(String e) =>
      SelfCheckResult(verdict: 'error', err: e);

  bool get ok => certOk && xfsOk;

  /// 证书前 16 位够认出是哪把 keystore 了
  String get certShort => cert.length >= 16 ? cert.substring(0, 16) : cert;
  String get fpShort => fp.length >= 16 ? fp.substring(0, 16) : fp;

  String get summary {
    switch (verdict) {
      case 'ok':
        return '签名 ✅ · XFS-1 ✅';
      case 'repackaged':
        return '签名不符（可能被二次打包）';
      case 'xfs-broken':
        return 'XFS-1 自检失败';
      default:
        return '自检未完成${err.isEmpty ? '' : '：$err'}';
    }
  }
}

const _channel = MethodChannel('com.xinghuo.sparkshell/pty');

/// 跑一次自检。Java 侧要把 APK 读完算哈希，首次约 1–2 s，别在 build() 里调。
Future<SelfCheckResult> runSelfCheck() async {
  try {
    final raw = await _channel.invokeMethod<String>('selfCheck');
    if (raw == null || raw.isEmpty) return SelfCheckResult.error('通道无返回');
    return SelfCheckResult.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (e) {
    return SelfCheckResult.error('$e');
  }
}
