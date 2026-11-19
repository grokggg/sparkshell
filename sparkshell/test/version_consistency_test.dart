// 版本号漂移守卫：pubspec / app_version.dart 必须同源。
//
// 这不是形式主义——2.9.0 之前版本号分散在 pubspec、标题字符串、更新检查三处，
// 结果"应用内更新"拿旧版本跟新清单比，永远判成"已是最新"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/app_version.dart';

void main() {
  test('appVersion/appCode 与 pubspec version 一致', () {
    final String yaml = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? m =
        RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$', multiLine: true)
            .firstMatch(yaml);
    expect(m, isNotNull, reason: 'pubspec 里没有 version: X.Y.Z+N');
    expect(m!.group(1), appVersion, reason: '改版本要同时改 lib/app_version.dart');
    expect(int.parse(m.group(2)!), appCode);
  });

  test('版本号能被 Updater 的语义比较解析', () {
    expect(RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(appVersion), isTrue);
    expect(appCode, greaterThan(0));
  });
}
