import 'dart:math' as math;

/// 一次「发出去」的上下文：真正给模型的 messages + 需要拼进 system 的记忆/摘要。
///
/// 为什么不让模型自己记：模型的窗口是它自己的固定值（几 K 到几 M token），
/// 客户端改不了。客户端能做的是**在窗口边缘做取舍**——把该记的留下，
/// 把重复的压掉，这样同一个窗口能装下更长的对话。
class BuiltContext {
  BuiltContext({
    required this.messages,
    required this.systemSuffix,
    required this.dropped,
    required this.usedChars,
  });

  final List<Map<String, dynamic>> messages;

  /// 追加到 system prompt 后面的块（长期记忆 + 早前摘要）；空串表示没有。
  final String systemSuffix;

  /// 因预算被挤掉的消息条数（>0 时摘要里会有一行说明）。
  final int dropped;

  final int usedChars;
}

/// 把「全部历史 + 记忆」压成「窗口装得下的一批消息」。
///
/// 三条规则，按优先级：
/// 1. 最近的 `keepTail` 条一定要带上（不然模型接不上话）；
/// 2. 从后往前按字符预算装，装不下就停——**不切半条消息**，
///    半条消息比没有更糟：模型会把截断的 JSON/代码当真的；
/// 3. 被挤掉的旧消息压成摘要（谁说的、说了什么，每条一句），
///    和长期记忆一起塞进 system。
class ContextBuilder {
  ContextBuilder({this.maxChars = 24000, this.keepTail = 10});

  /// 字符预算。中文按 1 字 ≈ 1 token 粗算，24000 字对 64K 窗口的模型很宽裕，
  /// 对 8K 窗口的本地模型则要调小——所以它在设置里可改，不写死。
  int maxChars;

  /// 最近几条无论如何都保留。
  int keepTail;

  int _lenOf(Map<String, dynamic> m) {
    final c = m['content'];
    if (c is String) return c.length;
    if (c is List) {
      var n = 0;
      for (final e in c) {
        if (e is Map) {
          final t = e['text'];
          if (t is String) n += t.length;
          n += 80; // 图片块按固定开销计
        }
      }
      return n;
    }
    return 0;
  }

  BuiltContext build({
    required List<Map<String, dynamic>> history,
    String memory = '',
    String summary = '',
    String systemPrompt = '',
  }) {
    if (history.isEmpty) {
      return BuiltContext(
        messages: const [],
        systemSuffix: _suffix(memory, summary, 0),
        dropped: 0,
        usedChars: 0,
      );
    }

    // 从尾巴往前装；先保证 keepTail 条
    final picked = <Map<String, dynamic>>[];
    var used = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final m = history[i];
      final n = _lenOf(m);
      final mustKeep = picked.length < keepTail;
      if (!mustKeep && used + n > maxChars) break;
      picked.insert(0, m);
      used += n;
      if (used > maxChars * 2) break; // 兜底：单条巨长也别把内存吃穿
    }

    // 开头如果是 tool 结果，模型会看到「没有对应调用的结果」，去掉更安全。
    while (picked.isNotEmpty && picked.first['role'] == 'tool') {
      picked.removeAt(0);
    }

    final dropped = history.length - picked.length;
    final auto = dropped > 0 ? _summarize(history.take(dropped).toList()) : '';
    final merged = [summary.trim(), auto]
        .where((s) => s.isNotEmpty)
        .join('\n');

    return BuiltContext(
      messages: picked,
      systemSuffix: _suffix(memory, merged, dropped),
      dropped: dropped,
      usedChars: used,
    );
  }

  String _suffix(String memory, String summary, int dropped) {
    final b = StringBuffer();
    if (memory.trim().isNotEmpty) {
      b.write('\n\n# 长期记忆（跨会话保存，视为事实）\n');
      b.write(memory.trim());
    }
    if (summary.trim().isNotEmpty) {
      b.write('\n\n# 早前对话摘要');
      if (dropped > 0) b.write('（已压缩 $dropped 条）');
      b.write('\n');
      b.write(summary.trim());
    }
    if (b.isEmpty) return '';
    return b.toString();
  }

  /// 抽取式摘要：不调模型，零延迟、零额度。
  ///
  /// 用户说的话优先（那是需求），助手的话只留前 80 字（那是结论）；
  /// 工具结果一律不留——它们是过程，重跑一次比记住便宜。
  String _summarize(List<Map<String, dynamic>> dropped) {
    final lines = <String>[];
    for (final m in dropped) {
      final role = '${m['role']}';
      if (role == 'tool') continue;
      final c = m['content'];
      final text = c is String ? c.trim() : '';
      if (text.isEmpty) continue;
      final limit = role == 'user' ? 120 : 80;
      final one = text.replaceAll(RegExp(r'\s+'), ' ');
      lines.add('- ${role == 'user' ? '用户' : '助手'}：'
          '${one.length > limit ? '${one.substring(0, limit)}…' : one}');
    }
    if (lines.isEmpty) return '';
    final keep = lines.length > 40 ? lines.sublist(lines.length - 40) : lines;
    return keep.join('\n');
  }

  /// 粗估 token：中文 1 字约 1 token，英文约 4 字符 1 token。
  static int estimateTokens(String s) {
    if (s.isEmpty) return 0;
    var cjk = 0;
    for (final r in s.runes) {
      if (r >= 0x4E00 && r <= 0x9FFF) cjk++;
    }
    final rest = s.length - cjk;
    return cjk + math.max(1, rest ~/ 4);
  }
}
