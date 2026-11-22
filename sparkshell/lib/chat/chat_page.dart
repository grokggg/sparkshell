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
import 'api_endpoint.dart';
import 'context_builder.dart';
import '../memory/memory_store.dart';
import '../plugins/plugin_store.dart';
import '../plugins/gallery.dart';
import '../settings/settings_page.dart';
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
  _Msg(this.role, this.text,
      {this.tool, this.args, this.ok = true, this.ms = 0, this.images = const []});

  final String role; // user | assistant | tool
  String text;

  /// 非空表示这是一条结构化工具调用（渲染成一行），空则是普通提示文字
  final String? tool;
  final Map<String, dynamic>? args;
  final bool ok;
  final int ms;

  /// 用户消息里带的图片（容器内绝对路径）。有值就渲染缩略图，点开能看大图。
  final List<String> images;
}

class _ChatPageState extends State<ChatPage> {
  static const _ch = MethodChannel('com.xinghuo.sparkshell/pty');

  final _input = TextEditingController();

  /// 正在「编辑后重发」的那条消息在 _msgs 里的下标；发出去时从它开始截断。
  int? _editAt;

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

  /// 跨会话记忆：落盘 files/memory.json，每轮把 digest 拼进 system。
  MemoryStore? _mem;

  /// 已装插件：工具名 plugin_<id>，执行时走容器 bash。
  PluginStore? _plug;

