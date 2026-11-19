import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/agent_runner.dart';
import '../agent/approval.dart';
import '../agent/cancel_token.dart';
import '../app_bus.dart';
import '../linux_env.dart';
import '../agent/tools.dart';
import '../app_version.dart';
import '../skills/skill_store.dart';
import '../skills/skill_tools.dart';
import '../update/updater.dart';
import '../term/terminal_bus.dart';
import 'tool_card.dart';
import 'tool_row.dart';
import 'api_config.dart';
import 'vision.dart';
import 'attach.dart';
import 'llm_client.dart';
import 'session_store.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _Msg {
  _Msg(this.role, this.text, {this.tool, this.args, this.ok = true, this.ms = 0});

  final String role; // user | assistant | tool
  String text;

  /// 非空表示这是一条结构化工具调用（渲染成一行），空则是普通提示文字
  final String? tool;
  final Map<String, dynamic>? args;
  final bool ok;
  final int ms;
}

class _ChatPageState extends State<ChatPage> {
  static const _ch = MethodChannel('com.xinghuo.sparkshell/pty');

  final _input = TextEditingController();

  /// 本轮待发送的附件（容器内路径）。发出去就清空，避免下一句又被带上。
  final List<String> _pending = <String>[];
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
  bool _agent = true;
  bool _autoApprove = false;
  String? _err;

  /// 上一条真正发出去的内容，失败后「重试」用它。
  String? _lastTry;

  /// 重试进度文案（「连接不稳定，正在重试 2/5…」），成功后清空。
  String? _status;

  /// 本轮取消令牌：每轮发送重建一个，停止后旧的自然作废。
  CancelToken? _token;

  /// 用户点过停止：本轮不再插入任何额外气泡，
  /// 只保留 Agent 自己写的那条「⏹ 已按你的要求停止」。
  bool _stopNote = false;

  /// 上面那条提示是否已经落到对话里（停止恰好卡在两轮之间时 run 里没人写，就在收尾时补一条）
  bool _stopShown = false;

  /// 正在收尾：按钮已经回到「发送」，旧 run 还没退出，状态条继续显示「正在停止…」。
  bool _stopping = false;

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
      return '请求太频繁被限流（429）。免费额度是全网共用的，等 30-60 秒再点重试通常就过。';
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
    // 页面销毁时把在途请求也掐掉，别让 socket 挂到 90 秒超时
    _token?.cancel();
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

  String _compose(String typed) => composeWithAttachments(typed, _pending);

