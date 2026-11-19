// ignore_for_file: avoid_print
//
// updater.dart 自检：跑一个真的本地 HTTP 服务，验证 check() 能解析清单、版本比较正确，
// 顺带把 download()（真下载 + sha256 校验）和 install()（走 mock 的原生通道）也跑通。
//
//   自带 fixture 服务（随机端口，setUpAll 里起，tearDownAll 收），
//   所以直接 `flutter test` 就能跑，不依赖外部 python 服务。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/update/updater.dart';

late HttpServer _fixture;
late String _base;

/// 300000 字节的确定性内容（不用随机，sha 才能稳定复现）。
List<int> get _apkBytes => List<int>.generate(300000, (int i) => (i * 31 + 7) & 0xFF);

Future<void> _startFixture() async {
  _fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _base = 'http://127.0.0.1:${_fixture.port}';
  final String sha = crypto.sha256.convert(_apkBytes).toString();
  final String apkUrl = '$_base/app-alpine-2.9.1.apk';
  final Map<String, Object> latest = <String, Object>{
    'version': '2.9.1', 'code': 32, 'url': apkUrl,
    'size': 300000, 'sha256': sha, 'notes': '修 proot 下 apt 空壳的问题',
  };
  final Map<String, Object> stale = <String, Object>{
    'version': '2.9.0', 'code': 30, 'url': apkUrl,
    'size': 300000, 'sha256': sha, 'notes': '',
  };
  final Map<String, Object> github = <String, Object>{
    'tag_name': 'v2.9.10-apk',
    'body': 'github 格式',
    'assets': <Object>[
      <String, Object>{
        'name': 'app-alpine.apk', 'size': 300000,
        'browser_download_url': apkUrl, 'digest': 'sha256:$sha',
      },
    ],
  };

  _fixture.listen((HttpRequest req) async {
    final String path = req.uri.path;
    if (path == '/app-alpine-2.9.1.apk') {
      req.response.headers.contentType = ContentType.binary;
      req.response.contentLength = _apkBytes.length;
      req.response.add(_apkBytes);
    } else {
      final Map<String, Object>? body = switch (path) {
        '/latest.json' => latest,
        '/stale.json' => stale,
        '/github.json' => github,
        _ => null,
      };
      if (body == null) {
        req.response.statusCode = 404;
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
      }
    }
    await req.response.close();
  });
}

