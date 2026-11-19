import 'dart:convert';

import '../chat/api_config.dart';
import '../chat/llm_client.dart';
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
class AgentRunner {
  AgentRunner({
    required this.cfg,
    required this.onText,
    required this.onToolResult,
    required this.approve,
    this.onTool,
    this.maxSteps = 12,
    this.onStatus,
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
    );
    onStatus?.call(null);
    try {
      for (var step = 0; step < maxSteps; step++) {
        final msg = await client.complete(messages, tools: Tools.specs);
        final raw = (msg['content'] as String?) ?? '';
        final calls = msg['tool_calls'] as List?;
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
          final ok = await approve(t.name, t.args);
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
          messages.add({'role': 'assistant', 'content': raw});
          messages.add({'role': 'user', 'content': '[工具 ${t.name} 的输出]\n$out'});
          continue;
        }

        // 走到这里说明原生 tool_calls 存在（noNative 分支已 return/continue）
        final nativeCalls = calls!;
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
          final ok = await approve(name, args);
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
          messages.add({'role': 'tool', 'tool_call_id': c['id'], 'content': out});
        }
      }
      onText('（已连跑 $maxSteps 步，先停下。发「继续」我接着跑，已完成的步骤不会重来）');
    } finally {
      client.dispose();
    }
  }

  static String _brief(Map<String, dynamic> args) {
    final s = jsonEncode(args);
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}
