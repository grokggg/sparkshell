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
      // 注意：不能用 `apk add ... || apt-get ...`。
      // Alpine 在 proot 下装完会因 busybox/ca-certificates 的 trigger 返回非 0（那 1 error 是无害的），
      // `||` 就会把 Debian 分支也拖出来跑一遍，于是终端里冒出 "apt-get: not found"。
      toolchainCommand: 'if command -v apk >/dev/null 2>&1; then '
          'apk add --no-cache python3 py3-pip git curl vim nano; '
          'else apt-get update && apt-get install -y python3 python3-pip git curl vim nano; fi; '
          'echo "--- 自检 ---"; python3 -V 2>&1; git --version 2>&1; '
          'curl --version 2>&1 | head -1; echo "(上面 apk 报的 1 error 是 proot 下的 trigger 噪音，不影响使用)"',
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
