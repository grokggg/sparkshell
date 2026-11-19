import 'package:flutter/material.dart';

/// 工具名称 → 中文动词 / 参数摘要 / 图标
class ToolInfo {
  // 纯静态工具类，禁止实例化。
  const ToolInfo._();

  /// 工具名 → 中文动词；未登记的工具名原样返回。
  static String label(String name) {
    switch (name) {
      case 'bash':
        return '跑命令';
      case 'read_file':
        return '读取';
      case 'write_file':
        return '写入';
      case 'edit_file':
        return '编辑';
      case 'apply_patch':
        return '改多处';
      case 'list_dir':
        return '列目录';
      case 'search_files':
        return '查找';
      case 'task_log':
        return '看日志';
      case 'task_list':
        return '任务列表';
      case 'todo':
        return '计划';
      default:
        return name;
    }
  }

  /// 工具名 + 参数 → 一行摘要；尽量短，供收起态单行展示。
  static String summary(String name, Map<String, dynamic> args) {
    switch (name) {
      case 'bash':
        // 多行脚本压成一行，过长再截断，避免撑破单行布局。
        return _clip(_oneLine(_str(args['command'])));
      case 'read_file':
      case 'write_file':
      case 'edit_file':
      case 'apply_patch':
        return _pathOf(args);
      case 'list_dir':
        return _pathOf(args, emptyFallback: '/');
      case 'search_files':
        return '${_str(args['pattern'])} · ${_pathOf(args, emptyFallback: '/')}';
      case 'task_log':
        return _str(args['id']);
      case 'task_list':
      case 'todo':
        return '';
      default:
        return '';
    }
  }

  /// 工具名 → 左侧小图标。
  static IconData icon(String name) {
    switch (name) {
      case 'bash':
        return Icons.terminal;
      case 'read_file':
        return Icons.description_outlined;
      case 'write_file':
        return Icons.save_outlined;
      case 'edit_file':
        return Icons.edit_outlined;
      case 'apply_patch':
        return Icons.build_outlined;
      case 'list_dir':
        return Icons.folder_open_outlined;
      case 'search_files':
        return Icons.search;
      case 'task_log':
        return Icons.article_outlined;
      case 'task_list':
        return Icons.checklist;
      case 'todo':
        return Icons.playlist_add_check;
      default:
        return Icons.widgets_outlined;
    }
  }

  /// 取参数里的路径；缺失或为空时用 [emptyFallback]。
  static String _pathOf(Map<String, dynamic> args, {String emptyFallback = ''}) {
    final String path = _str(args['path']);
    return path.isEmpty ? emptyFallback : path;
  }

  /// 任意参数值转成去首尾空白的字符串。
  static String _str(Object? value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  /// 多行文本压成单行：换行统一替换成 ' ; '。
  static String _oneLine(String text) {
    return text.replaceAll(RegExp(r'\r\n|\r|\n'), ' ; ').trim();
  }

  /// 超过 60 字符截断并补省略号。
  static String _clip(String text) {
    if (text.length <= 60) return text;
    return '${text.substring(0, 60)}…';
  }
}

/// 一次工具调用：一行摘要，点开看完整输出。
class ToolRow extends StatefulWidget {
  const ToolRow({
    super.key,
    required this.name,
    required this.args,
    required this.output,
    this.ok = true,
    this.ms = 0,
  });

  final String name;
  final Map<String, dynamic> args;
  final String output;
  final bool ok;
  final int ms; // 耗时毫秒，0 表示不显示

  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  /// 是否展开输出面板
  bool _open = false;

  // 配色集中在这里，方便后续统一调整。
  static const Color _iconColor = Color(0xFF7DE2D1);
  static const Color _labelColor = Color(0xFFD9E2F5);
  static const Color _summaryColor = Color(0xFF8A98B8);
  static const Color _mutedColor = Color(0xFF6B7899);
  static const Color _okColor = Color(0xFF6FCF97);
  static const Color _failColor = Color(0xFFEB8A8A);
  static const Color _textColor = Color(0xFFC9D4EA);
  static const Color _addColor = Color(0xFF6FCF97);
  static const Color _delColor = Color(0xFFEB8A8A);
  static const Color _hunkColor = Color(0xFF7FB2F0);

  @override
  Widget build(BuildContext context) {
    final bool hasOutput = widget.output.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildHeader(hasOutput),
        if (_open) _buildOutput(),
      ],
    );
  }

  /// 收起态的一行：图标 + 动词 + 摘要 + 展开箭头 + 状态点 + 耗时。
  Widget _buildHeader(bool hasOutput) {
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 34,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: <Widget>[
              Icon(ToolInfo.icon(widget.name), size: 14, color: _iconColor),
              const SizedBox(width: 6),
              Text(
                ToolInfo.label(widget.name),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _labelColor,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ToolInfo.summary(widget.name, widget.args),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: _summaryColor),
                ),
              ),
              // 没有输出就不给展开箭头，避免点了也没东西看。
              if (hasOutput)
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: _mutedColor,
                ),
              if (hasOutput) const SizedBox(width: 4),
              _buildDot(),
              if (widget.ms > 0)
                Text(
                  ' ${_formatMs(widget.ms)}',
                  style: const TextStyle(fontSize: 11, color: _mutedColor),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 成功/失败状态点。
  Widget _buildDot() {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.ok ? _okColor : _failColor,
      ),
    );
  }

  /// 展开后的完整输出面板，按行着色。
  Widget _buildOutput() {
    final String text = widget.output.isEmpty ? '（无输出）' : widget.output;
    return Container(
      margin: const EdgeInsets.only(left: 10, right: 10, bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText.rich(
        TextSpan(children: _buildSpans(text)),
        style: const TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.5,
          color: _textColor,
        ),
      ),
    );
  }

  /// 逐行生成带颜色的文本片段：@@ 蓝、+ 绿、- 红，其它用默认色。
  static List<TextSpan> _buildSpans(String text) {
    final List<TextSpan> spans = <TextSpan>[];
    final List<String> lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) {
        spans.add(const TextSpan(text: '\n'));
      }
      final String line = lines[i];
      spans.add(TextSpan(text: line, style: TextStyle(color: _lineColor(line))));
    }
    return spans;
  }

  /// 单行颜色判定。
  static Color _lineColor(String line) {
    if (line.startsWith('@@')) return _hunkColor;
    if (line.startsWith('+')) return _addColor;
    if (line.startsWith('-')) return _delColor;
    return _textColor;
  }

  /// 耗时格式化：<1s 显示 '320ms'，否则 '1.20s'。
  static String _formatMs(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(2)}s';
  }
}
