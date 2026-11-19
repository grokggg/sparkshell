// 图片 → OpenAI 兼容内容块（`image_url` + data URL）。
//
// 为什么单独一个文件：把「哪些图能发、发多大、发成什么形状」收在一处。
// llm_client 只负责序列化和降级，不掺和字节层面的判断；以后要换压缩策略
// 或者接别的图片协议，只改这里。
//
// 不引第三方包：魔数判断 + base64 用 dart:convert / dart:typed_data 就够，
// 少一个依赖（image 包还会把 APK 撑大几 MB，而我们只做「识别 + 编码」，
// 不做缩放/裁剪，用不上它）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../files/fs_service.dart';
import '../linux_env.dart';

/// 单张图片的字节上限：1.2 MiB。
///
/// 为什么卡这么小：
/// 1. base64 会把体积放大 4/3，1.2 MiB 的截图在 JSON 里就是 1.6 M 字符；
///    免费中转站的请求体上限和上下文窗口都很紧，再大要么被网关直接掐断
///    （413 / 400），要么把这一轮对话的 token 预算吃光，模型反而没余量干活。
/// 2. 手机截屏一般 300 KB～1 MB，1.2 MiB 足够覆盖；真超了说明是原图/长截图，
///    应该先让容器里的工具缩一下再发，而不是硬塞。
///
/// 超限的处置是「拒绝 + 回调说明」，绝不静默发巨大 base64——那种请求用户只会
/// 看到「卡住」「超时」，根本不知道是自己图太大。
const int kMaxImageBytes = 1258291; // 1.2 * 1024 * 1024，取整

/// 图片一张都没带上时，文本块里用的兜底话术。
const String kFallbackImageText = '请看这张图。';

/// 降级时补在消息末尾的说明。
const String kVisionFallbackNote = '（当前模型看不了图片，已只发文字）';

/// 容器路径 → 宿主路径需要的 rootfs 根目录。
///
/// 容器里的 `/root/inbox/a.jpg` 物理上是宿主 `filesDir/rootfs/root/inbox/a.jpg`，
/// 读文件必须做这层映射。默认取 [LinuxEnv] 记住的那个（只有 proot 启动过才有值）；
/// 测试或桌面环境可以把它换成返回临时目录的函数，也可以不管——[_locate]
/// 永远会把「传进来的原路径」当第二个候选再试一次，所以直接传宿主路径也能工作。
String? Function() rootfsPathProvider = () => LinuxEnv.instance.rootfsPath;

