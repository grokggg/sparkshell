import 'dart:convert';

import '../chat/api_config.dart';
import '../chat/llm_client.dart';
import 'cancel_token.dart';
import 'tools.dart';

typedef Approve = Future<bool> Function(String name, Map<String, dynamic> args);

/// 一次工具调用的结构化结果：给 UI 渲染成「图标 + 中文动词 + 参数 + 耗时」的一行。
class ToolEvent {
  ToolEvent({
    required this.name,
    required this.args,
    required this.output,
    required this.ok,
    required this.ms,
  });

  final String name;
  final Map<String, dynamic> args;
  final String output;
  final bool ok;
  final int ms;
}

/// 工具循环：模型要工具 → 人审批 → 容器里执行 → 结果回灌 → 再来一轮。
///
/// 刻意用非流式：tool_calls 必须完整拿到才能执行，逐帧解析只增风险不增体验。
/// 每轮最多 maxSteps 次，防止模型自己打转把 token 烧光。
/// 40 而不是 12：查环境、装包这种活本来就十几步，12 步就停会逼用户一直点「继续」。
class AgentRunner {
  AgentRunner({
    required this.cfg,
    required this.onText,
    required this.onToolResult,
    required this.approve,
    this.onTool,
    this.maxSteps = 40,
    this.onStatus,
    this.cancel,
    this.vision = false,
    this.onVisionFallback,
    this.modelOverride,
  });

  final ApiConfig cfg;
  final void Function(String text) onText;
  final void Function(String rendered) onToolResult;

  /// 结构化工具事件（渲染成一行的那个）；不给就退回纯文本 onToolResult
  final void Function(ToolEvent e)? onTool;
  final Approve approve;
  final int maxSteps;

  /// 重试/等待类状态：只更新顶部进度条，不往对话里插气泡（否则每条都出现两遍）
  final void Function(String? status)? onStatus;

  /// 用户「停止」开关。可空：老调用点不传就是原来那种跑完为止的行为。
  final CancelToken? cancel;

  /// 这一轮要不要把图片按多模态格式发出去。
  ///
  /// 只有「用户这次真的附了图、且调用方判断接入点能读懂图」才打开；
  /// 关着的时候即使消息里混进图片块也不做降级——那属于调用方的 bug，不该被静默掩盖。
  final bool vision;

  /// 本轮用哪个模型（带图时可能是看图模型）。null = 沿用 cfg.model。
  final String? modelOverride;

  /// 服务端表示看不了图、我们已去掉图片重发时的回调（界面必须告诉用户「这轮只发了文字」）。
  final void Function(String message)? onVisionFallback;

  /// 文本协议提示只说一次
  bool _toldTextProtocol = false;

  static final _openTag = RegExp(r'<tool\s+name="([A-Za-z_]+)"\s*>');

