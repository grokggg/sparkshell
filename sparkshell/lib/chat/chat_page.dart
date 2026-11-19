import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/agent_runner.dart';
import '../app_bus.dart';
import '../linux_env.dart';
import '../term/terminal_bus.dart';
import 'tool_card.dart';
import 'api_config.dart';
import 'llm_client.dart';
import 'session_store.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _Msg {
  _Msg(this.role, this.text);
  final String role; // user | assistant
  String text;
}

class _ChatPageState extends State<ChatPage> {
  static const _ch = MethodChannel('com.xinghuo.sparkshell/pty');

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _scaffold = GlobalKey<ScaffoldState>();
  final List<_Msg> _msgs = [];

  ApiConfig? _cfg;
  SessionStore? _store;
  Session? _session;
  List<Session> _sessions = const [];
  LlmClient? _client;
  StreamSubscription<String>? _sub;
  String? _filesDir;
  bool _busy = false;
  bool _agent = false;
  bool _autoApprove = false;
  String? _err;

  /// 上一条真正发出去的内容，失败后「重试」用它。
  String? _lastTry;

  /// 重试进度文案（「连接不稳定，正在重试 2/5…」），成功后清空。
  String? _status;

  /// 终端输入条来的问题
  StreamSubscription<String>? _aiSub;
  String? _lastAsk;
  DateTime _lastAskAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 把 HTTP 错误翻译成人话：免费模型 429 不是崩溃，是额度/限流。
  String _friendly(Object e) {
    final t = '$e';
    if (t.contains('429')) {
      if (t.contains('free')) {
        return '免费模型额度用完了（429）。去右上角设置换一个模型，或等 1 分钟再发。';
      }
      return '请求太频繁被限流（429），等几十秒再试。';
    }
    if (t.contains('401') || t.contains('403')) {
      return 'Key 无效、过期或被风控（401/403）：去右上角设置确认是七牛云的 key，模型写 qiniu/conatus-free。';
    }
    if (RegExp(r'\b5\d\d\b').hasMatch(t)) {
      return '接入点抖动（5xx，已按同一模型重试 5 次，仍未成功）：免费模型这会儿在排队或中转源站超时，'
          '不是你的 Key 坏了。等 20-30 秒点「重试」，多半就通。';
    }
    if (t.contains('SocketException') || t.contains('timeout')) {
      return '连不上模型服务（超时）：先确认手机网络，再点「重试」；同一接入点重试几次通常能过。';
    }
    return t;
  }

  @override
  void initState() {
    super.initState();
    AppBus.pendingChatFile.addListener(_takePendingFile);
    _aiSub = TerminalBus.instance.aiRequests.listen((q) {
      if (!mounted) return;
      final now = DateTime.now();
      // 连点两次发送 / 双通道回放会让同一句进来两遍，3 秒内只处理一次
      if (q == _lastAsk && now.difference(_lastAskAt) < const Duration(seconds: 3)) {
        TerminalBus.instance.mirror('\x1b[90m（同一条请求刚发过，已忽略重复）\x1b[0m\r\n');
        return;
      }
      _lastAsk = q;
      _lastAskAt = now;
      _input.text = q;
      if (!_agent) setState(() => _agent = true);
      _send();
    });
    _boot();
  }

