import 'package:flutter/material.dart';

import 'app_bus.dart';
import 'chat/chat_page.dart';
import 'files/file_page.dart';
import 'linux_env.dart';
import 'linux_page.dart';
import 'ssh_terminal.dart';
import 'webrtc_page.dart';

void main() => runApp(const SparkShellApp());

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
    const WebRtcPage(),
  ];

  /// 文件页长按「发给 Agent」：把路径交给 Chat，再切到 Chat 页。
  void _sendToChat(String path) {
    AppBus.pendingChatFile.value = path;
    setState(() => _idx = 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Text('SparkShell'),
          SizedBox(width: 8),
          Text('v2.7.0', style: TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
        centerTitle: false,
      ),
      body: IndexedStack(index: _idx, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.computer), label: 'Linux'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), label: '文件'),
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'SSH'),
          NavigationDestination(icon: Icon(Icons.wifi_tethering), label: 'WebRTC'),
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