void main() {
  // 需要 binding 才能 mock MethodChannel；但 binding 会把 HttpOverrides 换成
  // “所有请求返回 400”的桩，所以随后显式置回 null 才能打本地真实 HTTP。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUpAll(() async {
    await _startFixture();
  });
  tearDownAll(() async {
    await _fixture.close(force: true);
  });

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final MethodChannel pty = const MethodChannel('com.xinghuo.sparkshell/pty');
  final MethodChannel io = const MethodChannel('sparkshell/io');

  late Directory tmp;
  late String apkSha;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('updater_selfcheck');
    // 把原生 filesDir 指到临时目录
    messenger.setMockMethodCallHandler(pty, (MethodCall call) async {
      if (call.method == 'filesDir') return tmp.path;
      return null;
    });
    // 原生安装通道：默认成功
    messenger.setMockMethodCallHandler(io, (MethodCall call) async {
      if (call.method == 'installApk') return true;
      return null;
    });
    apkSha = _sha256Hex(_apkBytes).toLowerCase();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pty, null);
    messenger.setMockMethodCallHandler(io, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('版本比较', () {
    test('2.9.10 > 2.9.9（按段比，不是按字符串）', () {
      expect(Updater.compareVersions('2.9.10', '2.9.9'), greaterThan(0));
    });
    test('2.10.0 > 2.9.9', () {
      expect(Updater.compareVersions('2.10.0', '2.9.9'), greaterThan(0));
    });
    test('相同版本返回 0', () {
      expect(Updater.compareVersions('2.9.1', '2.9.1'), 0);
    });
    test('段数不同按补零比较', () {
      expect(Updater.compareVersions('2.9', '2.9.0'), 0);
      expect(Updater.compareVersions('2.9.1', '2.9'), greaterThan(0));
    });
    test('容忍前导 v 与 -apk 后缀', () {
      expect(Updater.compareVersions('v2.10.0-apk', '2.9.9'), greaterThan(0));
    });
    test('新版本小于旧版本返回负数', () {
      expect(Updater.compareVersions('2.8.9', '2.9.9'), lessThan(0));
    });
  });

  group('check()', () {
    test('从 latest.json 解析出 2.9.1 并判定有新版本', () async {
      final Updater u = Updater(sources: <String>['$_base/latest.json']);
      final UpdateInfo? info =
          await u.check(currentVersion: '2.9.0', currentCode: 31);
      expect(info, isNotNull);
      print('  latest.json -> $info');
      expect(info!.version, '2.9.1');
      expect(info.code, 32);
      expect(info.size, 300000);
      expect(info.url, endsWith('/app-alpine-2.9.1.apk'));
      expect(info.sha256, apkSha);
      expect(info.notes, contains('proot'));
    });

    test('已是最新时返回 null（版本相同）', () async {
      final Updater u = Updater(sources: <String>['$_base/latest.json']);
      final UpdateInfo? info =
          await u.check(currentVersion: '2.9.1', currentCode: 32);
      print('  same version -> $info');
      expect(info, isNull);
    });

    test('版本相同但 code 更大也算有更新', () async {
      final Updater u = Updater(sources: <String>['$_base/latest.json']);
      final UpdateInfo? info =
          await u.check(currentVersion: '2.9.1', currentCode: 1);
      expect(info, isNotNull);
      expect(info!.code, 32);
    });

    test('清单比本机旧时返回 null', () async {
      final Updater u = Updater(sources: <String>['$_base/stale.json']);
      final UpdateInfo? info =
          await u.check(currentVersion: '2.9.1', currentCode: 32);
      expect(info, isNull);
    });

    test('GitHub Release 格式（tag v2.9.10-apk + assets）', () async {
      final Updater u = Updater(sources: <String>['$_base/github.json']);
      final UpdateInfo? info =
          await u.check(currentVersion: '2.9.9', currentCode: 30);
      print('  github -> $info');
      expect(info, isNotNull);
      expect(info!.version, '2.9.10');
      expect(info.url, endsWith('app-alpine-2.9.1.apk'));
      expect(info.sha256, apkSha);
    });

    test('第一个源连不上时继续试第二个', () async {
      final Updater u = Updater(sources: <String>[
        'http://127.0.0.1:1/dead.json',
        '$_base/latest.json',
      ]);
      final UpdateInfo? info =
          await u.check(currentVersion: '2.9.0', currentCode: 31);
      expect(info, isNotNull);
      expect(info!.version, '2.9.1');
    });

    test('两个源都挂才抛错，且错误是中文', () async {
      final Updater u = Updater(sources: <String>[
        'http://127.0.0.1:1/a.json',
        'http://127.0.0.1:2/b.json',
      ]);
      await expectLater(
        u.check(currentVersion: '2.9.0', currentCode: 31),
        throwsA(isA<UpdateException>().having(
            (UpdateException e) => e.message, 'message', contains('检查更新失败'))),
      );
    });
  });

  group('download() + install()', () {
    test('下载到私有 updates/，sha256 校验通过，能拉起安装器', () async {
      final Updater u = Updater(sources: <String>['$_base/latest.json']);
      final UpdateInfo info =
          (await u.check(currentVersion: '2.9.0', currentCode: 31))!;

      final List<double> progress = <double>[];
      final String path = await u.download(info, onProgress: progress.add);
      print('  downloaded -> $path');
      print('  report -> ${u.lastDownload}');

      expect(path, endsWith('app-alpine-2.9.1.apk'));
      expect(File(path).existsSync(), isTrue);
      expect(File('$path.part').existsSync(), isFalse, reason: '.part 必须被 rename 掉');
      expect(File(path).lengthSync(), 300000);
      expect(u.lastDownload!.verified, isTrue);
      expect(u.lastDownload!.sha256, apkSha);
      expect(progress, isNotEmpty);
      expect(progress.last, closeTo(1.0, 1e-9));

      expect(await u.install(path), isTrue);
    });

    test('sha256 不匹配时删除文件并报中文错', () async {
      final Updater u = Updater(sources: <String>['$_base/latest.json']);
      final UpdateInfo bad = UpdateInfo(
        version: '2.9.1',
        code: 32,
        url: '$_base/app-alpine-2.9.1.apk',
        size: 300000,
        sha256: '0000', // 故意错的 sha
        notes: '',
      );
      await expectLater(
        u.download(bad),
        throwsA(isA<UpdateException>()
            .having((UpdateException e) => e.message, 'message', contains('sha256'))),
      );
      final Directory dir = Directory('${tmp.path}/updates');
      final List<String> left = dir.existsSync()
          ? dir.listSync().map((FileSystemEntity f) => f.path).toList()
          : <String>[];
      print('  leftovers -> $left');
      expect(left, isEmpty);
    });

    test('缺安装权限时抛出可读的中文提示', () async {
      messenger.setMockMethodCallHandler(io, (MethodCall call) async {
        if (call.method == 'installApk') {
          throw PlatformException(
            code: 'need_install_permission',
            message: '未授予「安装未知应用」权限',
          );
        }
        return null;
      });
      final Updater u = Updater(sources: <String>['$_base/latest.json']);
      final File fake = File('${tmp.path}/x.apk')..writeAsBytesSync(<int>[1, 2, 3]);
      await expectLater(
        u.install(fake.path),
        throwsA(isA<UpdateException>().having(
            (UpdateException e) => e.message, 'message', contains('权限'))),
      );
    });

    test('安装包不存在时直接报错', () async {
      final Updater u = Updater(sources: <String>['$_base/latest.json']);
      await expectLater(
        u.install('${tmp.path}/nope.apk'),
        throwsA(isA<UpdateException>()),
      );
    });
  });
}

String _sha256Hex(List<int> bytes) {
  // 测试里用 crypto 算，和实现独立
  return crypto.sha256.convert(bytes).toString();
}