  /// 文件页长按「发给 Agent」后，把 @路径 插到输入框末尾。
  void _takePendingFile() {
    final p = AppBus.pendingChatFile.value;
    if (p == null) return;
    AppBus.pendingChatFile.value = null;
    final cur = _input.text;
    final sep = (cur.isEmpty || cur.endsWith(' ')) ? '' : ' ';
    _input.text = '$cur$sep@$p ';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    _filesDir = await _ch.invokeMethod<String>('filesDir');
    if (_filesDir == null) return;
    final cfg = await ApiConfig.load(_filesDir!);
    final store = SessionStore('$_filesDir/sessions');
    _store = store;
    var all = await store.list();
    if (all.isEmpty) all = [await store.create()];
    await store.prune(keep: 60);
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _sessions = all;
      _session = all.first;
      _msgs
        ..clear()
        ..addAll(all.first.messages.map((m) => _Msg('${m['role']}', '${m['content'] ?? ''}')));
    });
  }

  /// 把当前气泡写回会话并落盘（每条消息后调一次，崩溃最多丢一条）。
  Future<void> _persist() async {
    final store = _store;
    final s = _session;
    if (store == null || s == null) return;
    s.messages
      ..clear()
      ..addAll(_msgs.map((m) => <String, dynamic>{'role': m.role, 'content': m.text}));
    if (s.title == '新会话' && _msgs.isNotEmpty) {
      final t = _msgs.first.text.replaceAll('\n', ' ').trim();
      if (t.isNotEmpty) s.title = t.length > 20 ? '${t.substring(0, 20)}…' : t;
    }
    await store.save(s);
    if (mounted) setState(() => _sessions = [s, ..._sessions.where((e) => e.id != s.id)]);
  }

  Future<void> _newSession() async {
    final store = _store;
    if (store == null) return;
    final s = await store.create();
    if (!mounted) return;
    setState(() {
      _session = s;
      _msgs.clear();
      _err = null;
      _sessions = [s, ..._sessions];
    });
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.pop(context);
  }

  void _openSession(Session s) {
    setState(() {
      _session = s;
      _msgs
        ..clear()
        ..addAll(s.messages.map((m) => _Msg('${m['role']}', '${m['content'] ?? ''}')));
      _err = null;
    });
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.pop(context);
  }

  Future<void> _deleteSession(Session s) async {
    await _store?.delete(s.id);
    final rest = _sessions.where((e) => e.id != s.id).toList();
    if (!mounted) return;
    setState(() => _sessions = rest);
    if (_session?.id == s.id) {
      if (rest.isEmpty) {
        await _newSession();
      } else {
        _openSession(rest.first);
      }
    }
  }

  Widget _drawer(BuildContext context) => Drawer(
        child: SafeArea(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: const Text('新建会话'),
              onTap: _newSession,
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: _sessions.length,
                itemBuilder: (_, i) {
                  final s = _sessions[i];
                  return ListTile(
                    dense: true,
                    selected: s.id == _session?.id,
                    title: Text(
                      _store?.preview(s) ?? s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '${s.messages.length} 条 · ${_ago(s.updatedAt)}',
                      style: const TextStyle(fontSize: 10),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => _deleteSession(s),
                    ),
                    onTap: () => _openSession(s),
                  );
                },
              ),
            ),
          ]),
        ),
      );

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _client?.dispose();
    AppBus.pendingChatFile.removeListener(_takePendingFile);
    _aiSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final cfg = _cfg;
    if (text.isEmpty || cfg == null || _busy) return;
    if (!cfg.ready) {
      const msg = '还没填 API Key：点 Chat 右上角齿轮，填七牛云的 key（base https://api.qnaigc.com/v1）';
      setState(() => _err = msg);
      TerminalBus.instance.mirror('\x1b[31m✗ $msg\x1b[0m\r\n');
      return;
    }
    _input.clear();
    _lastTry = text;
    if (_agent) {
      await _sendAgent(text, cfg);
      return;
    }
    final reply = _Msg('assistant', '');
    setState(() {
      _msgs.add(_Msg('user', text));
      _msgs.add(reply);
      _busy = true;
      _err = null;
    });
    _toBottom();

    final history = _msgs
        .where((m) => m.text.isNotEmpty)
        .map((m) => {'role': m.role, 'content': m.text})
        .toList();

    final client = _client = LlmClient(
      cfg,
      onRetry: (m) {
        if (mounted) setState(() => _status = m);
      },
    );
    final buf = StringBuffer();
    final done = Completer<void>();
    _sub = client.chat(history).listen(
      (delta) {
        buf.write(delta);
        setState(() => reply.text = buf.toString());
        _toBottom();
      },
      onError: (Object e) {
        final m = _friendly(e);
        setState(() => _err = m);
        TerminalBus.instance.mirror('\x1b[31m✗ $m\x1b[0m\r\n');
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future;
    if (mounted) {
      setState(() {
        _busy = false;
        _status = null;
      });
    }
    await _persist();
  }

  /// Agent 模式：模型要工具 → 弹窗审批 → 容器内执行 → 结果回灌。
  Future<void> _sendAgent(String text, ApiConfig cfg) async {
    setState(() {
      _msgs.add(_Msg('user', text));
      _busy = true;
      _err = null;
    });
    _toBottom();

    if (!LinuxEnv.instance.isReady) {
      setState(() => _msgs.add(_Msg('tool', '准备容器…')));
      final script = await LinuxEnv.instance.ensureReady((l) {
        if (mounted) setState(() => _msgs.add(_Msg('tool', l)));
      });
      if (script == null) {
        const m = '容器没准备好，先去 Linux 页看一眼';
        setState(() {
          _busy = false;
          _err = m;
        });
        TerminalBus.instance.mirror('\x1b[31m✗ $m\x1b[0m\r\n');
        return;
      }
    }

    final history = _msgs
        .where((m) => m.role != 'tool' && m.text.trim().isNotEmpty)
        .map((m) => <String, dynamic>{'role': m.role, 'content': m.text})
        .toList();

    final runner = AgentRunner(
      cfg: cfg,
      onStatus: (m) {
        if (mounted) setState(() => _status = m);
      },
      onText: (t) {
        if (!mounted) return;
        setState(() => _msgs.add(_Msg('assistant', t)));
        _toBottom();
        // 一个入口：回答也落到终端屏幕上
        if (TerminalBus.instance.live) {
          final flat = t.replaceAll('\n', ' ').trim();
          TerminalBus.instance.mirror(
              '\x1b[35m🤖\x1b[0m ${flat.length > 400 ? '${flat.substring(0, 400)}…' : flat}\r\n');
        }
      },
      onToolResult: (t) {
        if (!mounted) return;
        setState(() => _msgs.add(_Msg('tool', t)));
        _toBottom();
      },
      approve: _approve,
    );

    try {
      await runner.run(history);
    } catch (e) {
      if (mounted) {
        final m = _friendly(e);
        setState(() => _err = m);
        TerminalBus.instance.mirror('\x1b[31m✗ $m\x1b[0m\r\n');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
      await _persist();
    }
  }

  Future<bool> _approve(String name, Map<String, dynamic> args) async {
    if (_autoApprove) return true;
    final body = jsonEncode(args);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('允许执行 $name ？'),
        content: SingleChildScrollView(
          child: Text(
            body.length > 600 ? '${body.substring(0, 600)}…' : body,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('拒绝')),
          TextButton(
            onPressed: () {
              _autoApprove = true;
              Navigator.pop(ctx, true);
            },
            child: const Text('全部允许'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('允许')),
        ],
      ),
    );
    return ok ?? false;
  }


  /// 把当前对话导出成 JSON，落在容器的 /root/share 下，用文件页「导出」就能拿到手机里。
  Future<void> _exportSession() async {
    final root = LinuxEnv.instance.rootfsPath;
    if (root == null) {
      setState(() => _err = '容器还没准备好，先去 Linux 页看一眼');
      return;
    }
    try {
      final dir = Directory('$root/root/share');
      await dir.create(recursive: true);
      final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final f = File('${dir.path}/chat-$ts.json');
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'app': 'SparkShell',
          'version': '2.0.0',
          'exportedAt': DateTime.now().toIso8601String(),
          'model': _cfg?.model ?? '',
          'messages': _msgs.map((m) => {'role': m.role, 'text': m.text}).toList(),
        }),
        flush: true,
      );
      final name = f.uri.pathSegments.last;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 /root/share/$name（${_msgs.length} 条消息）')),
      );
    } catch (e) {
      if (mounted) setState(() => _err = '导出失败：$e');
    }
  }

  Future<void> _settings() async {
    final cfg = _cfg;
    if (cfg == null) return;
    final base = TextEditingController(text: cfg.baseUrl);
    final key = TextEditingController(text: cfg.apiKey);
    final model = TextEditingController(text: cfg.model);
    final sys = TextEditingController(text: cfg.systemPrompt);
    final bak = TextEditingController(
      text: cfg.backups
          .map((e) => '${e['baseUrl']}|${e['apiKey']}|${e['model']}')
          .join('\n'),
    );
    var temp = cfg.temperature;
    String? test;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('模型设置'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: base,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://api.qnaigc.com/v1',
                ),
              ),
              TextField(
                controller: key,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API Key'),
              ),
              TextField(
                controller: model,
                decoration: const InputDecoration(
                  labelText: '模型',
                  hintText: 'qiniu/conatus-free',
                ),
              ),
              TextField(
                controller: bak,
                maxLines: 3,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: '备用接入点（可选）',
                  hintText: 'https://备份站/v1|sk-xxx|模型名\n一行一个；主接入点 5xx 时自动切过去',
                ),
              ),
              TextField(
                controller: sys,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '系统提示'),
              ),
              Row(children: [
                const Text('温度'),
                Expanded(
                  child: Slider(
                    value: temp,
                    min: 0,
                    max: 1,
                    divisions: 10,
                    label: temp.toStringAsFixed(1),
                    onChanged: (v) => setS(() => temp = v),
                  ),
                ),
              ]),
              if (test != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(test!, style: const TextStyle(fontSize: 12)),
                ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final c = ApiConfig(
                  baseUrl: base.text,
                  apiKey: key.text,
                  model: model.text,
                  systemPrompt: sys.text,
                  temperature: temp,
                );
                setS(() => test = '测试中…');
                try {
                  final r = await LlmClient(c).ping();
                  setS(() => test = '✅ $r');
                } catch (e) {
                  setS(() => test = '❌ $e');
                }
              },
              child: const Text('测试连接'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                cfg
                  ..baseUrl = base.text.trim()
                  ..apiKey = key.text.trim()
                  ..model = model.text.trim()
                  ..systemPrompt = sys.text
                  ..temperature = temp;
                // 备用接入点：一行 `baseUrl|key|model`，空行忽略
                cfg.backups
                  ..clear()
                  ..addAll(bak.text
                      .split('\n')
                      .map((l) => l.trim())
                      .where((l) => l.isNotEmpty && l.contains('|'))
                      .map((l) {
                    final p = l.split('|');
                    return {
                      'baseUrl': p.isNotEmpty ? p[0].trim() : '',
                      'apiKey': p.length > 1 ? p[1].trim() : '',
                      'model': p.length > 2 ? p[2].trim() : cfg.model,
                    };
                  }));
                if (_filesDir != null) await cfg.save(_filesDir!);
                _client?.dispose();
                _client = null;
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) setState(() {});
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 卡片标题：工具输出的第一行（通常是「[exit 0]」或「已写入 xxx」）
  static String _toolTitle(String text) {
    final first = text.split('\n').first.trim();
    if (first.isEmpty) return '工具输出';
    return first.length > 80 ? '${first.substring(0, 80)}…' : first;
  }

  /// 工具结果里带 diff（@@ / + / -）时，按行上色，改了什么一眼看得见。
  static TextSpan _toolSpan(String text) {
    final spans = <TextSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      Color? color;
      if (l.startsWith('@@')) {
        color = const Color(0xFF7FB2F0);
      } else if (l.startsWith('+')) {
        color = const Color(0xFF6FCF97);
      } else if (l.startsWith('-')) {
        color = const Color(0xFFEB8A8A);
      }
      spans.add(TextSpan(text: i == lines.length - 1 ? l : '$l\n', style: TextStyle(color: color)));
    }
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _cfg;
    return Scaffold(
      key: _scaffold,
      drawer: _drawer(context),
      appBar: AppBar(
        title: Text(cfg == null ? 'Chat' : 'Chat · ${cfg.model}'),
        actions: [
          IconButton(
            tooltip: _agent ? 'Agent 模式：开' : 'Agent 模式：关',
            onPressed: () => setState(() => _agent = !_agent),
            icon: Icon(_agent ? Icons.smart_toy : Icons.smart_toy_outlined),
            color: _agent ? Theme.of(context).colorScheme.primary : null,
          ),
          IconButton(
            tooltip: '导出会话',
            onPressed: _exportSession,
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(onPressed: _settings, icon: const Icon(Icons.settings)),
        ],
      ),
      body: Column(children: [
        if (_status != null && _busy)
          Container(
            width: double.infinity,
            color: Colors.amber.withOpacity(0.12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(children: [
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: 8),
              Text(_status!, style: const TextStyle(fontSize: 11)),
            ]),
          ),
        if (_err != null)
          Container(
            width: double.infinity,
            color: Colors.red.withOpacity(0.15),
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(_err!, style: const TextStyle(fontSize: 12)),
                ),
                if (_lastTry != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            _input.text = _lastTry!;
                            _send();
                          },
                    child: const Text('重试', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _msgs.isEmpty
              ? Center(
                  child: Text(
                    cfg == null
                        ? '读取配置…'
                        : (cfg.ready
                            ? (_agent ? 'Agent 模式：让它改文件、跑命令' : '说点什么')
                            : '点右上角设置填 API Key'),
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _msgs.length,
                  itemBuilder: (_, i) {
                    final m = _msgs[i];
                    final mine = m.role == 'user';
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        constraints: const BoxConstraints(maxWidth: 320),
                        decoration: BoxDecoration(
                          color: m.role == 'tool'
                              ? Theme.of(context).colorScheme.surfaceContainerLow
                              : mine
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: m.role == 'tool'
                            ? ToolResultCard(
                                title: _toolTitle(m.text),
                                text: m.text,
                              )
                            : SelectableText(
                                m.text.isEmpty ? '…' : m.text,
                                style: const TextStyle(fontSize: 13, height: 1.4),
                              ),
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: '输入消息…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _busy
                  ? IconButton.filled(
                      onPressed: () {
                        _sub?.cancel();
                        setState(() => _busy = false);
                      },
                      icon: const Icon(Icons.stop),
                    )
                  : IconButton.filled(
                      onPressed: _send,
                      icon: const Icon(Icons.send),
                    ),
            ]),
          ),
        ),
      ]),
    );
  }
}
