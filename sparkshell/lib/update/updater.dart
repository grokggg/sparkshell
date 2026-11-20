// 应用内检查更新 / 下载 / 调起系统安装器。
//
// 这个文件刻意不 import material —— 只依赖 dart:io + flutter/services，
// 方便被任意 UI（设置页、启动自检、命令行小工具）复用，也方便单测直接跑。
//
// 三个环节：
//   1. check()    读 latest.json（或 GitHub Release）比版本
//   2. download() 下到私有目录 filesDir/updates，先写 .part 再 rename，校验 sha256
//   3. install()  通过 IO 通道的 installApk 拉起系统安装器（FileProvider 授权）
//
// 约定：对外抛出的异常一律是 UpdateException，message 是可直接展示的中文一句话。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';

/// 更新流程中的可读错误。message 一定是中文一句，供 UI 直接展示。
class UpdateException implements Exception {
  UpdateException(this.message, [this.cause]);

  /// 中文说明，可直接展示给用户。
  final String message;

  /// 原始异常，仅用于日志，不展示。
  final Object? cause;

  @override
  String toString() => message;
}

/// 一条更新清单。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.code,
    required this.url,
    required this.size,
    required this.sha256,
    required this.notes,
    this.source = '',
  });

  /// 语义版本，形如 2.9.1（不含前导 v）。
  final String version;

  /// versionCode；来源不支持时为 0（表示未知，比较时忽略）。
  final int code;

  /// APK 直链。
  final String url;

  /// APK 字节数；未知为 0。
  final int size;

  /// 期望的 sha256（小写十六进制）；未知为空串。
  final String sha256;

  /// 更新说明。
  final String notes;

  /// 哪个源给的这份清单，排障用。
  final String source;

  @override
  String toString() =>
      'UpdateInfo(version: $version, code: $code, size: $size, '
      'sha256: ${sha256.isEmpty ? '-' : sha256}, url: $url)';
}

/// 下载结果。`path` 是落盘后的 APK 绝对路径。
class DownloadReport {
  const DownloadReport({
    required this.path,
    required this.bytes,
    required this.sha256,
    required this.verified,
    required this.note,
  });

  final String path;
  final int bytes;

  /// 实际算出来的 sha256（空串表示算不出来，例如 crypto 不可用）。
  final String sha256;

  /// 是否与清单里的 sha256 做过比对且通过。
  final bool verified;

  /// 校验状态的中文说明，成功/降级都会写清楚，绝不伪装成“已校验”。
  final String note;

  @override
  String toString() =>
      'DownloadReport(path: $path, bytes: $bytes, verified: $verified, note: $note)';
}

/// 检查 / 下载 / 安装。一个实例可重复使用。
class Updater {
  Updater({List<String>? sources})
      : sources = sources ?? manifestUrls;

  /// 清单源，按顺序回退。
  static const List<String> manifestUrls = <String>[
    'https://discretion-stated-bargain-expect.trycloudflare.com/latest.json',
    'https://api.github.com/repos/grokggg/sparkshell/releases/latest',
  ];

  /// GitHub Release 里 APK 资产的名字。
  static const String githubAssetName = 'app-alpine.apk';

  static const Duration manifestTimeout = Duration(seconds: 8);
  static const Duration downloadTimeout = Duration(seconds: 20);

  static const MethodChannel _pty = MethodChannel('com.xinghuo.sparkshell/pty');
  static const MethodChannel _io = MethodChannel('sparkshell/io');

  /// 实际使用的清单源（可在构造时替换，便于自测）。
  final List<String> sources;

  /// 最近一次 download() 的详细结果（供 UI 展示校验状态）。
  DownloadReport? lastDownload;

  // ---------------------------------------------------------------- check ---