  /// 上下文压缩器。模型窗口改不了，能改的是「每次发多少」。
  final ContextBuilder _ctxb = ContextBuilder();
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
    final mem = MemoryStore(_filesDir!);
    await mem.load();
    final plug = PluginStore(_filesDir!);
    await plug.load();
    if (plug.all.isEmpty) {
      // 第一次启动装 3 个最常用的：不留白板，也不硬塞一屏看不懂的。
      for (final p in builtinGallery().take(3)) {
        await plug.install(p);
      }
      await plug.save();
    }
    Tools.plugins = plug;
    final store = SessionStore('$_filesDir/sessions');
    _store = store;
    var all = await store.list();
    if (all.isEmpty) all = [await store.create()];
    await store.prune(keep: 60);
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _mem = mem;
      _plug = plug;
      _sessions = all;
      _session = all.first;
      _msgs
        ..clear()
        ..addAll(all.first.messages.map((m) => _Msg('${m['role']}', '${m['content'] ?? ''}')));
    });
  }

  /// 把「全部气泡 + 长期记忆」压成这一轮真正要发的东西。
  ///
  /// 模型自己的窗口改不了；能做的是发送前裁剪 + 注入记忆，
  /// 这样同一个窗口能装下更长的对话，也不会一开新会话就失忆。
  BuiltContext _buildContext({bool skipToolBubbles = false}) {
    final raw = _msgs
        .where((m) => m.text.isNotEmpty && (!skipToolBubbles || m.role != 'tool'))
        .map((m) => <String, dynamic>{'role': m.role, 'content': m.text})
        .toList();
    return _ctxb.build(
      history: raw,
      memory: _mem?.digest() ?? '',
      systemPrompt: _cfg?.systemPrompt ?? '',
    );
  }

  /// 用户说「记住……」时落一条长期记忆；普通聊天不打扰。
  Future<void> _maybeRemember(String text) async {
    final t = text.trim();
    if (!t.startsWith('记住') && !t.startsWith('记一下')) return;
    final body = t.replaceFirst(RegExp(r'^记住[，,：:]?|^记一下[，,：:]?'), '').trim();
    if (body.isEmpty) return;
    final mem = _mem;
    if (mem == null) return;
    await mem.add(body);
    await mem.save();
    if (mounted) {
      setState(() => _status = '已记住：${body.length > 20 ? '${body.substring(0, 20)}…' : body}');
    }
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
    // 编辑后重发：把这条及之后的消息全丢掉，等于在同一分支上改口，而不是叠一句新的。
    final at = _editAt;
    if (at != null) {
      _editAt = null;
      setState(() {
        if (at < _msgs.length) _msgs.removeRange(at, _msgs.length);
      });
      _persist();
    }
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
      _msgs.add(_Msg('user', text, images: images));
      _msgs.add(reply);
      _busy = true;
      _err = null;
    });
    _toBottom();

    final bctx = _buildContext();
    final history = bctx.messages;
    await _maybeRemember(text);
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
    _sub = client.chat(history, cancel: token, extraSystem: bctx.systemSuffix).listen(
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
      _msgs.add(_Msg('user', text, images: images));
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

    final bctx = _buildContext(skipToolBubbles: true);
    final history = bctx.messages;
    await _maybeRemember(text);
    await _applyVision(history, text, images);

    final runner = AgentRunner(
      extraSystem: bctx.systemSuffix,
      toolsOverride: Tools.specsWithPlugins(),
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


  /// 一条消息能做什么：复制、编辑后重发（只限自己发的）、从这里开分支。
  /// 长按被 SelectableText 的选区手势吃掉，所以再给个明确的三点入口——
  /// 手机上「找不到复制」比多一个按钮更烦。
  void _messageMenu(int i) {
    final m = _msgs[i];
    final mine = m.role == 'user';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('复制'),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: m.text));
              if (!mounted) return;
              Navigator.pop(sheet);
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)));
            },
          ),
          if (mine)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑后重发'),
              subtitle: const Text('从这条开始改，后面的回答会重新生成'),
              onTap: () {
                Navigator.pop(sheet);
                setState(() {
                  _editAt = i;
                  _msgs.removeAt(i);
                });
                _input.text = m.text;
                _input.selection = TextSelection.collapsed(offset: m.text.length);
                _persist();
              },
            ),
          ListTile(
            leading: const Icon(Icons.call_split),
            title: const Text('从这里开分支'),
            subtitle: const Text('带走这条及之前的全部记录，后面互不影响'),
            onTap: () {
              Navigator.pop(sheet);
              _branchAt(i);
            },
          ),
        ]),
      ),
    );
  }

  /// 开分支：新会话复制 [0..i] 的记录，原会话一点不动。
  Future<void> _branchAt(int i) async {
    final store = _store;
    if (store == null) return;
    final cut = (_msgs.length - 1 < i) ? _msgs.length - 1 : i;
    final head = _msgs[0].text.replaceAll('\n', ' ').trim();
    final title = head.isEmpty
        ? '分支'
        : (head.length > 16 ? '${head.substring(0, 16)}… · 分支' : '$head · 分支');
    final s = await store.create(title);
    s.messages.addAll(_msgs
        .take(cut + 1)
        .map((m) => <String, dynamic>{'role': m.role, 'content': m.text}));
    await store.save(s);
    if (!mounted) return;
    setState(() {
      _session = s;
      _msgs
        ..clear()
        ..addAll(s.messages.map((m) => _Msg('${m['role']}', '${m['content'] ?? ''}')));
      _err = null;
      _sessions = [s, ..._sessions.where((e) => e.id != s.id)];
    });
    _toBottom();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已开分支，原会话保留'), duration: Duration(seconds: 2)));
  }

  /// 点缩略图看原图：双指缩放，点空白关掉。
  void _previewImage(String path) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: InteractiveViewer(
          maxScale: 5,
          child: Center(child: Image.file(File(path), fit: BoxFit.contain)),
        ),
      ),
    );
  }

  /// 输入框上方那条「模型 · 思考档」：点一下就能换，不用退回设置页。
  ///
  /// 产品口径：换模型是「选一个名字」，不是「改一个配置项」；
  /// 所以放在手边，一次点击到底。
  Widget _modelBar() {
    final cfg = _cfg;
    if (cfg == null) return const SizedBox.shrink();
    final name = _shortModel(cfg.model);
    final lvl = _reasonLabel(cfg.reasoning);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 6, bottom: 2),
        child: InkWell(
          onTap: _modelSheet,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF1B2231),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2C3648)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.memory, size: 13, color: Color(0xFF8FA0BC)),
              const SizedBox(width: 5),
              Text('$name · $lvl',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFB9C6DC))),
              const Icon(Icons.expand_more, size: 14, color: Color(0xFF8FA0BC)),
            ]),
          ),
        ),
      ),
    );
  }

  String _shortModel(String m) {
    final s = m.contains('/') ? m.split('/').last : m;
    return s.length > 20 ? '${s.substring(0, 20)}…' : s;
  }

  String _reasonLabel(String r) {
    switch (r) {
      case 'off':
        return '不思考';
      case 'low':
        return '低';
      case 'high':
        return '高';
      case 'max':
        return '极高';
      default:
        return '自动';
    }
  }

  static const _reasonOptions = <List<String>>[
    ['auto', '自动'],
    ['off', '不思考'],
    ['low', '低'],
    ['high', '高'],
    ['max', '极高'],
  ];

  /// 模型 + 思考档的底部弹层。
  ///
  /// 三段式，替代原来「一个平铺列表 + 拉取就把几十个名字全灌进去」的做法：
  ///   1. 已固定 —— 用户主动钉住的，永远在，不会被拉取结果冲掉；
  ///   2. 最近用过 —— 真正用过的（lastUsedAt > 0），按时间倒序，最多 12 条；
  ///      末尾再补几条手填过但还没用过的，免得设置页填的模型在这里没有位置；
  ///   3. 接入点拉取 —— 只是候选展示，点右侧「固定」才入库，不入库就不占位置；
  ///   4. 其他接入点 —— 别的 key 名下存过的模型（固定优先 + 最近用过），
  ///      点一条就切到那个 key 并用它，不用先去设置页换 key 再回来找。
  ///      只有一个接入点时这一段整段不出现（那就没有「其他」可言）。
  /// 当前选中的模型一定在列表最前面出现：它若已属于某一段就提到该段首位，
  /// 三段都不属于时单开一条「当前使用」顶在最上面，绝不隐身。
  Future<void> _modelSheet() async {
    final cfg = _cfg;
    final dir = _filesDir;
    if (cfg == null) return;
    var sel = cfg.model;
    var lvl = cfg.reasoning;
    var loading = false;
    var hint = '';

    // 拉取结果只活在这次弹层里：不入库、不覆盖已固定项，也不改旧的 models 字段。
    final pulled = <String>[];
    var pulledCount = 0;

    // 固定/取消固定是「改列表结构」，改完立刻落盘，关掉弹层也不丢。
    Future<void> persist() async {
      if (dir != null) await cfg.save(dir);
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141A24),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final sup = cfg.supportsThinking(sel);
        final vault = cfg.vault;

        // 档案库按 (名字, 接入点) 存，同名可能有多条；展示按名字去重。
        // vault.entries 已按「固定优先、再按最近使用」排序，取第一条的接入点即可。
        final urlOf = <String, String>{};
        for (final e in vault.entries) {
          urlOf.putIfAbsent(e.id, () => e.baseUrl);
        }

        // 1) 已固定：pinned 的项；当前项提到首位，一眼看到「正在用哪个」
        final pinned = <String>[];
        for (final e in vault.entries) {
          if (e.pinned && !pinned.contains(e.id)) pinned.add(e.id);
        }
        if (pinned.remove(sel)) pinned.insert(0, sel);

        // 2) 最近用过：未固定、确实用过（lastUsedAt > 0），按时间倒序，最多 12 条。
        // 后面再补上「手填过但还没用过」的（设置页填的、旧配置迁移来的）：
        // 它们既不在固定区，一般也不在拉取结果里，不给位置就等于换个地方丢模型。
        final used = vault.entries
            .where((e) => !e.pinned && e.lastUsedAt > 0)
            .toList();
        used.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
        final recentAll = <String>[];
        for (final e in used) {
          if (pinned.contains(e.id) || recentAll.contains(e.id)) continue;
          recentAll.add(e.id);
        }
        final unused = <String>[];
        for (final e in vault.entries) {
          if (e.pinned || e.lastUsedAt > 0) continue;
          if (pinned.contains(e.id) ||
              recentAll.contains(e.id) ||
              unused.contains(e.id)) {
            continue;
          }
          unused.add(e.id);
        }
        final recent = recentAll.take(12).toList();
        final unusedShown = unused.take(20).toList();
        recent.addAll(unusedShown);
        if (recent.remove(sel)) recent.insert(0, sel);
        final recentNote = <String>[
          if (recentAll.length > 12) '最近 12 条（共 ${recentAll.length} 个）',
          if (unusedShown.isNotEmpty)
            (unused.length > unusedShown.length
                ? '${unusedShown.length} 个还没用过（共 ${unused.length} 个）'
                : '${unusedShown.length} 个还没用过'),
        ].join(' · ');

        // 3) 拉取候选：上面已经列过的名字不重复显示（同一项出现两遍只会点错）
        final cand = <String>[
          for (final m in pulled)
            if (m != sel && !pinned.contains(m) && !recent.contains(m)) m,
        ];
        final candShown = cand.take(60).toList();

        // 当前项三段都不属于时，单开一条顶在最前，保证它不隐身
        final selListed = pinned.contains(sel) || recent.contains(sel);

        Widget header(String title, {String? note}) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
            child: Row(children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8FA0BC))),
              if (note != null && note.isNotEmpty) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10.5, color: Color(0xFF5C6A82))),
                ),
              ],
            ]),
          );
        }

        Widget emptyLine(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
              child: Text(text,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF5C6A82))),
            );

        // 一行模型：左边永远是对勾位（选中的才有颜色），右边是操作位。
        Widget tile(String id, {Widget? action}) {
          final on = id == sel;
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            horizontalTitleGap: 6,
            minLeadingWidth: 16,
            leading: Icon(
              on ? Icons.check_circle : Icons.circle_outlined,
              size: 15,
              color: on ? const Color(0xFF6FA8FF) : const Color(0xFF39445A),
            ),
            title: Text(id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    color:
                        on ? const Color(0xFFE6EDFA) : const Color(0xFFB9C6DC))),
            subtitle: cfg.supportsThinking(id)
                ? const Text('支持思考',
                    style: TextStyle(fontSize: 11, color: Color(0xFF6FA8FF)))
                : null,
            trailing: action,
            onTap: () => setSheet(() => sel = id),
          );
        }

        // 固定一项：先在它自己的接入点下建档（已存在则只更新），再钉住。
        // 两步都用同一个 baseUrl，否则 vault 会按「同名不同接入点」多存一条。
        Future<void> pinUp(String id) async {
          final url = urlOf[id] ?? cfg.baseUrl;
          vault.add(id, baseUrl: url);
          vault.pin(id, baseUrl: url);
          if (ctx.mounted) setSheet(() {});
          await persist();
        }

        Future<void> unpinUp(String id) async {
          vault.unpin(id, baseUrl: urlOf[id] ?? cfg.baseUrl);
          if (ctx.mounted) setSheet(() {});
          await persist();
        }

        Widget pinIcon(String id) => IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '固定到「已固定」',
              icon: const Icon(Icons.push_pin_outlined,
                  size: 16, color: Color(0xFF8FA0BC)),
              onPressed: () => pinUp(id),
            );

        Widget unpinIcon(String id) => IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '取消固定',
              icon:
                  const Icon(Icons.push_pin, size: 16, color: Color(0xFF6FA8FF)),
              onPressed: () => unpinUp(id),
            );

        Widget pinText(String id) => TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => pinUp(id),
              child: const Text('固定', style: TextStyle(fontSize: 12)),
            );

        Future<void> pull() async {
          setSheet(() => loading = true);
          final got = await LlmClient(cfg).listModels();
          if (!ctx.mounted) return;
          setSheet(() {
            loading = false;
            pulled.clear();
            for (final m in got) {
              final v = m.trim();
              if (v.isNotEmpty && !pulled.contains(v)) pulled.add(v);
            }
            pulledCount = pulled.length;
            hint = pulledCount == 0
                ? '接入点没给出模型列表（可能不支持 /models），可以去设置里手填'
                : '拉到 $pulledCount 个模型，点右侧「固定」才会存进列表';
          });
        }

        final rows = <Widget>[];
        if (!selListed) {
          rows.add(header('当前使用', note: '还没固定，也不在最近用过里'));
          rows.add(tile(sel));
        }

        rows.add(header('已固定',
            note: pinned.isEmpty ? null : '${pinned.length} 个，不会被拉取冲掉'));
        if (pinned.isEmpty) {
          rows.add(emptyLine('还没固定任何模型。用过的会自动进「最近用过」，也可以在下面拉取后点图钉固定。'));
        } else {
          for (final id in pinned) {
            rows.add(tile(id, action: unpinIcon(id)));
          }
        }

        rows.add(header('最近用过',
            note: recentNote.isEmpty ? null : recentNote));
        if (recent.isEmpty) {
          rows.add(emptyLine('用过的模型会出现在这里；设置页手填的也会留在这一区。'));
        } else {
          for (final id in recent) {
            rows.add(tile(id, action: pinIcon(id)));
          }
        }

        rows.add(header('接入点拉取',
            note: (pulledCount == 0 || cand.length <= 60)
                ? null
                : '只列出前 60 个'));
        if (pulledCount == 0) {
          rows.add(emptyLine('点右上角「从接入点拉取」看看这台接入点有哪些模型。结果只在这里做候选，不动上面的列表。'));
        } else if (candShown.isEmpty) {
          rows.add(emptyLine('拉到的模型都已经在上面了。'));
        } else {
          for (final id in candShown) {
            rows.add(tile(id, action: pinText(id)));
          }
        }

        // 4) 其他接入点：别的 key 名下的模型，不用先去设置页换 key 再回来找。
        // 只留 id != 当前接入点的；只有一个 key 时这一段整段不出现，不留空白。
        // activeEndpointId 理论上总被 save() 的 ensureEndpoint 填好，这里仍留个兜底：
        // 空值时按当前 baseUrl 反查，免得把「正在用的这个」也列成「其他」。
        final activeId = cfg.activeEndpointId.trim().isNotEmpty
            ? cfg.activeEndpointId
            : (cfg.currentEndpoint?.id ?? '');
        final others = <ApiEndpoint>[
          for (final ep in cfg.endpoints)
            if (ep.id != activeId) ep,
        ];
        if (others.isNotEmpty) {
          // 分组标题：key 的名字 + 它名下的模型数，比上面三段的段标题低半级。
          Widget groupTitle(ApiEndpoint ep, int n) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
              child: Row(children: [
                const Icon(Icons.key_outlined,
                    size: 12, color: Color(0xFF5C6A82)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(ep.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8FA0BC))),
                ),
                const SizedBox(width: 6),
                Text('$n 个模型',
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFF5C6A82))),
              ]),
            );
          }

          // 其他接入点的一行：点它就是「切 key + 换模型 + 记一次使用 + 落盘 + 关弹层」。
          // 不复用上面的 tile()：那个只改本次弹层的选中项，不切接入点。
          Widget otherTile(ApiEndpoint ep, String id) {
            return ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 12, right: 4),
              horizontalTitleGap: 6,
              minLeadingWidth: 16,
              leading: const Icon(Icons.circle_outlined,
                  size: 13, color: Color(0xFF39445A)),
              title: Text(id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, color: Color(0xFFB9C6DC))),
              onTap: () async {
                // 顺序要紧：先切接入点（换 baseUrl/apiKey），再写 model。
                // 反过来的话 save() 里的 ensureEndpoint 会把这个模型记到旧接入点上，
                // 于是「另一个 key 的模型」又被搬到当前 key 名下 —— 正是要修的那个毛病。
                if (!cfg.useEndpoint(ep.id)) return;
                cfg.model = id;
                ep.model = id; // 下次切回这个 key 时 useEndpoint 能把模型一起恢复
                // 这里传原始 baseUrl 而不是 id：档案库按「用户填的地址原文」分组，
                // 传规范化后的 id 在带结尾斜杠时会认不回来，白白多建一条通用档。
                cfg.vault.markUsed(id, baseUrl: ep.baseUrl);
                if (dir != null) await cfg.save(dir);
                if (mounted) setState(() {});
                if (ctx.mounted) Navigator.pop(ctx);
              },
            );
          }

          // 超出 5 条只报个数，不可点：这里不放「展开」，免得弹层长到要滚半天。
          Widget moreLine(int n) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 4, 2),
                child: Text('还有 $n 个',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF5C6A82))),
              );

          rows.add(header('其他接入点',
              note: '${others.length} 个 key，点模型直接切过去'));
          for (final ep in others) {
            // 只取真正属于这个接入点的条目：通用档（baseUrl 为空）在每个 key 下都算，
            // 全列一遍会让同一串模型在每个分组里重复出现。
            // 用 normalize 比较而不是 forEndpoint：档案里存的是原始 baseUrl，
            // 可能带结尾斜杠，直接等值比会漏掉自己的模型。
            final own = cfg.vault.entries
                .where((e) =>
                    e.baseUrl.isNotEmpty &&
                    ApiEndpoint.normalize(e.baseUrl) == ep.id)
                .toList();
            // 与档案库一致的排序：固定优先，再按最近使用，最后按建档时间。
            own.sort((a, b) {
              if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
              final u = b.lastUsedAt.compareTo(a.lastUsedAt);
              return u != 0 ? u : b.addedAt.compareTo(a.addedAt);
            });
            final names = <String>[];
            for (final e in own) {
              if (!names.contains(e.id)) names.add(e.id);
            }
            final shown = names.take(5).toList();
            rows.add(groupTitle(ep, names.length));
            if (shown.isEmpty) {
              rows.add(emptyLine('这个 key 名下还没存过模型；在设置页填一次它的 key 就会进来。'));
            } else {
              for (final id in shown) {
                rows.add(otherTile(ep, id));
              }
              if (names.length > shown.length) {
                rows.add(moreLine(names.length - shown.length));
              }
            }
          }
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Text('选择模型',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                  onPressed: loading ? null : pull,
                  icon: loading
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 15),
                  label: const Text('从接入点拉取', style: TextStyle(fontSize: 12)),
                ),
              ]),
              if (hint.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(hint,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF8FA0BC))),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: rows,
                ),
              ),
              const Divider(height: 18),
              Row(children: [
                const Text('思考深度', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                Text(sup ? '这个模型吃思考参数' : '名字看不出支持，可手动开',
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF8FA0BC))),
              ]),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final o in _reasonOptions)
                    ChoiceChip(
                      label: Text(o[1], style: const TextStyle(fontSize: 12)),
                      selected: lvl == o[0],
                      onSelected: sup ? (_) => setSheet(() => lvl = o[0]) : null,
                    ),
                ],
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: sup,
                title: const Text('这个模型支持思考', style: TextStyle(fontSize: 12)),
                onChanged: (v) => setSheet(() {
                  // 旧字段留着（设置页仍读它），但 supportsThinking 先看档案库，
                  // 只写 thinkingSupport 会被已有标注盖回去，所以两处一起写。
                  cfg.thinkingSupport[sel] = v;
                  cfg.vault.annotate(sel, v);
                }),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    cfg.model = sel;
                    cfg.vault.markUsed(sel);
                    cfg.reasoning = lvl;
                    if (dir != null) await cfg.save(dir);
                    if (mounted) setState(() {});
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('用这个模型'),
                ),
              ),
            ]),
          ),
        );
      }),
    );
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
      ], tools: Tools.specsWithPlugins());
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
          'version': appVersion,
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
    final dir = _filesDir;
    if (cfg == null || dir == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsPage(
        cfgPath: dir,
        initialTab: 0,
        onChanged: () async {
          final c = await ApiConfig.load(dir);
          if (mounted) setState(() => _cfg = c);
        },
      ),
    ));
    // 设置里可能改了模型/插件/记忆，回来同步一次
    final c2 = await ApiConfig.load(dir);
    final m2 = _mem;
    if (m2 != null) await m2.load();
    final p2 = _plug;
    if (p2 != null) await p2.load();
    if (mounted) setState(() => _cfg = c2);
    if (!mounted) return;
  }

  /// 旧设置页：备用接入点、测思考开关这些还没搬进新页面，先从「高级」胶囊进去。
  Future<void> _settingsLegacy(ApiConfig cfg) async {
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
    var reasoning = cfg.reasoning;
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
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('思考深度', style: Theme.of(ctx).textTheme.labelMedium),
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final e in const {
                    'auto': '自动',
                    'off': '不思考',
                    'low': '低',
                    'high': '高',
                    'max': '最高',
                  }.entries)
                    ChoiceChip(
                      label: Text(e.value, style: const TextStyle(fontSize: 12)),
                      selected: reasoning == e.key,
                      onSelected: (_) => setS(() => reasoning = e.key),
                    ),
                ],
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
              onPressed: () async {
                setS(() => test = '正在测「不思考」开关…');
                final probe = ApiConfig(
                  baseUrl: base.text.trim(),
                  apiKey: key.text.trim(),
                  model: model.text.trim(),
                  reasoning: 'off',
                );
                final r = await LlmClient(probe).ping();
                setS(() => test = r.ok
                    ? '✅ 这个模型接受「不思考」开关（${r.ms}ms）'
                    : '⚠️ 它不接受或报错：${r.message}');
              },
              child: const Text('测思考开关'),
            ),
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
                  ..reasoning = reasoning
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
        // 只要在跑就一定要有一条状态：模型想、跑工具、限流退避，三种都得看得见。
        // 以前只有「重试」才设 _status，正常跑的时候这条横幅根本不出现。
        if (_busy || _stopping)
          Container(
            width: double.infinity,
            color: (_status?.contains('限流') ?? false) ||
                    (_status?.contains('不稳定') ?? false)
                ? Colors.amber.withOpacity(0.12)
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(children: [
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _stopping ? (_status ?? '正在停止…') : (_status ?? '正在想…'),
                  style: const TextStyle(fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
                              child: Text(_busy ? '执行中 · $n 次工具调用' : '已完成 · $n 次工具调用',
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
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (m.images.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          for (final p in m.images)
                                            GestureDetector(
                                              onTap: () => _previewImage(p),
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(8),
                                                child: Image.file(
                                                  File(p),
                                                  width: 96,
                                                  height: 96,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (_, __, ___) => Container(
                                                    width: 96,
                                                    height: 96,
                                                    color: Colors.black12,
                                                    alignment: Alignment.center,
                                                    child: const Icon(Icons.broken_image, size: 18),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  if (m.text.isNotEmpty || m.images.isEmpty)
                                    SelectableText(
                                      m.text.isEmpty ? '…' : m.text,
                                      style: const TextStyle(fontSize: 13, height: 1.4),
                                    ),
                                  // 复制/编辑重发/开分支的入口：长按会被选区手势吃掉，
                                  // 所以挂一个一眼能看见的三点，点一下出菜单。
                                  Align(
                                    alignment: Alignment.bottomRight,
                                    child: InkWell(
                                      onTap: () => _messageMenu(i),
                                      borderRadius: BorderRadius.circular(10),
                                      child: const Padding(
                                        padding: EdgeInsets.only(top: 2, left: 8),
                                        child: Icon(Icons.more_horiz,
                                            size: 14, color: Color(0xFF7C879C)),
                                      ),
                                    ),
                                  ),
                                ],
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
              const SizedBox(width: 6),
              _pill(Icons.tune, '高级', () {
                final c = _cfg;
                if (c != null) _settingsLegacy(c);
              }),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_pending.isNotEmpty) _attachStrip(),
              _modelBar(),
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
