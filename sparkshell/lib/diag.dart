import 'dart:async';

import 'package:flutter/foundation.dart';

import 'security/self_check.dart';

/// 运行期诊断：错误环形缓冲 + 启动自检结果。
///
/// 为什么要有它：真机上出问题（解包失败、闪退、接口 4xx）时，用户能给的只有
/// 一张截图；而这个包又是自签、自校验的，事后没法用商店后台查日志。所以把
/// 最近发生的事留在内存里，让用户「复制诊断信息」一次性贴出来。
///
/// 只留内存不落盘：写文件要走原生通道，收益（跨重启）不抵复杂度；一次会话内
/// 的事故现场已经够定位问题。
class Diag {
  Diag._();

  /// 环形缓冲上限：够还原一次事故，又不至于把界面撑爆。
  static const int maxLines = 240;

  static final List<String> _log = <String>[];

  /// 启动时那次自检的结果（null = 还没跑完 / 跑挂了）。
  static final ValueNotifier<SelfCheckResult?> selfCheck =
      ValueNotifier<SelfCheckResult?>(null);

  /// 累计错误条数，界面用它决定要不要显示「诊断」红点。
  static final ValueNotifier<int> errorCount = ValueNotifier<int>(0);

  static List<String> get lines => List<String>.unmodifiable(_log);

  /// 记一条。`tag` 用短词：flutter / zone / platform / selfcheck / update。
  static void add(String tag, Object error, [StackTrace? stack]) {
    final now = DateTime.now();
    final hhmmss = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final where = stack == null
        ? ''
        : stack
            .toString()
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .take(2)
            .map((l) => l.trim())
            .join(' <- ');
    final line = '$hhmmss [$tag] $error${where.isEmpty ? '' : '  @$where'}';
    _log.add(line);
    if (_log.length > maxLines) {
      _log.removeRange(0, _log.length - maxLines);
    }
    errorCount.value = errorCount.value + 1;
    debugPrint(line);
  }

  /// 启动时跑一次自检。失败不抛：自检本身挂了不该拦住 App。
  static Future<SelfCheckResult?> boot() async {
    try {
      final r = await runSelfCheck();
      selfCheck.value = r;
      if (!r.ok) add('selfcheck', '自检不合格：${r.verdict} ${r.summary}');
      return r;
    } catch (e, s) {
      add('selfcheck', e, s);
      return null;
    }
  }

  /// 给用户复制的那段文本：版本、自检、最近错误，一眼能贴。
  static String dump({
    required String version,
    required int code,
    String extra = '',
  }) {
    final b = StringBuffer()
      ..writeln('SparkShell $version+$code')
      ..writeln('时间 ${DateTime.now().toIso8601String()}');
    final sc = selfCheck.value;
    if (sc == null) {
      b.writeln('自检：未完成');
    } else {
      b.writeln('自检：${sc.verdict}  ${sc.summary}');
      b.writeln('  证书 ${sc.cert}');
      b.writeln('  设备指纹 ${sc.fp}');
      b.writeln('  包 ${sc.pkg} $version');
      if (sc.err.isNotEmpty) b.writeln('  错误 ${sc.err}');
    }
    if (extra.trim().isNotEmpty) b.writeln(extra.trim());
    b.writeln('最近 ${_log.length} 条：');
    if (_log.isEmpty) {
      b.writeln('  （无）');
    } else {
      for (final l in _log) {
        b.writeln('  $l');
      }
    }
    return b.toString();
  }
}
