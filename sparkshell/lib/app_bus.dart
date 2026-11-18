import 'package:flutter/foundation.dart';

/// 跨页面的轻量信号总线：文件页把路径丢进来，Chat 页取走插进输入框。
/// 不引第三方状态管理，够用就行。
class AppBus {
  AppBus._();

  /// 待插入 Chat 输入框的容器内路径（如 /root/hello.py）
  static final ValueNotifier<String?> pendingChatFile = ValueNotifier(null);
}
