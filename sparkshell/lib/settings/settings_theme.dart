import 'package:flutter/material.dart';

/// 设置中心的配色常量 + 几个通用小部件。
///
/// 单独成文件是为了让五个分区（模型/插件/记忆/上下文/高级）共用同一套
/// 圆角、描边和字号，不用在每个 Tab 里重复写 BoxDecoration。
/// 只依赖 flutter，不引第三方包。
class Sk {
  const Sk._();

  /// 页面底色
  static const Color bg = Color(0xFF0E131B);

  /// 卡片底色
  static const Color card = Color(0xFF161D28);

  /// 描边 / 分割线
  static const Color line = Color(0xFF253044);

  /// 主色
  static const Color primary = Color(0xFF2F6BFF);

  /// 次要文字
  static const Color dim = Color(0xFF8A99B0);

  /// 正文
  static const Color text = Color(0xFFE8EEF7);

  /// 危险色（删除、清空）
  static const Color danger = Color(0xFFFF5C6C);

  /// 成功色
  static const Color ok = Color(0xFF37C98B);

  /// 所有卡片统一圆角
  static const double radius = 14;

  /// 输入框内部圆角（比卡片小一号，视觉上不打架）
  static const double fieldRadius = 10;

  static TextStyle get title => const TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: text,
    height: 1.3,
  );

  static TextStyle get body =>
      const TextStyle(fontSize: 13, color: text, height: 1.45);

  static TextStyle get note =>
      const TextStyle(fontSize: 12, color: dim, height: 1.45);

  static TextStyle get mono => const TextStyle(
    fontSize: 11.5,
    color: dim,
    height: 1.4,
    fontFamily: 'monospace',
  );
}

/// 全局暗色主题（只作用于设置页，不改宿主 MaterialApp 的主题）。
ThemeData settingsTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Sk.bg,
    canvasColor: Sk.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: Sk.primary,
      surface: Sk.card,
      error: Sk.danger,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF22303F),
      contentTextStyle: TextStyle(color: Sk.text, fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Sk.primary,
      selectionColor: Color(0x552F6BFF),
      selectionHandleColor: Sk.primary,
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: Sk.primary,
      inactiveTrackColor: Sk.line,
      thumbColor: Colors.white,
      overlayColor: Sk.primary.withValues(alpha: 0.12),
      trackHeight: 3,
    ),
  );
}

/// 统一卡片：圆角 14、1px 描边、卡片色。
class SkCard extends StatelessWidget {
  const SkCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = EdgeInsets.zero,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? Sk.card,
        borderRadius: BorderRadius.circular(Sk.radius),
        border: Border.all(color: borderColor ?? Sk.line, width: 1),
      ),
      child: child,
    );
  }
}

/// 分组标题：小字号 + 字距，放在卡片上方。
class SkSection extends StatelessWidget {
  const SkSection(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Sk.dim,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 带标签的输入框。label 在框外，避免 Material 的浮动标签在窄屏上跳来跳去。
class SkField extends StatelessWidget {
  const SkField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.maxLines = 1,
    this.minLines,
    this.suffix,
    this.onChanged,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final int maxLines;
  final int? minLines;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Sk.dim, height: 1.2),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          maxLines: obscure ? 1 : maxLines,
          minLines: obscure ? 1 : minLines,
          enabled: enabled,
          onChanged: onChanged,
          cursorColor: Sk.primary,
          style: const TextStyle(fontSize: 13.5, color: Sk.text, height: 1.35),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 12.5,
              color: Sk.dim.withValues(alpha: 0.55),
            ),
            filled: true,
            fillColor: Sk.bg.withValues(alpha: 0.55),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 36,
            ),
            border: _border(Sk.line),
            enabledBorder: _border(Sk.line),
            disabledBorder: _border(Sk.line.withValues(alpha: 0.5)),
            focusedBorder: _border(Sk.primary, width: 1.4),
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _border(Color c, {double width = 1}) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(Sk.fieldRadius),
    borderSide: BorderSide(color: c, width: width),
  );
}

/// 小圆角标签（标签、状态、计数）。
class SkTag extends StatelessWidget {
  const SkTag(this.text, {super.key, this.color = Sk.dim});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, color: color, height: 1.5),
      ),
    );
  }
}

/// 空状态：图标 + 一句说明 + 可选操作按钮。
class SkEmpty extends StatelessWidget {
  const SkEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.note,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? note;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Sk.card,
                shape: BoxShape.circle,
                border: Border.all(color: Sk.line),
              ),
              child: Icon(icon, size: 24, color: Sk.dim.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 14, color: Sk.text)),
            if (note != null) ...[
              const SizedBox(height: 6),
              Text(
                note!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: Sk.dim,
                  height: 1.5,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