/// 按文件头（magic bytes）判断图片 MIME，识别不了返回 null。
///
/// 为什么不信扩展名：Android 上图片经过相册、微信、下载器转手，扩展名和真实
/// 格式对不上是常态（`.jpg` 里装 PNG、WebP 存成 `.png`）。按字节判最可靠，
/// 扩展名只在魔数认不出来时兜底。
String? sniffImageMime(Uint8List head) {
  if (head.length >= 3 &&
      head[0] == 0xFF &&
      head[1] == 0xD8 &&
      head[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (head.length >= 8 &&
      head[0] == 0x89 &&
      head[1] == 0x50 &&
      head[2] == 0x4E &&
      head[3] == 0x47 &&
      head[4] == 0x0D &&
      head[5] == 0x0A &&
      head[6] == 0x1A &&
      head[7] == 0x0A) {
    return 'image/png';
  }
  if (head.length >= 6) {
    final ascii = String.fromCharCodes(head.take(6));
    // GIF87a / GIF89a
    if (ascii.startsWith('GIF8') && (ascii[4] == '7' || ascii[4] == '9') && ascii[5] == 'a') {
      return 'image/gif';
    }
  }
  if (head.length >= 12) {
    final ascii = String.fromCharCodes(head.take(12));
    // RIFF....WEBP
    if (ascii.startsWith('RIFF') && ascii.substring(8) == 'WEBP') return 'image/webp';
  }
  return null;
}

/// 扩展名 → MIME；不认识的扩展名返回 null。
String? mimeFromExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  switch (path.substring(dot + 1).toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
  }
  return null;
}

/// 把容器里的一张图读成 OpenAI 兼容的 content block。
///
/// 返回 `{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}`；
/// 文件不存在、不是图片、超过 [maxBytes] 时返回 null，并把原因交给 [onReject]。
///
/// 为什么用 null + 回调而不是抛异常：一张图失败不应该毁掉整轮对话——用户发的
/// 是「截图 + 一句话」，图坏了文字还得能发出去。上层拿到 null 可以只提示一句
/// 「这张图没带上：太大」，然后继续。
Future<Map<String, dynamic>?> buildImagePart(
  String containerPath, {
  int maxBytes = kMaxImageBytes,
  void Function(String path, String reason)? onReject,
}) async {
  Map<String, dynamic>? reject(String reason) {
    onReject?.call(containerPath, reason);
    return null;
  }

  final file = await _locate(containerPath);
  if (file == null) return reject('容器里找不到这个文件');

  final name = file.path.split('/').last;
  final extMime = mimeFromExtension(name);

  // 先看长度再读：10 MB 的图读进内存再判断大小，等于白白占一次堆。
  final length = await file.length();
  if (length <= 0) return reject('文件是空的');
  if (length > maxBytes) {
    return reject('图片太大（${_mb(length)}，上限 ${_mb(maxBytes)}）');
  }

  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } on FileSystemException catch (e) {
    return reject('读不了这个文件（${e.osError?.message ?? e.message}）');
  }

  // 魔数优先，扩展名只在「认不出来」时决定报错文案。
  // 注意这里**不**用扩展名兜底放行：`.jpg` 里塞一段文本是常见的（下载失败、
  // 缓存占位、改后缀），把这种字节按 image/jpeg 发出去，服务端一定会 400，
  // 用户看到的却是「模型看不了图」——真正的原因被彻底藏起来了。
  final mime = sniffImageMime(bytes);
  if (mime == null) {
    return reject(extMime == null
        ? '不是支持的图片格式（只支持 jpg/png/webp/gif）'
        : '文件内容不是图片（扩展名是图片，但文件头认不出来）');
  }

  return <String, dynamic>{
    'type': 'image_url',
    'image_url': {'url': 'data:$mime;base64,${base64Encode(bytes)}'},
  };
}

/// 把「用户打的字 + 本轮图片」拼成一条消息的 content。
///
/// - 没有可用图片：返回纯 String。纯文本模型、老调用方完全不受影响，
///   这也是「加图片通道但别搞死文本模型」的关键——没有图就还是老样子。
/// - 有图片：返回 `[{type:text}, {type:image_url}, ...]`，OpenAI 多模态标准形状。
///
/// [onReject] 逐张回调失败原因（太大 / 格式不支持 / 找不到），界面可以据此提示。
Future<Object> buildUserContent(
  String text,
  List<String> imagePaths, {
  void Function(String path, String reason)? onReject,
}) async {
  final blocks = <Map<String, dynamic>>[];
  final reasons = <String>[];

  for (final p in imagePaths) {
    final part = await buildImagePart(p, onReject: (path, reason) {
      reasons.add(reason);
      onReject?.call(path, reason);
    });
    if (part != null) blocks.add(part);
  }

  if (blocks.isEmpty) {
    if (reasons.isEmpty) return text;
    // 用户明明发了图，一张都没成功：不能装作没发生，否则模型会答非所问，
    // 用户也永远不知道自己的图没上去。这里把原因写进正文。
    final note = '（有 ${reasons.length} 张图片没能附带：${reasons.toSet().join('；')}）';
    final body = text.trim();
    return body.isEmpty ? note : '$text\n\n$note';
  }

  final body = text.trim();
  return <Map<String, dynamic>>[
    // 有些接入点对「只有图没有文字」的 content 比较挑，空文本时补一句极短的引导。
    {'type': 'text', 'text': body.isEmpty ? kFallbackImageText : text},
    ...blocks,
  ];
}

