import 'package:flutter/material.dart';

/// 工具结果卡片：短输出直出，长输出默认折叠；diff 按行着色。
class ToolResultCard extends StatelessWidget {
  const ToolResultCard({super.key, required this.title, required this.text, this.maxPreviewLines = 3});

  /// 首行标题，例如 'write_file · 已写入 40 字节'
  final String title;

  /// 完整输出（可能带 @@/+/ - 的 diff 段）
  final String text;

  /// 折叠时预览几行
  final int maxPreviewLines;

  @override
  Widget build(BuildContext context) {
    // 展开/收起是交互状态，交给私有 StatefulWidget 管，对外仍是 StatelessWidget。
    return _ToolResultCardBody(
      title: title,
      text: text,
      maxPreviewLines: maxPreviewLines,
    );
  }
}

/// 内部实现：持有展开状态。
class _ToolResultCardBody extends StatefulWidget {
  const _ToolResultCardBody({
    required this.title,
    required this.text,
    required this.maxPreviewLines,
  });

  final String title;
  final String text;
  final int maxPreviewLines;

  @override
  State<_ToolResultCardBody> createState() => _ToolResultCardBodyState();
}

class _ToolResultCardBodyState extends State<_ToolResultCardBody> {
  /// 是否已展开长输出
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _ToolResultCardBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 输出变了（同一条消息被替换）就回到折叠态，避免残留展开状态。
    if (oldWidget.text != widget.text) {
      _expanded = false;
    }
  }

  /// diff 着色：@@ 蓝、+ 绿、- 红，其它保持默认色。
  static TextSpan _toolSpan(String text) {
    final spans = <TextSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      Color? color;
      if (l.startsWith('@@')) {
        color = const Color(0xFF7FB2F0);
      } else if (l.startsWith('+')) {
        color = const Color(0xFF6FCF97);
      } else if (l.startsWith('-')) {
        color = const Color(0xFFEB8A8A);
      }
      // 最后一行不带换行，避免多出一行空白
      spans.add(TextSpan(
        text: i == lines.length - 1 ? l : '$l\n',
        style: TextStyle(color: color),
      ));
    }
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.text.isEmpty ? '…' : widget.text;
    final lines = body.split('\n');
    final int maxLines = widget.maxPreviewLines < 1 ? 1 : widget.maxPreviewLines;
    // 短输出：行数和总长度都在阈值内，直接全文展示，不出现展开按钮。
    final bool short = lines.length <= maxLines + 3 && body.length <= 600;

    final List<Widget> children = <Widget>[];

    // 标题行：小号灰字，单行省略
    children.add(Text(
      widget.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 10, color: Colors.grey),
    ));
    children.add(const SizedBox(height: 4));

    if (short) {
      // 短输出也走同一套着色，diff 一样能看
      children.add(SelectableText.rich(
        _toolSpan(body),
        style: const TextStyle(
          fontSize: 11,
          height: 1.4,
          fontFamily: 'monospace',
        ),
      ));
    } else if (!_expanded) {
      // 折叠态：前 maxPreviewLines 行，灰色，溢出省略
      children.add(Text(
        lines.take(maxLines).join('\n'),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11,
          height: 1.4,
          fontFamily: 'monospace',
          color: Colors.grey,
        ),
      ));
      children.add(const SizedBox(height: 4));
      children.add(_toggle(context, '展开 ${lines.length} 行'));
    } else {
      // 展开态：完整内容 + 收起
      children.add(SelectableText.rich(
        _toolSpan(body),
        style: const TextStyle(
          fontSize: 11,
          height: 1.4,
          fontFamily: 'monospace',
        ),
      ));
      children.add(const SizedBox(height: 4));
      children.add(_toggle(context, '收起'));
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 展开/收起的那一行蓝色小字
  Widget _toggle(BuildContext context, String label) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