  /// 找到 `<tool name="bash">` 后面那个「平衡的」JSON 对象结束位置。
  /// 不能用正则配 `}`：命令里带 `{}`、`$()`、引号都会把简单匹配打崩。
  static int? _jsonEnd(String s, int open) {
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var k = open; k < s.length; k++) {
      final c = s[k];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == '\\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
        continue;
      }
      if (c == '"') {
        inStr = true;
      } else if (c == '{' || c == '[') {
        depth++;
      } else if (c == '}' || c == ']') {
        depth--;
        if (depth == 0) return k + 1;
      }
    }
    return null;
  }

  /// 从正文里捞工具调用，容忍各种乱七八糟的闭合标签。
  ///
  /// 实测七牛 conatus 会吐这种：
  ///   `<tool name="bash">{"command":"ls -la /root"}</arg_value>`
  ///   `<tool name="bash">{"command":"ls -la /root"}</arg_value></iquest_tool_call>`
  /// 所以不能只认 `</tool>`，JSON 结束就算结束，后面的标签一律当噪音。
  static ({String name, Map<String, dynamic> args, int start, int end})? _parseTextTool(
      String text) {
    final m = _openTag.firstMatch(text);
    if (m == null) return null;
    final name = m.group(1) ?? '';
    final start = m.start;
    var i = m.end;
    while (i < text.length && ' \n\r\t'.contains(text[i])) {
      i++;
    }

    Map<String, dynamic>? args;
    var end = i;
    if (i < text.length && text[i] == '{') {
      final close = _jsonEnd(text, i);
      if (close != null) {
        final body = text.substring(i, close);
        args = _asMap(body);
        if (args == null) {
          // 有些中转会把引号转义成 \" —— 再试一次
          args = _asMap(body.replaceAll(r'\"', '"'));
        }
        if (args != null) end = close;
      }
    }
    if (args == null) {
      final rest = text.substring(i);
      final cut = rest.indexOf('</');
      final body = (cut >= 0 ? rest.substring(0, cut) : rest).trim();
      if (name != 'bash' || body.isEmpty) return null;
      args = <String, dynamic>{'command': body};
      end = i + (cut >= 0 ? cut : body.length);
    }

    // 吃掉尾巴上的闭合标签，可能连着好几个：</arg_value></iquest_tool_call>
    final closeTag = RegExp(r'^\s*</[A-Za-z_.\-]+>');
    while (true) {
      final t = closeTag.firstMatch(text.substring(end));
      if (t == null) break;
      end += t.end;
    }

    return (name: name, args: args, start: start, end: end);
  }

  static Map<String, dynamic>? _asMap(String body) {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    return null;
  }

  /// 容器事实写进 system：不写这段，模型会满世界找 python3、把步数烧在探测上。
  static const preamble = '你在一台 Android 手机的 proot 容器里，rootfs 为 Alpine 或 Debian，'
      '工作目录 /root，PATH 已配好（/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin）。\n'
      '工具：bash（容器内 shell，每次独立进程，用 cd /root && ... 串联）、read_file、write_file、'
      'list_dir、edit_file（单处替换）、apply_patch（一次改多处）、search_files、todo、'
      'task_log / task_list（读后台任务）。\n'
      '装包、pip install、跑超过 60 秒的脚本，一律 bash 加 background=true，拿到任务 id 后用 '
      'task_log 轮询，别把一次调用卡在那里。\n'
      '环境事实：Alpine 只有 busybox，python3/git/curl 默认都不存在。\n'
      '跑 python 前先 self-heal，一步到位，别分三步：'
      '`command -v python3 >/dev/null || apk add --no-cache python3; cd /root && python3 xxx.py`。'
      'Debian 用 `command -v python3 >/dev/null || (apt-get update && apt-get install -y python3)`。\n'
      'apk/apt 源已在 App 侧换成国内镜像，装包通常几十秒；超过 2 分钟没输出就先换策略。\n'
      '判断发行版只认 `grep ^ID= /etc/os-release`（alpine / debian / ubuntu）。'
      'Alpine 上 `command -v apt-get` 有时也会命中一个空壳，别拿它当依据；能装包的只有 apk。\n'
      '改写文件优先 edit_file（只传 old/new 片段），整文件覆盖才用 write_file。\n'
      '如果这个接入点不支持 function calling（你发不出 tool_calls），改用文本协议，一行一条：\n'
      '<tool name="bash">{"command":"ls -la /root"}</tool>\n'
      '标签里的 JSON 必须能被 JSON.parse；一次只发一个工具，等结果回来再决定下一步。'
      '禁止说「我没有终端工具」——你有，标签就是调用方式。';

  /// 取消后统一收口：写一条提示、清掉状态条，让调用点直接 return。
  ///
  /// 刻意不抛异常：上层（chat_page）把异常当成网络故障弹红色错误条，
  /// 用户明明是主动点的停止，不该看到「连不上模型服务」。
  bool _stopRequested() {
    final c = cancel;
    if (c == null || !c.isCancelled) return false;
    onStatus?.call(null);
    onToolResult('⏹ 已按你的要求停止');
    return true;
  }

  Future<void> run(List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty || messages.first['role'] != 'system') {
      final sys = [cfg.systemPrompt.trim(), preamble]
          .where((e) => e.isNotEmpty)
          .join('\n\n');
      messages.insert(0, {'role': 'system', 'content': sys});
    }
    final client = LlmClient(
      cfg,
      onRetry: (m) => onStatus?.call(m),
      vision: vision,
      onVisionFallback: onVisionFallback,
      modelOverride: modelOverride,
    );
    onStatus?.call(null);
    try {
      // 不在 40 步就停：装环境、找依赖这种活本来就长，停一次就要用户点一次
      // 「继续」，等于把等待转嫁给他。这里改成跑到底，400 步只是防死循环的保险。
      var step = 0;
      var stalls = 0;
      String? lastSig;
      while (true) {
        step++;
        if (step > maxSteps * 10) {
          onText('（已连跑 $step 步还没收尾，我先停下。发「继续」我接着跑，已完成的部分不会重来）');
          return;
        }
        // 每步开头先看取消：上一步工具刚跑完那一刻点的停止，不该再多发一轮请求
        if (_stopRequested()) return;

        // 停止时 HttpClient 被 close(force: true)，挂着的请求会以
        // SocketException / HttpException 冒出来；这类异常由下面的 catch 统一收口
        final msg = await client.complete(messages, tools: Tools.specs, cancel: cancel);
        final raw = (msg['content'] as String?) ?? '';
        final calls = msg['tool_calls'] as List?;
        // 卡住判定：模型自己打转时（同一个命令连着发 3 次、结果没变化），
        // 无限跑下去只会烧额度，这时停下来比硬撑更有用。
        final sig = calls == null || calls.isEmpty
            ? null
            : calls
                .map((c) => '${(c as Map)['function']?['name']}'
                    '${(c as Map)['function']?['arguments']}')
                .join('|');
        if (sig != null && sig == lastSig) {
          stalls++;
        } else {
          stalls = 0;
        }
        lastSig = sig;
        if (stalls >= 3) {
          onText('（同一个命令连跑 ${stalls + 1} 次都没有新结果，像是卡住了。我停下，你看一眼再让我继续）');
          return;
        }
        final noNative = calls == null || calls.isEmpty;
        // 文本协议：模型不支持 function calling 时的兜底通道
        final t = noNative ? _parseTextTool(raw) : null;

        // 显示给用户的内容要把工具标签剥掉，否则聊天里全是 `<tool ...>` 噪音
        var shown = t == null
            ? raw.trim()
            : (raw.substring(0, t.start) + raw.substring(t.end)).trim();
        // 兜底：正文里残留的闭合标签碎片（模型常写成 </arg_value> 混搭）一律清掉
        shown = shown.replaceAll(RegExp(r'</[A-Za-z_.\-]+>'), '').trim();
        if (shown.isNotEmpty) onText(shown);

        if (noNative) {
          if (t == null) return;
          if (!_toldTextProtocol) {
            _toldTextProtocol = true;
            onToolResult('ℹ 这个接入点不返回 tool_calls，已改用文本协议执行（功能一样）');
          }
          // 审批弹窗可能停在这里等用户点：点「停止」时弹窗还开着，别再执行
          if (_stopRequested()) return;
          final ok = await approve(t.name, t.args);
          if (_stopRequested()) return;
          final sw = Stopwatch()..start();
          final out = ok ? await Tools.run(t.name, t.args) : '用户拒绝执行';
          sw.stop();
          final cb = onTool;
          if (cb != null) {
            cb(ToolEvent(
                name: t.name, args: t.args, output: out, ok: ok, ms: sw.elapsedMilliseconds));
          } else {
            onToolResult('${ok ? '▶' : '⊘'} ${t.name}\n${_brief(t.args)}\n$out');
          }
          // 容器里的进程杀不掉（bash 可能还在跑），能立刻做到的是：
          // 这一条跑完就不再回灌模型、不再开下一轮。结果不回灌也更安全。
          if (_stopRequested()) return;
          messages.add({'role': 'assistant', 'content': raw});
          messages.add({'role': 'user', 'content': '[工具 ${t.name} 的输出]\n$out'});
          continue;
        }

        // 走到这里说明原生 tool_calls 存在（noNative 分支已 return/continue）
        final nativeCalls = calls;
        messages.add({'role': 'assistant', 'content': raw.trim(), 'tool_calls': nativeCalls});
        for (final rc in nativeCalls) {
          final c = rc as Map;
          final fn = c['function'] as Map? ?? const {};
          final name = fn['name'] as String? ?? '';
          var args = <String, dynamic>{};
          try {
            args = jsonDecode(fn['arguments'] as String? ?? '{}') as Map<String, dynamic>;
          } catch (_) {
            args = {'raw': fn['arguments']};
          }
          // 一条 assistant 消息可能带多个 tool_call：每个执行前后都要看灯，
          // 否则用户点了停止，剩下的调用还会接着在容器里跑
          if (_stopRequested()) return;
          final ok = await approve(name, args);
          if (_stopRequested()) return;
          final sw = Stopwatch()..start();
          final out = ok ? await Tools.run(name, args) : '用户拒绝执行';
          sw.stop();
          final cb = onTool;
          if (cb != null) {
            cb(ToolEvent(
                name: name, args: args, output: out, ok: ok, ms: sw.elapsedMilliseconds));
          } else {
            onToolResult('${ok ? '▶' : '⊘'} $name\n${_brief(args)}\n$out');
          }
          if (_stopRequested()) return;
          messages.add({'role': 'tool', 'tool_call_id': c['id'], 'content': out});
        }
      }
      // 正常不会走到这里：while(true) 只从「模型给最终答复」或上面的保险退出。
    } catch (e) {
      // 停止之后冒出来的任何异常（被掐断的 socket、工具被中断）都当「正常停止」处理：
      // 写一条提示就安静退出，不再往上层抛，避免界面弹红色「连不上模型服务」
      if (_stopRequested()) return;
      rethrow;
    } finally {
      client.dispose();
    }
  }

  static String _brief(Map<String, dynamic> args) {
    final s = jsonEncode(args);
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}