/// 这轮消息里有没有图片块。
bool hasImageParts(List<Map<String, dynamic>> messages) {
  for (final m in messages) {
    final content = m['content'];
    if (content is List &&
        content.any((b) => b is Map && b['type'] == 'image_url')) {
      return true;
    }
  }
  return false;
}

/// 去掉消息里所有图片块，只留文字，并在最后一条 user 消息末尾补 [note]。
///
/// 为什么返回新列表、不改原对象：调用方（聊天页）手里的 history 还要落盘，
/// 降级只应该影响「这一次请求」——历史里的图不能被擦掉，否则用户下次换一个
/// 能看图的模型，图就没了。
///
/// 为什么要补那句话：用户看得见自己发了图，模型却只收到文字，不解释一句
/// 模型会以为用户说的是「空消息」，答得莫名其妙。
List<Map<String, dynamic>> stripImageParts(
  List<Map<String, dynamic>> messages, {
  String note = kVisionFallbackNote,
}) {
  final out = <Map<String, dynamic>>[];
  var lastUserIndex = -1;
  var removed = 0;

  for (final m in messages) {
    final copied = <String, dynamic>{...m};
    final content = copied['content'];
    if (content is List) {
      final texts = <String>[];
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          final t = block['text'];
          if (t is String && t.isNotEmpty) texts.add(t);
        } else {
          removed++;
        }
        // image_url 以及未知类型一律丢掉：降级的目的就是「只发文字」。
      }
      copied['content'] = texts.join('\n');
    }
    if (copied['role'] == 'user') lastUserIndex = out.length;
    out.add(copied);
  }

  // 本来就没有图：别画蛇添足加「看不了图片」的说明，否则纯文本对话里
  // 每次调用都会多出一句莫名其妙的提示。
  if (removed == 0) return out;

  if (lastUserIndex >= 0) {
    final cur = out[lastUserIndex]['content'];
    final text = cur is String ? cur.trimRight() : '';
    out[lastUserIndex]['content'] = text.isEmpty ? note : '$text\n$note';
  }
  return out;
}

/// 容器路径 → 真实存在的宿主文件；找不到返回 null。
Future<File?> _locate(String path) async {
  var p = path.trim();
  if (p.isEmpty) return null;

  // 有些选择器/剪贴板会给 file:// URI，顺手接住
  if (p.startsWith('file://')) {
    try {
      p = Uri.parse(p).toFilePath();
    } catch (_) {
      return null;
    }
  }

  final guest = FsService.normalize(p);
  if (guest == '\u0000') return null; // 含 .. 越界，直接拒

  final candidates = <String>[];
  final root = rootfsPathProvider();
  if (root != null && root.trim().isNotEmpty) {
    final r = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    candidates.add('$r/$guest');
  }
  // 原路径也试一次：桌面 / 测试环境没有 rootfs 前缀，传进来的本来就是宿主路径。
  candidates.add('/$guest');

  for (final c in candidates) {
    final f = File(c);
    if (await f.exists()) return f;
  }
  return null;
}

/// 字节数 → 给用户看的 MB 文案（1.3 MB）。
String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// 容器内路径看着像不像图片（按扩展名）。
///
/// 只用来决定「这一轮要不要按多模态发」；真正的格式判定在 [buildImagePart] 里
/// 看 magic bytes，扩展名骗人也不会把非法数据发出去。
bool isImagePath(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.webp') ||
      p.endsWith('.gif');
}

/// 把一条 content 换到「最后一条 user 消息」上。
///
/// 单独抽出来是为了能测：聊天页是 StatefulWidget，直接测要起整个界面，
/// 而这里真正容易错的是"改哪一条"——改错就会出现"图和问题脱节"。
bool replaceLastUserContent(List<Map<String, dynamic>> history, Object content) {
  final idx = history.lastIndexWhere((m) => m['role'] == 'user');
  if (idx < 0) return false;
  history[idx] = <String, dynamic>{'role': 'user', 'content': content};
  return true;
}
