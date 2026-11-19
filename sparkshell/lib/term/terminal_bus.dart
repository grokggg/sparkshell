import 'dart:async';

/// 终端里的「AI 通道」。
///
/// 两条方向：
/// 1. AI 干活 → [mirror] / [echoCommand] / [echoResult] 把动作和输出写进终端屏幕，
///    用户在 Linux 页就能实时看到 AI 在敲什么、拿到了什么；
/// 2. 用户在终端里提问 → [askAi]，Chat 页订阅 [aiRequests] 直接把问题交给 Agent。
///
/// 刻意不 import xterm / Flutter：终端页面把 `Terminal.write` 注册进来即可，
/// 这样 Agent 层（tools.dart）也能安全引用，不会把 UI 依赖带进纯逻辑。
class TerminalBus {
  TerminalBus._();

  static final TerminalBus instance = TerminalBus._();

  void Function(String text)? _mirror;
  final _requests = StreamController<String>.broadcast();

  /// 终端里发出的 AI 请求（`@ai ...`）
  Stream<String> get aiRequests => _requests.stream;

  /// 终端是否已经起来（没起来时镜像全部丢弃，不报错）
  bool get live => _mirror != null;

  void attach(void Function(String) mirror) => _mirror = mirror;

  void detach() => _mirror = null;

  void mirror(String text) => _mirror?.call(text);

  /// AI 要执行命令时，先在终端里留一行青色徽标，避免"黑箱"。
  ///
  /// 一条 for 循环 + 五个 `command -v` 能把 220 宽的行折成 8 行，
  /// 整屏都是命令、看不见结果。所以：多行只留首行 + 行数，超长截断 + …
  void echoCommand(String cmd, {int maxChars = 120}) {
    var one = cmd.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');
    final lines = cmd.trim().split('\n').length;
    if (one.length > maxChars) {
      one = '${one.substring(0, maxChars)}…';
    }
    final more = lines > 1 ? ' \x1b[90m(+${lines - 1} 行)\x1b[0m' : '';
    mirror('\r\n\x1b[36m▶ AI\x1b[0m \x1b[1m$one\x1b[0m$more\r\n');
  }

  /// 命令输出回灌：暗灰缩进，太长只保留尾部
  void echoResult(String text, {int maxChars = 3000}) {
    var t = text.trimRight();
    if (t.isEmpty) return;
    if (t.length > maxChars) {
      t = '…（共 ${text.length} 字符，这里只显示尾部）\n'
          '${t.substring(t.length - maxChars)}';
    }
    for (final line in t.split('\n')) {
      mirror('  \x1b[90m$line\x1b[0m\r\n');
    }
  }

  /// 终端输入条 → Chat
  void askAi(String text) {
    final q = text.trim();
    if (q.isNotEmpty) _requests.add(q);
  }
}
