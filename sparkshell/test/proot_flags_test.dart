// 启动参数守卫：交互式会话必须带 --kill-on-exit，一次性命令必须不带。
//
// 这两条是反过来的：多一个旗标会让 `nohup … &` 一起被杀，少一个旗标会让
// 用户关掉终端后容器进程赖在后台。两边都不是"崩给你看"的错，只有真机用久了
// 才发现，所以用测试把决定钉死。

import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/linux_env.dart';

void main() {
  group('交互式启动脚本', () {
    late String body;

    setUp(() {
      body = launchScriptBody(
        base: '/data/user/0/com.grokggg.sparkshell/files',
        rootfs: '/data/user/0/com.grokggg.sparkshell/files/rootfs',
        tmp: '/data/user/0/com.grokggg.sparkshell/files/tmp',
      );
    });

    test('带 --kill-on-exit：关终端就收掉容器进程', () {
      expect(body, contains('--kill-on-exit'));
      expect(body, contains('--link2symlink'));
    });

    test('路径按传入值渲染，不写死包名', () {
      expect(body, contains('/data/user/0/com.grokggg.sparkshell/files/proot'));
      expect(body, isNot(contains(r'$base/proot'))); // dart 侧插值过，不该留字面量
    });

    test('bash 缺失时回落 sh，且 SHELL_BIN 作为 shell 变量在运行时展开', () {
      expect(body, contains('/bin/bash'));
      expect(body, contains('SHELL_BIN=/bin/sh'));
      // 脚本里必须是 \$SHELL_BIN（运行时展开），不能是已经被 dart 插值成空串
      expect(body, contains(r'$SHELL_BIN -l'));
    });

    test('绑 /dev /proc /sys /sdcard /storage 与工作目录 /root 都在', () {
      for (final b in ['/dev', '/proc', '/sys', '/sdcard', '/storage']) {
        expect(body, contains('-b $b'), reason: b);
      }
      expect(body, contains('-w /root'));
    });
  });

  group('一次性命令', () {
    test('不带 --kill-on-exit：不能顺手杀掉 nohup 的后台任务', () {
      expect(kProotExecFlags, isNot(contains('kill-on-exit')));
      expect(kProotExecFlags, contains('--link2symlink'));
    });

    test('交互式与一次性只差这一个旗标', () {
      final interactive = kProotInteractiveFlags.split(' ').toSet();
      final exec = kProotExecFlags.split(' ').toSet();
      expect(interactive.difference(exec), {'--kill-on-exit'});
      expect(exec.difference(interactive), isEmpty);
    });
  });
}
