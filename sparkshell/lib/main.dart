import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_bus.dart';
import 'chat/chat_page.dart';
import 'diag.dart';
import 'files/file_page.dart';
import 'linux_env.dart';
import 'linux_page.dart';
import 'security/self_check.dart';
import 'ssh_terminal.dart';
import 'app_version.dart';
import 'webrtc/remote_page.dart';

void main() {
  // 全局兜底：真机闪退时至少留下现场，用户能在「设置 → 诊断」里一键复制。
  // 之前是 `void main() => runApp(...)`，红屏一闪什么都不剩，只能靠截图猜。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        Diag.add('flutter', details.exception, details.stack);
        if (previous != null) {
          previous(details);
        } else {
          FlutterError.presentError(details);
        }
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        Diag.add('platform', error, stack);
        return true;
      };
      runApp(const SparkShellApp());
    },
    (error, stack) => Diag.add('zone', error, stack),
  );
}

class SparkShellApp extends StatelessWidget {
  const SparkShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SparkShell',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1020),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7DE2D1),
          brightness: Brightness.dark,
        ),
      ),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _idx = 0;

  // late final：初始化时机在构造之后，才能引用实例方法 _sendToChat
  late final _pages = <Widget>[
    const LinuxPage(),
    const ChatPage(),
    _FilesTab(onSendToChat: _sendToChat),
    const SshTerminalPage(),
    const RtcRemotePage(),
  ];

  /// 文件页长按「发给 Agent」：把路径交给 Chat，再切到 Chat 页。
  void _sendToChat(String path) {
    AppBus.pendingChatFile.value = path;
    setState(() => _idx = 1);
  }

  @override
  void initState() {
    super.initState();
    // 首帧之后再跑：自检要读整个 APK 算哈希，1–2 秒，不能卡启动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Diag.boot();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Text('SparkShell'),
          SizedBox(width: 8),
          Text('v$appVersion', style: TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
        centerTitle: false,
      ),
      body: Column(
        children: [
          // 启动即自检：不合格的包不该等到用户翻到设置页才发现。
          _SelfCheckBanner(),
          Expanded(child: IndexedStack(index: _idx, children: _pages)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.computer), label: 'Linux'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), label: '文件'),
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'SSH'),
          NavigationDestination(icon: Icon(Icons.wifi_tethering), label: '远程'),
        ],
      ),
    );
  }
}


/// 文件 Tab 依赖 rootfs 的就绪路径，所以单独包一层：先 ensureReady，再交棒给 FilePage。
class _FilesTab extends StatefulWidget {
  const _FilesTab({this.onSendToChat});

  final void Function(String path)? onSendToChat;

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  String? _root;
  String? _err;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      // ensureReady 返回的是 proot 启动脚本路径，不是 rootfs！
      // 文件页要的是 rootfs 根目录，必须取 rootfsPath（v1.6.1 之前拿错了）。
      final script = await LinuxEnv.instance.ensureReady((_) {});
      final root = LinuxEnv.instance.rootfsPath;
      if (!mounted) return;
      setState(() {
        _root = root;
        _err = root != null
            ? null
            : (script == null
                ? 'rootfs 未就绪，先去 Linux 页启动一次，再回文件页'
                : 'rootfs 路径没记下来（启动脚本=$script）');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_root != null) {
      return FilePage(rootPath: _root!, onSendToChat: widget.onSendToChat);
    }
    return Center(
      child: _err == null
          ? const CircularProgressIndicator(strokeWidth: 2)
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.folder_off_outlined, size: 40),
                const SizedBox(height: 12),
                Text(_err!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(onPressed: _boot, child: const Text('重试')),
              ]),
            ),
    );
  }
}

/// 顶部红条：只在自检不合格时出现（重签包 / XFS-1 自检不过 / 自检本身报错）。
/// 合格时什么都不显示 —— 平时别拿它占地方。
class _SelfCheckBanner extends StatelessWidget {
  const _SelfCheckBanner();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SelfCheckResult?>(
      valueListenable: Diag.selfCheck,
      builder: (context, sc, _) {
        if (sc == null || sc.ok) return const SizedBox.shrink();
        return Material(
          color: const Color(0xFF3A1520),
          child: InkWell(
            onTap: () => _showDetail(context, sc),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: [
                  const Icon(Icons.gpp_bad_rounded,
                      size: 17, color: Color(0xFFFF6B81)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '这个包的签名对不上（${sc.summary}）—— 别在上面填 API Key',
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: Color(0xFFFFB3BE),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showDetail(context, sc),
                    child: const Text('详情', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showDetail(BuildContext context, SelfCheckResult sc) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自检详情'),
        content: SingleChildScrollView(
          child: Text(
            '结论 ${sc.verdict}\n'
            '证书 ${sc.cert}\n'
            '设备指纹 ${sc.fp}\n'
            'XFS-1 ${sc.xfsOk ? "通过" : "不通过"}\n'
            '包名 ${sc.pkg}\n'
            '${sc.err.isEmpty ? "" : "错误 ${sc.err}"}',
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
