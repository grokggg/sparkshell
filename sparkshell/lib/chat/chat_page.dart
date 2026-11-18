import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/agent_runner.dart';
import '../app_bus.dart';
import '../linux_env.dart';
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

  /// 把 HTTP 错误翻译成人话：免费模型 429 不是崩溃，是额度/限流。
  String _friendly(Object e) {
    final t = '$e';
    if (t.contains('429')) {
      if (t.contains('free')) {
        return '免费模型额度用完了（429）。去右上角设置换一个模型，或等 1 分钟再发。';
      }
      return '请求太频繁被限流（429），等几十秒再试。';
    }
    if (t.contains('401')) return 'API Key 无效或过期（401），去设置里重新填。';
    if (t.contains('522') || t.contains('523') || t.contains('524')) {
      return '接入点网关超时（$e）。已自动重试 3 次：中转站源站没响应，'
          '换一个接入点或模型再发；点右边「重试」也可以。';
    }
    if (RegExp(r'HTTP 5\d\d').hasMatch(t)) {
      return '模型服务端故障（$e），已自动重试 3 次。稍等一会儿或换模型。';
    }
    if (t.contains('SocketException') || t.contains('timeout')) return '网络连不上模型服务，检查网络或换个接入点。';
    return t;
  }

  @override
  void initState() {
    super.initState();
    AppBus.pendingChatFile.addListener(_takePendingFile);
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
      setState(() => _err = '还没填 API Key，点右上角设置');
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

    final client = _client = LlmClient(cfg);
    final buf = StringBuffer();
    final done = Completer<void>();
    _sub = client.chat(history).listen(
      (delta) {
        buf.write(delta);
        setState(() => reply.text = buf.toString());
        _toBottom();
      },
      onError: (Object e) {
        setState(() => _err = _friendly(e));
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    await done.future;
    if (mounted) setState(() => _busy = false);
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
        setState(() {
          _busy = false;
          _err = '容器没准备好，先去 Linux 页看一眼';
        });
        return;
      }
    }

    final history = _msgs
        .where((m) => m.role != 'tool' && m.text.trim().isNotEmpty)
        .map((m) => <String, dynamic>{'role': m.role, 'content': m.text})
        .toList();

    final runner = AgentRunner(
      cfg: cfg,
      onText: (t) {
        if (!mounted) return;
        setState(() => _msgs.add(_Msg('assistant', t)));
        _toBottom();
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
      if (mounted) setState(() => _err = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
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

  Future<void> _settings() async {
    final cfg = _cfg;
    if (cfg == null) return;
    final base = TextEditingController(text: cfg.baseUrl);
    final key = TextEditingController(text: cfg.apiKey);
    final model = TextEditingController(text: cfg.model);
    final sys = TextEditingController(text: cfg.systemPrompt);
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
                  hintText: 'https://api.deepseek.com/v1',
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
                  hintText: 'deepseek-chat / qwen-plus / gpt-4o-mini',
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
          IconButton(onPressed: _settings, icon: const Icon(Icons.settings)),
        ],
      ),
      body: Column(children: [
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
                            ? SelectableText.rich(
                                _toolSpan(m.text.isEmpty ? '…' : m.text),
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.4,
                                  fontFamily: 'monospace',
                                ),
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
