import 'package:flutter/services.dart';

/// 附件选择失败时抛出的异常，`toString()` 直接就是能贴到 UI 上的中文句子。
class AttachmentPickerException implements Exception {
  AttachmentPickerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 聊天附件选择器：从系统相册 / 文件管理器挑文件，**复制进容器**的 `/root/inbox/`。
///
/// 为什么不把 `/sdcard` 上的原始路径直接交给模型？
/// 1. 容器（proot 的 alpine/debian）根目录是宿主的 `filesDir/rootfs`，容器里根本没有
///    Android 的 `/sdcard`；要访问得额外 bind mount，proot 一重启就没了，路径不稳定。
/// 2. Scoped Storage 之下 `content://` URI 是临时的授权，进程一退就失效；把 URI 直接
///    塞进对话历史，下一轮模型要读时权限早没了。
/// 3. 复制进 rootfs 之后文件属于我们自己的私有目录，容器内的 shell、python、模型工具
///    都能用普通的 `open('/root/inbox/x.jpg')` 读，不用关心 Android 的权限模型。
///
/// 代价是占一份磁盘（单文件上限由原生侧限制为 200MB），换来的是路径长期有效、语义统一。
class AttachmentPicker {
  AttachmentPicker._();

  /// 原生 IO 通道。Java 侧同一个 handler 同时挂在 `sparkshell/io` 和这个包名通道上。
  static const MethodChannel _channel =
      MethodChannel('com.xinghuo.sparkshell/io');

  /// 容器内的附件落点，与 MainActivity.INBOX_DIR 保持一致。
  static const String inboxDir = '/root/inbox';

  /// 选图片（系统相册 / 图片文档），可多选。
  ///
  /// 返回容器内路径列表，如 `['/root/inbox/IMG_001.jpg']`；
  /// 用户取消返回空列表；失败抛 [AttachmentPickerException]。
  static Future<List<String>> images() => _pick('pickImages', '图片');

  /// 选任意文件（文档、压缩包、音频…），可多选。
  ///
  /// 返回值与失败语义同 [images]。
  static Future<List<String>> files() => _pick('pickFiles', '文件');

  /// 统一调用与错误翻译：原生只回 code/message，这里翻成人话。
  static Future<List<String>> _pick(String method, String label) async {
    try {
      final res = await _channel.invokeMethod<List<dynamic>>(method);
      if (res == null || res.isEmpty) return const <String>[];
      // 原生回的是 ArrayList<String>，解码后可能是 List<Object?>，统一收成字符串并丢掉空项。
      return res
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      // 通道不存在：多半是跑在桌面/测试环境，或者原生侧漏注册了通道。
      throw AttachmentPickerException(
        '当前环境不支持选择$label：原生通道 com.xinghuo.sparkshell/io 不可用',
      );
    } on PlatformException catch (e) {
      throw AttachmentPickerException(_explain(e, label));
    }
  }

  /// 调系统相机拍一张（单张，不是列表）。
  ///
  /// 返回容器内路径，如 `/root/inbox/photo-20261119-143012.jpg`；
  /// 用户取消返回 null；设备没有相机 App 时抛 [AttachmentPickerException]（code `no_camera`）。
  ///
  /// 原生侧会先把照片写进 `filesDir/camera_tmp` 的临时文件，复制进容器后立刻删掉，
  /// 所以这里拿到的路径一定在 `/root/inbox` 里，宿主上的临时文件不会残留。
  static Future<String?> camera() async {
    try {
      final res = await _channel.invokeMethod<String>('pickCamera');
      final path = (res ?? '').trim();
      return path.isEmpty ? null : path;
    } on MissingPluginException {
      throw AttachmentPickerException(
        '当前环境不支持拍照：原生通道 com.xinghuo.sparkshell/io 不可用',
      );
    } on PlatformException catch (e) {
      throw AttachmentPickerException(_explain(e, '照片'));
    }
  }

  static String _explain(PlatformException e, String label) {
    final detail = (e.message ?? '').trim();
    switch (e.code) {
      case 'busy':
        return '系统选择器正在使用中，请先完成上一次选择';
      case 'no_picker':
        return '设备上没有可用的文件选择器${detail.isEmpty ? '' : '：$detail'}';
      case 'no_camera':
        // 原生侧这句已经是人话，直接透传；兜底再给一句。
        return detail.isEmpty ? '设备上没有可用的相机' : detail;
      case 'permission':
        return detail.isEmpty
            ? '没有相机权限，请在系统设置里允许 SparkShell 使用相机'
            : '相机权限不足：$detail。可在系统设置里允许 SparkShell 使用相机';
      case 'camera_failed':
        return detail.isEmpty ? '拍照失败，请重试' : detail;
      case 'import_failed':
        return detail.isEmpty ? '复制$label到容器失败' : detail;
      case 'bad_args':
        return '参数不正确${detail.isEmpty ? '' : '：$detail'}';
      default:
        return '选择$label失败${detail.isEmpty ? '' : '：$detail'}';
    }
  }
}

/// 把「用户打的字 + 本轮附件」拼成真正发给模型的那条消息。
///
/// 为什么不把图片转 base64 塞进多模态字段？
/// - 免费接入点（qiniu/conatus-free）是纯文本模型，塞 image_url 会直接 400；
/// - 容器里已经有真文件，模型用 bash / read_file / python 都能读，还能缩图、裁切、OCR；
/// - base64 一张 3MB 的截图 ≈ 4M 字符，够把上下文吃干净。
/// 所以只给路径 + 一句提示，让模型的工具去读。
String composeWithAttachments(String typed, List<String> files) {
  if (files.isEmpty) return typed;
  final buf = StringBuffer();
  if (typed.isNotEmpty) {
    buf.writeln(typed);
    buf.writeln();
  }
  buf.writeln('（附件已放进容器，可直接读）');
  for (final f in files) {
    buf.writeln('- $f');
  }
  return buf.toString().trimRight();
}