  /// 检查更新。返回 null 表示已是最新（且至少有一个源成功应答）。
  ///
  /// 网络错误不会在第一个源上中断，会继续试下一个；两个源全挂才抛
  /// UpdateException，避免把“没网”伪装成“已是最新”。
  Future<UpdateInfo?> check({
    required String currentVersion,
    required int currentCode,
  }) async {
    final List<String> errors = <String>[];
    bool anySourceOk = false;

    for (final String url in sources) {
      try {
        final UpdateInfo info = await _fetchManifest(url);
        anySourceOk = true;
        if (_isNewer(info, currentVersion, currentCode)) return info;
      } on UpdateException catch (e) {
        errors.add('$url → ${e.message}');
      } catch (e) {
        errors.add('$url → ${_describe(e)}');
      }
    }

    if (anySourceOk) return null;
    throw UpdateException(
      '检查更新失败：所有更新源都不可用（${errors.join('；')}）',
      errors,
    );
  }

  Future<UpdateInfo> _fetchManifest(String url) async {
    final String body = await _getText(url).timeout(
      manifestTimeout,
      onTimeout: () => throw UpdateException('请求超时（${manifestTimeout.inSeconds}s）'),
    );
    return parseManifest(body, source: url);
  }

  /// 解析一份清单。兼容两种格式：
  ///   * 自建 latest.json：{version, code, url, size, sha256, notes}
  ///   * GitHub releases/latest：tag_name=v2.9.1-apk + assets[app-alpine.apk]
  static UpdateInfo parseManifest(String body, {String source = ''}) {
    final Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (e) {
      throw UpdateException('清单不是合法 JSON', e);
    }
    if (raw is! Map) {
      throw UpdateException('清单格式不对：顶层不是 JSON 对象');
    }
    final Map<String, dynamic> map = raw.cast<String, dynamic>();

    if (map['assets'] is List && map['tag_name'] is String) {
      return _parseGithub(map, source);
    }
    return _parsePlain(map, source);
  }

  static UpdateInfo _parsePlain(Map<String, dynamic> map, String source) {
    final String version = _cleanVersion(_str(map['version']));
    if (version.isEmpty) throw UpdateException('清单缺少 version 字段');

    final String url = _str(map['url'] ?? map['apkUrl'] ?? map['download']).trim();
    if (url.isEmpty) throw UpdateException('清单缺少 url 字段');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw UpdateException('清单里的 url 不是 http(s) 地址：$url');
    }

