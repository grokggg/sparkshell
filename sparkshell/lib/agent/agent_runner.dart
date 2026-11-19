import 'dart:convert';

import '../chat/api_config.dart';
import '../chat/llm_client.dart';
import 'tools.dart';

typedef Approve = Future<bool> Function(String name, Map<String, dynamic> args);

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
    this.maxSteps = 12,
  });

  final ApiConfig cfg;
  final void Function(String text) onText;
  final void Function(String rendered) onToolResult;
  final Approve approve;
  final int maxSteps;

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
      '改写文件优先 edit_file（只传 old/new 片段），整文件覆盖才用 write_file。';

  Future<void> run(List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty || messages.first['role'] != 'system') {
      final sys = [cfg.systemPrompt.trim(), preamble]
          .where((e) => e.isNotEmpty)
          .join('\n\n');
      messages.insert(0, {'role': 'system', 'content': sys});
    }
    final client = LlmClient(
      cfg,
      onRetry: (m) => onToolResult('⏳ $m'),
    );
    try {
      for (var step = 0; step < maxSteps; step++) {
        final msg = await client.complete(messages, tools: Tools.specs);
        final content = (msg['content'] as String?)?.trim() ?? '';
        if (content.isNotEmpty) onText(content);

        final calls = msg['tool_calls'] as List?;
        if (calls == null || calls.isEmpty) return;

        messages.add({'role': 'assistant', 'content': content, 'tool_calls': calls});
        for (final raw in calls) {
          final c = raw as Map;
          final fn = c['function'] as Map? ?? const {};
          final name = fn['name'] as String? ?? '';
          var args = <String, dynamic>{};
          try {
            args = jsonDecode(fn['arguments'] as String? ?? '{}') as Map<String, dynamic>;
          } catch (_) {
            args = {'raw': fn['arguments']};
          }
          final ok = await approve(name, args);
          final out = ok ? await Tools.run(name, args) : '用户拒绝执行';
          onToolResult('${ok ? '▶' : '⊘'} $name\n${_brief(args)}\n$out');
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