  /// + 号：系统相册 / 文件管理器，选完复制进 /root/inbox。
  Future<void> _pickAttach({required bool images}) async {
    try {
      final got = images
          ? await AttachmentPicker.images()
          : await AttachmentPicker.files();
      if (!mounted || got.isEmpty) return;
      setState(() {
        for (final p in got) {
          if (!_pending.contains(p)) _pending.add(p);
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 拍一张：原生相机拍完直接复制进容器，回来当附件使。
  Future<void> _takePhoto() async {
    try {
      final path = await AttachmentPicker.camera();
      if (!mounted || path == null || path.isEmpty) return;
      setState(() {
        if (!_pending.contains(path)) _pending.add(path);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 附件条：显示在输入框上方，发出去之前一直可见，点 × 摘掉。
  Widget _attachStrip() {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: _pending.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final name = _pending[i].split('/').last;
          return InputChip(
            label: Text(name, style: const TextStyle(fontSize: 12)),
            avatar: const Icon(Icons.insert_drive_file_outlined, size: 16),
            visualDensity: VisualDensity.compact,
            onDeleted: () => setState(() => _pending.removeAt(i)),
          );
        },
      ),
    );
  }

  /// + 号弹层：图片 / 文件。这两个是所有人的第一直觉，别再让人手打 @ 路径。
  Future<void> _showAttachSheet() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('图片'),
            subtitle: const Text('从相册选，可多张'),
            onTap: () => Navigator.pop(ctx, 'images'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('拍一张'),
            subtitle: const Text('用相机拍完直接发'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: const Text('文件'),
            subtitle: const Text('文档、压缩包、音频…'),
            onTap: () => Navigator.pop(ctx, 'files'),
          ),
        ]),
      ),
    );
    if (picked == null) return;
    if (picked == 'camera') {
      await _takePhoto();
      return;
    }
    await _pickAttach(images: picked == 'images');
  }

  /// 把这一轮的图片塞进「最后一条 user 消息」的 content。
  ///
  /// 为什么一定要改最后一条、而不是追加一条新消息：
  /// 模型看到的是完整历史，追加会变成"用户又单独说了一句图"，问句和图脱节，
  /// 更容易答偏。图本来就是那句话的一部分。
  Future<void> _applyVision(
    List<Map<String, dynamic>> history,
    String text,
    List<String> images,
  ) async {
    if (images.isEmpty || history.isEmpty) return;
    final content = await buildUserContent(
      text,
      images,
      onReject: (path, reason) {
        final name = path.split('/').last;
        if (mounted) {
          setState(() => _err = '图片没带上：$name —— $reason');
        }
      },
    );
    replaceLastUserContent(history, content);
  }

  /// 接入点看不了图、已经自动去掉图片重发时，必须让用户知道。
  /// 否则他以为自己发了截图，模型却在答「你什么都没说」。
  void _onVisionFallback(String message) {
    if (!mounted) return;
    setState(() => _err = message);
    TerminalBus.instance.mirror('\x1b[33m! $message\x1b[0m\r\n');
  }

  Future<void> _send() async {
    final typed = _input.text.trim();
    final cfg = _cfg;
    // 只发附件、不写字也算一条：手机上「发张图问问」不该逼人再补一句。
    if ((typed.isEmpty && _pending.isEmpty) || cfg == null || _busy) return;
    final text = _compose(typed);
    // 图片单独记一份：_pending 发完就清空了，而这一轮要拿它决定
    // ①content 里塞不塞 image_url ②要不要开 vision 降级通道
    final images = _pending.where(isImagePath).toList(growable: false);
    if (!cfg.ready) {
      const msg = '还没填 API Key：点 Chat 右上角齿轮，填七牛云的 key（base https://api.qnaigc.com/v1）';
      setState(() => _err = msg);
      TerminalBus.instance.mirror('\x1b[31m✗ $msg\x1b[0m\r\n');
      return;
    }
    _input.clear();
    if (_pending.isNotEmpty) setState(_pending.clear);
    _lastTry = text;
    // 新一轮：令牌必须重建。上一轮那颗已经 cancel 过，永远保持 isCancelled，
    // 复用会让这一轮第一步就被判成「已停止」。
    _token?.cancel();
    final token = _token = CancelToken();
    _stopNote = false;
    _stopShown = false;
    _stopping = false;
    if (_agent) {
      await _sendAgent(text, cfg, token, images);
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
        .map((m) => <String, dynamic>{'role': m.role, 'content': m.text})
        .toList();
    await _applyVision(history, text, images);

    final client = _client = LlmClient(
      cfg,
      vision: images.isNotEmpty,
      modelOverride: cfg.modelFor(hasImages: images.isNotEmpty),
      onVisionFallback: _onVisionFallback,
      onRetry: (m) {
        if (mounted) setState(() => _status = m);
      },
    );
    final buf = StringBuffer();
    final done = Completer<void>();
    // 停止时我们会 cancel 掉订阅，而 StreamSubscription.cancel() 不触发 onDone，
    // 这里挂一颗令牌兜底完成，_send 才不会永远挂在 await 上（那样这轮也不会落盘）
    unawaited(token.whenCancelled.then((_) {
      if (!done.isCompleted) done.complete();
    }));
    _sub = client.chat(history, cancel: token).listen(
      (delta) {
        // 已点停止：晚到的增量不再往气泡里写
        if (token.isCancelled) return;
        buf.write(delta);
        setState(() => reply.text = buf.toString());
        _toBottom();
      },
      onError: (Object e) {
        // 主动停止时 socket 被拆，抛出来的异常不算错误，别弹红条
        if (token.isCancelled) {
          if (!done.isCompleted) done.complete();
          return;
        }
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
    // 只在「还是这一轮」时收尾：用户已经点停止并发了新消息的话，
    // 这里再去改 _busy 会把新一轮的状态打乱
    if (mounted && identical(_token, token)) {
      setState(() {
        _busy = false;
        _stopping = false;
        _status = null;
      });
    }
    await _persist();
  }

  /// 停止：先把令牌打掉 + 断 socket，再改 UI。
  ///
  /// 顺序很重要——`cancel()` 会同步触发 LlmClient 里的 `close(force: true)`，
  /// 在途 HTTP 立刻断开；UI 这边不用等它，先放开输入框，
  /// 状态条留一句「正在停止…」直到 run 真正退出。
  void _stopAgent() {
    _token?.cancel();
    _sub?.cancel();
    if (!mounted) return;
    setState(() {
      _stopNote = true;
      _busy = false;
      _stopping = true;
      _status = '正在停止…';
      _err = null;
    });
    _toBottom();
  }

  /// Agent 模式：模型要工具 → 弹窗审批 → 容器内执行 → 结果回灌。
  Future<void> _sendAgent(
    String text,
    ApiConfig cfg,
    CancelToken token, [
    List<String> images = const <String>[],
  ]) async {
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
          _stopping = false;
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
    await _applyVision(history, text, images);

    final runner = AgentRunner(
      cfg: cfg,
      cancel: token,
      vision: images.isNotEmpty,
      modelOverride: cfg.modelFor(hasImages: images.isNotEmpty),
      onVisionFallback: _onVisionFallback,
      onStatus: (m) {
        // 停止后的「正在停止…」不覆盖：旧 run 可能在收尾时回调一条重试文案
        if (mounted && identical(_token, token)) setState(() => _status = m);
      },
      onText: (t) {
        if (!mounted) return;
        // 旧一轮（已被新消息顶替）的迟到回调一律丢弃
        if (!identical(_token, token)) return;
        // 点过停止之后不再插新气泡：run 里已经写过「⏹ 已按你的要求停止」
        if (_stopNote || token.isCancelled) return;
        setState(() => _msgs.add(_Msg('assistant', t)));
        _toBottom();
        // 一个入口：回答也落到终端屏幕上
        if (TerminalBus.instance.live) {
          final flat = t.replaceAll('\n', ' ').trim();
          TerminalBus.instance.mirror(
              '\x1b[35m🤖\x1b[0m ${flat.length > 400 ? '${flat.substring(0, 400)}…' : flat}\r\n');
        }
      },
      onTool: (e) {
        if (!mounted) return;
        if (!identical(_token, token)) return;
        if (_stopNote) return;
        setState(() => _msgs.add(_Msg('tool', e.output,
            tool: e.name, args: e.args, ok: e.ok, ms: e.ms)));
        _toBottom();
      },
      onToolResult: (t) {
        if (!mounted) return;
        if (!identical(_token, token)) return;
        if (t.contains('⏹ 已按你的要求停止')) _stopShown = true;
        setState(() => _msgs.add(_Msg('tool', t)));
        _toBottom();
      },
      approve: (name, args) async {
        // 停止时审批框可能还开着：先关掉它，别让用户对着一个没用的弹窗发呆
        if (token.isCancelled) return false;
        return await _approve(name, args);
      },
    );

    try {
      await runner.run(history);
    } catch (e) {
      // 停止引起的 socket 异常不当错误显示
      if (mounted && !token.isCancelled) {
        final m = _friendly(e);
        setState(() => _err = m);
        TerminalBus.instance.mirror('\x1b[31m✗ $m\x1b[0m\r\n');
      }
    } finally {
      // 只有「还是当前这一轮」才收尾：停止后用户可能已经发了新消息，
      // 旧 run 退出时不能把新一轮的 _busy/_status 抹掉
      if (identical(_token, token)) {
        if (mounted) {
          setState(() {
            _busy = false;
            _stopping = false;
            _status = null;
          });
          // 停止恰好卡在「上一步刚跑完」的缝隙里时，run 里没有机会写提示，
          // 这里补一条，保证用户一定看得到「已停止」而不是静默结束
          if (_stopNote && !_stopShown) {
            _stopShown = true;
            setState(() => _msgs.add(_Msg('tool', '⏹ 已按你的要求停止')));
            _toBottom();
          }
        }
        _stopNote = false;
      }
      await _persist();
    }
  }

  Future<bool> _approve(String name, Map<String, dynamic> args) async {
    if (_autoApprove) return true;
    // 只读/容器内写不打扰，只有真会出事的那几类才问。
    final req = approvalFor(name, args);
    if (req == null) return true;
    final body = req.snippet;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(req.reason),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 6),
              Text(body, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ],
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


  Widget _pill(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(0.14)),
        ),
        child: Row(children: [
          Icon(icon, size: 13, color: const Color(0xFF9AA7C7)),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 11.5, color: Color(0xFFC9D4EA))),
        ]),
      ),
    );
  }

  /// 上下文占用环：真实按「字符/4」估算，超 80% 变琥珀色提醒。
  Widget _usageRing() {
    final p = _contextUsage();
    final pct = (p * 100).round();
    return Tooltip(
      message: '上下文约 $pct%（按字符估算，窗口 32k）',
      child: SizedBox(
        width: 26,
        height: 26,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: p,
              strokeWidth: 2.4,
              backgroundColor: Colors.white.withOpacity(0.10),
              valueColor: AlwaysStoppedAnimation(
                p > 0.8 ? const Color(0xFFE0A458) : const Color(0xFF7DE2D1),
              ),
            ),
            Text('$pct',
                style: const TextStyle(fontSize: 8.5, color: Color(0xFFB7C4DC))),
          ],
        ),
      ),
    );
  }

  /// 点会话卡改标题（dsh go 那页顶部有个铅笔，作用一样）
  Future<void> _renameSession() async {
    final s = _session;
    if (s == null) return;
    final c = TextEditingController(text: s.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('会话标题'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：装 python 跑脚本'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('保存')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    s.title = name.trim();
    await _store?.save(s);
    if (mounted) setState(() {});
  }

  /// 模型自检：真发一个最小请求，只为了确认「通不通、通多久」。
  Future<void> _pingModel() async {
    final cfg = _cfg;
    if (cfg == null || !cfg.ready) {
      setState(() => _err = '还没填 API Key，点右上角齿轮');
      return;
    }
    setState(() => _status = '正在自检 ${cfg.model}…');
    final sw = Stopwatch()..start();
    try {
      final client = LlmClient(cfg);
      final msg = await client.complete(<Map<String, dynamic>>[
        {'role': 'user', 'content': '请用工具列出 /root 的文件'},
      ], tools: Tools.specs);
      client.dispose();
      sw.stop();
      final ok = (msg['content'] as String?)?.trim().isNotEmpty ?? false;
      setState(() {
        _status = null;
        _err = ok ? null : '模型返回了空内容（接入点通，但模型没吐字）';
      });
      if (!mounted) return;
      final nativeTools = ((msg['tool_calls'] as List?) ?? const []).isNotEmpty;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(!ok
            ? '接入通了但没内容  ·  ${sw.elapsedMilliseconds}ms'
            : nativeTools
                ? '原生工具调用可用  ·  ${cfg.model}  ·  ${sw.elapsedMilliseconds}ms'
                : '这个模型不返回 tool_calls，已自动走文本协议（一样能干活）  ·  ${sw.elapsedMilliseconds}ms'),
      ));
      TerminalBus.instance
          .mirror('\x1b[36m⚙ 自检\x1b[0m ${ok ? 'ok' : '空回复'} ${sw.elapsedMilliseconds}ms\r\n');
    } catch (e) {
      sw.stop();
      final m = _friendly(e);
      setState(() {
        _status = null;
        _err = m;
      });
      TerminalBus.instance.mirror('\x1b[31m✗ 自检失败：$m\x1b[0m\r\n');
    }
  }

  /// 上下文占用估算：按「1 token ≈ 4 字符」粗算，再做保守上限。
  /// 不追求精确，也不预置一个好看的数字——发多少算多少。
  double _contextUsage() {
    var chars = 0;
    for (final m in _msgs) {
      chars += m.text.length;
    }
    final tokens = chars / 4.0;
    const window = 32768.0; // conatus-free 走保守窗口
    return (tokens / window).clamp(0.0, 1.0);
  }

  /// 把当前对话导出成 JSON，落在容器的 /root/share 下，用文件页「导出」就能拿到手机里。

  // ---- 更新与技能：都放在右上角「更多」里，不占主界面 ----

  /// 检查更新 → 下载（带进度、校验 sha256）→ 拉起系统安装器。
  Future<void> _checkUpdate() async {
    final Updater up = Updater();
    UpdateInfo? info;
    var started = false;
    String status = '正在检查…';
    String? error;
    double progress = 0;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> check() async {
            setS(() {
              status = '正在检查…';
              error = null;
            });
            try {
              final UpdateInfo? got = await up.check(
                currentVersion: appVersion,
                currentCode: appCode,
              );
              setS(() {
                info = got;
                status = got == null ? '已经是最新版本（$appVersion）' : '发现新版本 ${got.version}';
              });
            } catch (e) {
              setS(() {
                error = '$e';
                status = '检查失败';
              });
            }
          }

          Future<void> pull() async {
            final UpdateInfo target = info!;
            setS(() {
              status = '正在下载 ${(target.size / 1048576).toStringAsFixed(1)} MB…';
              progress = 0;
            });
            try {
              final String path = await up.download(
                target,
                onProgress: (v) => setS(() => progress = v),
              );
              final DownloadReport? rep = up.lastDownload;
              setS(() {
                status = rep != null && rep.verified
                    ? '下载完成，sha256 校验通过，正在唤起安装器…'
                    : '下载完成（未校验 sha256），正在唤起安装器…';
              });
              final bool ok = await up.install(path);
              if (!mounted) return;
              setS(() => status = ok ? '安装器已打开，按系统提示完成安装' : '安装器没有打开');
            } catch (e) {
              setS(() => error = '$e');
            }
          }

          // 首帧就自动查一次，用户不用先点「重试」
          if (!started) {
            started = true;
            Future<void>.microtask(check);
          }

          final bool hasUpdate = info != null;
          return AlertDialog(
            title: Text(status),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前版本 $appVersion（$appCode）', style: const TextStyle(fontSize: 12, color: Color(0xFF5B6884))),
                if (hasUpdate && (info!.notes).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: Text(info!.notes, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
                if (progress > 0 && progress < 1) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: progress),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(fontSize: 12, color: Color(0xFFC0392B))),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('关闭')),
              if (error != null || (!hasUpdate && info == null))
                TextButton(onPressed: check, child: const Text('重试')),
              if (hasUpdate)
                FilledButton(onPressed: pull, child: Text('下载并安装 ${info!.version}')),
            ],
          );
        },
      ),
    );
  }

  /// 技能库：看看现在装了哪些；空库时一键放个示例，省得用户自己拼 frontmatter。
  Future<void> _showSkills() async {
    String text;
    SkillStore? store;
    try {
      final SkillStore s = await SkillTools.store();
      store = s;
      text = s.all.isEmpty
          ? '还没有技能。\n\n目录：${s.dir}\n'
              '每个技能就是一个目录里的 SKILL.md，开头写 name / description，正文写步骤。\n'
              '放进去立刻生效，AI 用 skill_list 就能看到——不用重装。'
          : s.all
              .map((e) => '${e.name}\n  ${e.description}\n  ${e.allowedTools.isEmpty ? "工具不限" : e.allowedTools.join(", ")}')
              .join('\n\n');
    } catch (e) {
      text = '读技能库失败：$e';
    }
    if (!mounted) return;
    final bool empty = store != null && store.all.isEmpty;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已装技能'),
        content: SingleChildScrollView(child: Text(text, style: const TextStyle(fontSize: 12.5))),
        actions: [
          if (empty)
            TextButton(
              onPressed: () async {
                try {
                  await store!.install('debian-toolchain', _sampleSkill); // empty==true 时 store 必非空
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                  await _showSkills();
                } catch (e) {
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('放入失败：$e')));
                }
              },
              child: const Text('放入示例技能'),
            ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 示例技能：不是凑数，是示范「给模型写说明书」的正确颗粒度——
  /// 先判发行版，再装，最后自检；这三步不写清，模型就会在 Alpine 上敲 apt-get。
  static const String _sampleSkill = '''
---
name: debian-toolchain
description: 在容器里装 python3/git/curl，先判发行版再选包管理器，装完自检
allowed-tools: bash, read_file
tags: debian, alpine, toolchain
---

# 装工具链

1. 先确认发行版，不要猜：
   \`grep ^ID= /etc/os-release\`
   - `ID=alpine` → `apk add --no-cache python3 git curl`
   - `ID=debian` → `apt-get update && apt-get install -y python3 git curl`
2. 注意：Alpine 上 `command -v apt-get` 有时能命中空壳，判定只看 os-release。
3. 装完必须自检，三条都要有输出：
   \`python3 -V && git --version && curl --version | head -1\`
4. 如果 apk/apt 报 trigger 相关噪音，不影响使用，把真实错误行挑出来再判断。
''';

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
    final vmodel = TextEditingController(text: cfg.visionModel);
    final sys = TextEditingController(text: cfg.systemPrompt);
    final bak = TextEditingController(
      text: cfg.backups
          .map((e) => '${e['baseUrl']}|${e['apiKey']}|${e['model']}')
          .join('\n'),
    );
    var temp = cfg.temperature;
    String? test;
    // 测试连接：点下去必须立刻有反应——按钮转圈 + 结果就近显示 + SnackBar 兜底。
    // 以前结果塞在整段设置的最底部（滚动区外），点了像没反应。
    var testing = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('模型设置'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (test != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: (test!.startsWith('✅')
                            ? Colors.green
                            : Theme.of(ctx).colorScheme.error)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(test!, style: const TextStyle(fontSize: 12.5)),
                ),
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
                controller: vmodel,
                decoration: const InputDecoration(
                  labelText: '看图模型（可选）',
                  hintText: 'qwen-vl-max / gpt-4o-mini；留空就还是用上面的模型',
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
            ]),
          ),
          actions: [
            TextButton(
              // 测的过程中禁用，避免连点堆出一串请求
              onPressed: testing
                  ? null
                  : () async {
                      final c = ApiConfig(
                        baseUrl: base.text,
                        apiKey: key.text.trim(),
                        model: model.text,
                        systemPrompt: sys.text,
                        temperature: temp,
                      );
                      setS(() {
                        testing = true;
                        test = '测试中…（最多等 20 秒）';
                      });
                      PingResult r;
                      try {
                        r = await LlmClient(c).ping();
                      } catch (e) {
                        r = PingResult(ok: false, message: '请求异常：$e', ms: 0);
                      }
                      if (!ctx.mounted) return;
                      setS(() {
                        testing = false;
                        test = (r.ok ? '✅ ' : '❌ ') + r.message + ' · ${r.ms}ms';
                      });
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text((r.ok ? '连接正常：' : '连接失败：') + r.message),
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    },
              child: testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('测试连接'),
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
                  ..visionModel = vmodel.text.trim()
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

  @override
  Widget build(BuildContext context) {
    final cfg = _cfg;
    return Scaffold(
      key: _scaffold,
      drawer: _drawer(context),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          // ── 顶部：圆形菜单 + 会话卡 + 编辑（对齐 dsh go 那页的形态）
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
            child: Row(children: [
              IconButton(
                tooltip: '会话列表',
                onPressed: () => _scaffold.currentState?.openDrawer(),
                icon: const Icon(Icons.menu, size: 20),
              ),
              Expanded(
                child: InkWell(
                  onTap: _renameSession,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF1F7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _session?.title ?? (cfg == null ? '新会话' : 'Chat · ${cfg.model}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0B1020),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Color(0xFF2FBF71),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _agent ? '本机 · workspace' : '本机 · 纯对话',
                            style: const TextStyle(fontSize: 10.5, color: Color(0xFF5B6884)),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '导出会话',
                onPressed: _exportSession,
                icon: const Icon(Icons.ios_share, size: 18),
              ),
              IconButton(
                tooltip: _agent ? 'Agent 模式：开' : 'Agent 模式：关',
                onPressed: () => setState(() => _agent = !_agent),
                icon: Icon(_agent ? Icons.smart_toy : Icons.smart_toy_outlined, size: 20),
                color: _agent ? const Color(0xFF7DE2D1) : null,
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (v) {
                  if (v == 'update') _checkUpdate();
                  if (v == 'skills') _showSkills();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'update', child: Text('检查更新')),
                  PopupMenuItem(value: 'skills', child: Text('已装技能')),
                ],
              ),
              IconButton(
                onPressed: _settings,
                icon: const Icon(Icons.settings, size: 20),
              ),
            ]),
          ),
        if (_status != null && (_busy || _stopping))
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
                    if (m.tool != null) {
                      // 一次提问里的连续工具调用归成一组，头上一行「已完成 · N 次工具调用」
                      final head = i == 0 || _msgs[i - 1].tool == null;
                      var n = 0;
                      if (head) {
                        for (var k = i; k < _msgs.length && _msgs[k].tool != null; k++) {
                          n++;
                        }
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (head && n > 1)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                              child: Text('已完成 · $n 次工具调用',
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7899))),
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ToolRow(
                              name: m.tool!,
                              args: m.args ?? const {},
                              output: m.text,
                              ok: m.ok,
                              ms: m.ms,
                            ),
                          ),
                        ],
                      );
                    }
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
        // ── 胶囊快捷条（全部是真动作，不做装饰按钮）
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              _pill(Icons.speed, '模型自检', _pingModel),
              const SizedBox(width: 6),
              // 给人看的话，不是给终端看的命令：用户点一下就是一句话，由模型自己决定跑什么
              _pill(Icons.folder_open_outlined, '看文件', () {
                _input.text = '看看 /root 目录里有什么，用一句话说清';
                _input.selection = TextSelection.collapsed(offset: _input.text.length);
              }),
              const SizedBox(width: 6),
              _pill(Icons.restore, '恢复', () {
                final s0 = _session;
                if (s0 != null) _openSession(s0);
              }),
              const SizedBox(width: 6),
              _pill(Icons.timeline, '时间线', () => _scaffold.currentState?.openDrawer()),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_pending.isNotEmpty) _attachStrip(),
              Row(children: [
              IconButton(
                tooltip: '添加图片或文件',
                onPressed: _showAttachSheet,
                icon: const Icon(Icons.add_circle_outline, size: 20),
              ),
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
              const SizedBox(width: 6),
              _usageRing(),
              const SizedBox(width: 4),
              _busy
                  ? IconButton.filled(
                      tooltip: '停止',
                      // 停止要真断 socket：_token.cancel() 会一路传到
                      // HttpClient.close(force: true)，不是只把界面标成空闲
                      onPressed: _stopAgent,
                      icon: const Icon(Icons.stop),
                    )
                  : IconButton.filled(
                      onPressed: _send,
                      icon: const Icon(Icons.send),
                    ),
              ]),
            ]),
          ),
        ),
        ]),
      ),
    );
  }
}