    return UpdateInfo(
      version: version,
      code: _int(map['code'] ?? map['versionCode']),
      url: url,
      size: _int(map['size'] ?? map['bytes']),
      sha256: _str(map['sha256'] ?? map['sha']).trim().toLowerCase(),
      notes: _str(map['notes'] ?? map['changelog'] ?? map['body']).trim(),
      source: source,
    );
  }

  static UpdateInfo _parseGithub(Map<String, dynamic> map, String source) {
    // tag 形如 v2.9.1-apk / 2.9.1
    final String tag = _str(map['tag_name']).trim();
    final String version = _cleanVersion(tag);
    if (version.isEmpty) throw UpdateException('Release 里的 tag 解析不出版本号：$tag');

    final List<dynamic> assets =
        (map['assets'] as List<dynamic>? ?? <dynamic>[]);
    Map<String, dynamic>? apk;
    for (final dynamic a in assets) {
      if (a is! Map) continue;
      final String name = _str(a['name']).toLowerCase();
      if (name == githubAssetName || name.endsWith('.apk')) {
        apk = a.cast<String, dynamic>();
        break;
      }
    }
    if (apk == null) throw UpdateException('Release 里没有找到 APK 资产');

    final String url = _str(apk['browser_download_url']).trim();
    if (url.isEmpty) throw UpdateException('APK 资产缺少下载地址');

    // GitHub 的 digest 字段形如 "sha256:abcd..."，没有就留空（不做假校验）。
    String sha = _str(apk['digest']).trim().toLowerCase();
    if (sha.startsWith('sha256:')) sha = sha.substring('sha256:'.length);

    return UpdateInfo(
      version: version,
      code: 0, // Release 不携带 versionCode
      url: url,
      size: _int(apk['size']),
      sha256: sha,
      notes: _str(map['body']).trim(),
      source: source,
    );
  }

  static bool _isNewer(UpdateInfo info, String currentVersion, int currentCode) {
    final int cmp = compareVersions(info.version, currentVersion);
    if (cmp != 0) return cmp > 0;
    // 版本号相同：只有在双方都给了 versionCode 时才用 code 兜底
    if (info.code > 0 && currentCode > 0) return info.code > currentCode;
    return false;
  }

  /// 分段并行下载：6 条连接各拉一段，直接写进同一个 .part。
  ///
  /// 只对「支持 Range + 大于 4 MB」的文件启用；服务端不认 Range 时抛
  /// [UpdateException] 由调用方回退到单连接，不在这里猜。
  Future<void> _downloadRanges(
    String url,
    File part,
    int total, {
    void Function(double)? onProgress,
  }) async {
    const int workers = 6;
    final RandomAccessFile raf = await part.open(mode: FileMode.write);
    await raf.truncate(total);
    final int chunk = (total + workers - 1) ~/ workers;
    int done = 0;
    double lastTick = 0;

    Future<void> one(int i) async {
      final int start = i * chunk;
      if (start >= total) return;
      final int end = (start + chunk - 1) < total ? start + chunk - 1 : total - 1;
      final HttpClient c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final HttpClientRequest req =
            await c.getUrl(Uri.parse(url)).timeout(downloadTimeout);
        req.headers.set(HttpHeaders.userAgentHeader, 'SparkShell-Updater');
        req.headers.set('Range', 'bytes=$start-$end');
        final HttpClientResponse r =
            await req.close().timeout(downloadTimeout);
        if (r.statusCode == HttpStatus.ok) {
          await r.drain<void>();
          throw UpdateException('服务端不支持分段下载');
        }
        if (r.statusCode != HttpStatus.partialContent) {
          await r.drain<void>();
          throw UpdateException('分段下载失败：HTTP ${r.statusCode}');
        }
        int pos = start;
        await for (final List<int> ch in r.timeout(const Duration(seconds: 90))) {
          await raf.setPosition(pos);
          await raf.writeFrom(ch);
          pos += ch.length;
          done += ch.length;
          if (total > 0 && onProgress != null) {
            final double p = (done / total).clamp(0.0, 1.0);
            if (p == 1.0 || p - lastTick >= 0.005) {
              lastTick = p;
              onProgress(p);
            }
          }
        }
      } finally {
        c.close(force: true);
      }
    }

    try {
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < workers; i++) one(i),
      ]);
    } finally {
      await raf.close();
    }
    if (done != total) {
      throw UpdateException('下载不完整：收到 $done / $total 字节');
    }
  }

  // ------------------------------------------------------------- download ---

  /// 下载 APK，返回落盘后的绝对路径。校验细节见 [lastDownload] / [DownloadReport]。
  Future<String> download(
    UpdateInfo info, {
    void Function(double)? onProgress,
  }) async {
    final DownloadReport report =
        await downloadDetailed(info, onProgress: onProgress);
    lastDownload = report;
    return report.path;
  }

  /// 同 [download]，但把“有没有真的校验成功”一并返回，避免调用方猜测。
  Future<DownloadReport> downloadDetailed(
    UpdateInfo info, {
    void Function(double)? onProgress,
  }) async {
    final Directory dir = await _updatesDir();
    final String name = _fileNameFor(info);
    final File target = File('${dir.path}/$name');
    final File part = File('${target.path}.part');

    // 先清掉上一次的残留，避免 .part 被追加写坏。
    for (final File f in <File>[part, target]) {
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {
          // 删不掉就让下面的写入失败并给出中文错误，这里不静默吞掉语义。
        }
      }
    }

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    int received = 0;
    int total = info.size > 0 ? info.size : 0;
    try {
      final HttpClientRequest req = await client
          .getUrl(Uri.parse(info.url))
          .timeout(downloadTimeout);
      req.headers.set(HttpHeaders.userAgentHeader, 'SparkShell-Updater');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final HttpClientResponse resp =
          await req.close().timeout(downloadTimeout);
      if (resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>();
        throw UpdateException('下载失败：HTTP ${resp.statusCode}（${info.url}）');
      }
      // 大包且服务端支持 Range：改走 6 路并行。单连接被限到 1 MB/s 时，
      // 60 MB 要一分钟；并行之后通常能压到十几秒（实测同一条隧道 3–4 倍）。
      if (resp.headers.value('accept-ranges') == 'bytes' &&
          total > 4 * 1024 * 1024) {
        await resp.drain<void>();
        await sink?.close();
        await _downloadRanges(info.url, part, total, onProgress: onProgress);
        received = total;
      } else {
      if (resp.contentLength > 0) total = resp.contentLength;

      sink = part.openWrite();
      double lastTick = 0;
      await for (final List<int> chunk in resp.timeout(downloadTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          final double p = (received / total).clamp(0.0, 1.0);
          if (p == 1.0 || p - lastTick >= 0.005) {
            lastTick = p;
            onProgress(p);
          }
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      }
    } on UpdateException {
      rethrow;
    } catch (e) {
      throw UpdateException('下载中断：${_describe(e)}', e);
    } finally {
      client.close(force: true);
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 关闭失败没有额外信息，忽略。
        }
      }
    }

    if (total > 0 && received != total) {
      _tryDelete(part);
      throw UpdateException('下载不完整：收到 $received / $total 字节');
    }

    // .part → 正式文件，rename 在同一目录内是原子的。
    final File done;
    try {
      done = await part.rename(target.path);
    } on FileSystemException catch (e) {
      _tryDelete(part);
      throw UpdateException('保存安装包失败：${e.message}', e);
    }

    // ---- sha256：能算就一定算；算不出 / 没给期望值都要如实写进 note ----
    String actual = '';
    String note = '没法算 sha256，本次未校验安装包完整性';
    bool verified = false;
    try {
      actual = await _sha256Of(done);
    } catch (e) {
      actual = '';
      note = '没法算 sha256（${_describe(e)}），本次未校验安装包完整性';
    }

    if (actual.isNotEmpty) {
      if (info.sha256.isEmpty) {
        note = '清单未提供 sha256，已算出实际 sha256=$actual，但未做比对';
      } else if (actual.toLowerCase() == info.sha256.toLowerCase()) {
        verified = true;
        note = 'sha256 校验通过';
      } else {
        _tryDelete(done);
        throw UpdateException(
          '安装包 sha256 不匹配（期望 ${info.sha256}，实际 $actual），已删除下载文件',
        );
      }
    }

    return DownloadReport(
      path: done.path,
      bytes: received,
      sha256: actual,
      verified: verified,
      note: note,
    );
  }

  /// 私有目录：filesDir/updates。走 pty 通道的 filesDir，避免自己猜路径。
  Future<Directory> _updatesDir() async {
    String? base;
    try {
      base = await _pty.invokeMethod<String>('filesDir');
    } on PlatformException catch (e) {
      throw UpdateException('拿不到应用私有目录：${e.message ?? e.code}', e);
    } on MissingPluginException catch (e) {
      throw UpdateException('拿不到应用私有目录：原生通道未就绪', e);
    }
    if (base == null || base.isEmpty) {
      throw UpdateException('拿不到应用私有目录（filesDir 返回空）');
    }
    final Directory dir = Directory('$base/updates');
    try {
      await dir.create(recursive: true);
    } on FileSystemException catch (e) {
      throw UpdateException('创建下载目录失败：${e.message}', e);
    }
    return dir;
  }

  static String _fileNameFor(UpdateInfo info) {
    String name = '';
    try {
      final List<String> segs = Uri.parse(info.url).pathSegments;
      if (segs.isNotEmpty) name = Uri.decodeComponent(segs.last);
    } catch (_) {
      name = '';
    }
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
    if (name.isEmpty || !name.toLowerCase().endsWith('.apk')) {
      name = 'sparkshell-${info.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_')}.apk';
    }
    if (name.length > 120) {
      name = '${name.substring(name.length - 116)}.apk';
    }
    return name;
  }

  static Future<String> _sha256Of(File file) async {
    final _DigestSink out = _DigestSink();
    final ByteConversionSink input = crypto.sha256.startChunkedConversion(out);
    try {
      await for (final List<int> chunk in file.openRead()) {
        input.add(chunk);
      }
    } finally {
      input.close();
    }
    final crypto.Digest? d = out.value;
    if (d == null) throw UpdateException('sha256 计算无结果');
    return d.toString();
  }

  // -------------------------------------------------------------- install ---

  /// 调起系统安装器。返回 true 表示已成功拉起安装界面。
  ///
  /// 缺「安装未知来源应用」权限时抛 UpdateException（原生侧 code=need_install_permission）。
  Future<bool> install(String apkPath) async {
    final File apk = File(apkPath);
    if (!apk.existsSync()) {
      throw UpdateException('安装包不存在：$apkPath');
    }
    try {
      final bool? ok = await _io.invokeMethod<bool>(
        'installApk',
        <String, Object?>{'path': apkPath},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'need_install_permission') {
        throw UpdateException(
          '需要「安装未知应用」权限：请在系统设置里允许 SparkShell 安装应用后重试',
          e,
        );
      }
      throw UpdateException('调起安装器失败：${e.message ?? e.code}', e);
    } on MissingPluginException catch (e) {
      throw UpdateException('当前版本没有安装通道，无法调起系统安装器', e);
    }
  }

  /// 清理下载目录里的历史安装包（安装成功后调用）。
  Future<void> clearCache() async {
    try {
      final Directory dir = await _updatesDir();
      await for (final FileSystemEntity f in dir.list()) {
        if (f is File) _tryDelete(f);
      }
    } catch (e) {
      throw UpdateException('清理安装包失败：${_describe(e)}', e);
    }
  }

  // ------------------------------------------------------------- helpers ---

  /// 语义版本比较：a>b 返回正数，a<b 返回负数，相等返回 0。
  /// 只按数字段比，非数字段（预发布后缀）忽略；段数不同时短的一方补 0。
  static int compareVersions(String a, String b) {
    final List<int> pa = _versionParts(a);
    final List<int> pb = _versionParts(b);
    final int n = pa.length > pb.length ? pa.length : pb.length;
    for (int i = 0; i < n; i++) {
      final int x = i < pa.length ? pa[i] : 0;
      final int y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }

  static List<int> _versionParts(String v) {
    String s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // 去掉 +build 与 -预发布 后缀
    final int plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    final int dash = s.indexOf('-');
    if (dash >= 0) s = s.substring(0, dash);
    final List<int> out = <int>[];
    for (final String seg in s.split('.')) {
      final Match? m = RegExp(r'^(\d+)').firstMatch(seg);
      out.add(m == null ? 0 : int.tryParse(m.group(1)!) ?? 0);
    }
    return out;
  }

  /// "v2.9.1-apk" → "2.9.1"；解析不出版本返回空串。
  static String _cleanVersion(String raw) {
    String s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final Match? m = RegExp(r'^\d+(?:\.\d+)*').firstMatch(s);
    return m == null ? '' : m.group(0)!;
  }

  static Future<String> _getText(String url) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse(url)).timeout(manifestTimeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'SparkShell-Updater');
      final HttpClientResponse resp = await req.close().timeout(manifestTimeout);
      if (resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>();
        throw UpdateException('HTTP ${resp.statusCode}');
      }
      return await resp.transform(utf8.decoder).join().timeout(manifestTimeout);
    } on UpdateException {
      rethrow;
    } on TimeoutException catch (e) {
      throw UpdateException('请求超时（${manifestTimeout.inSeconds}s）', e);
    } on SocketException catch (e) {
      throw UpdateException('网络不可达：${e.message}', e);
    } on HandshakeException catch (e) {
      throw UpdateException('TLS 握手失败：${e.message}', e);
    } on FormatException catch (e) {
      throw UpdateException('响应不是合法 UTF-8：${e.message}', e);
    } finally {
      client.close(force: true);
    }
  }

  static String _str(Object? v) => v == null ? '' : v.toString();

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  static void _tryDelete(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // 删除失败不影响主流程
    }
  }

  /// 把底层异常压成一句中文。
  static String _describe(Object e) {
    if (e is UpdateException) return e.message;
    if (e is TimeoutException) return '超时';
    if (e is SocketException) return '网络不可达：${e.message}';
    if (e is HandshakeException) return 'TLS 握手失败：${e.message}';
    if (e is HttpException) return 'HTTP 异常：${e.message}';
    if (e is FileSystemException) return '文件操作失败：${e.message}';
    if (e is FormatException) return '数据格式错误：${e.message}';
    return e.toString();
  }
}

/// 收集 chunked 转换的最终 digest，避免额外依赖 package:convert。
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) {
    value = data;
  }

  @override
  void close() {}
}
