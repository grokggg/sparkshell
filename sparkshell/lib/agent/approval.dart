/// 工具审批：只在该拦的时候拦。
///
/// 旧行为是每个工具都弹一次窗，用户点两下就烦了，最后必然点「全部允许」——
/// 等于没有审批。这里改成按危险程度判定：
///   - 只读/容器内写：直接过；
///   - 会删数据、改系统、连外网执行、动宿主：弹窗，并说清「为什么拦」。
///
/// 判定只看命令文本，不做沙箱分析——目标是挡住手滑和模型幻觉，不是防定向逃逸。
library;

/// 一次审批请求。
class ApprovalRequest {
  const ApprovalRequest(this.reason, this.snippet);
  final String reason;
  final String snippet;
}

/// 会毁数据/毁系统/远程取代码执行的动作。
const _bashRules = <String, String>{
  r'\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+/(\s|$)': '要在根目录删东西',
  r'\brm\s+-[a-zA-Z]*r[a-zA-Z]*f?\s+~': '要删整个 home',
  r'--no-preserve-root': '明确要求连根删',
  r'\bmkfs(\.\w+)?\b': '要格式化分区',
  r'\bdd\b.*\bof=/dev/': '要直接写块设备',
  r'\b(shred|wipe)\b': '要不可恢复地擦除',
  r'>\s*/dev/(block|mmcblk|sd)': '要覆盖磁盘',
  r'\b(fdisk|parted|mke2fs)\b': '要改分区表',
  r'\bmount\b|\bumount\b': '要挂载/卸载文件系统',
  r'\bchmod\s+(-R\s+)?777\s+/': '要把根目录改成人人可写',
  r'\bchown\s+-R\s+\S+\s+/': '要递归改根目录属主',
  r'(curl|wget)[^|;]*\|\s*(ba)?sh': '要从网上抓脚本直接执行',
  r'\b(base64|xxd)\b[^|;]*\|\s*(ba)?sh': '要解码后直接执行',
  r'\b(shutdown|reboot|halt|poweroff)\b': '要关机/重启',
  r'\bkill\s+-9\s+-1\b|\bkillall5\b': '要杀光所有进程',
  r'\b(iptables|nft)\b': '要改防火墙',
  r'\bsu\b|\bsudo\b': '要切 root',
  r':\(\)\s*\{.*\};\s*:': 'fork 炸弹',
};

/// 写到这些前缀之外，算动宿主/系统。
const _safeRoots = ['/root', '/tmp', '/home', '/workspace', '/data/data/com.grokggg.sparkshell'];

bool _writesOutside(String path) {
  if (path.isEmpty) return false;
  if (!path.startsWith('/')) return false; // 相对路径落在 cwd，容器内
  return !_safeRoots.any((r) => path == r || path.startsWith('$r/'));
}

/// 该不该为这次调用弹窗。null = 不用问。
ApprovalRequest? approvalFor(String name, Map<String, dynamic> args) {
  switch (name) {
    case 'bash':
      final cmd = (args['command'] ?? '').toString();
      for (final e in _bashRules.entries) {
        if (RegExp(e.key, caseSensitive: false).hasMatch(cmd)) {
          return ApprovalRequest(e.value, _clip(cmd));
        }
      }
      return null;

    case 'ssh_exec':
      return ApprovalRequest('要在远端的机器上执行命令', _clip('${args['host'] ?? ''} ${args['command'] ?? ''}'));

    case 'write_file':
    case 'edit_file':
    case 'apply_patch':
      final p = (args['path'] ?? args['file'] ?? '').toString();
      if (_writesOutside(p)) return ApprovalRequest('要写容器之外的路径', p);
      return null;

    default:
      return null;
  }
}

/// 弹窗正文：最多 600 字，多了看不完也没必要。
String _clip(String s) => s.length > 600 ? '${s.substring(0, 600)}…' : s;
