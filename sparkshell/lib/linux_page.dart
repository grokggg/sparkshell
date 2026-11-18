import 'package:flutter/material.dart';

import 'linux_env.dart';
import 'pty_terminal.dart';

/// Linux 页：首次进入时释放 proot + Debian rootfs，然后复用 PTY 通道进容器。
class LinuxPage extends StatelessWidget {
  const LinuxPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PtyTerminalPage(
      title: 'Debian Linux',
      commandProvider: (log) async {
        try {
          return await LinuxEnv.instance.ensureReady(log);
        } catch (e) {
          log('初始化失败: $e');
          return null;
        }
      },
    );
  }
}
