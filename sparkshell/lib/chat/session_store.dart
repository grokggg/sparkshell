import 'dart:convert';
import 'dart:io';

/// 会话持久化：纯 Dart，不碰 Flutter，方便在桌面直接跑测试。
///
/// 一个会话 = 一个 `<id>.json`，messages 保持 OpenAI 格式原样往返，
/// 这样 tool_calls / tool 结果回放时不用再做转换。
class Session {
  Session({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  String title;
  DateTime updatedAt;
  final List<Map<String, dynamic>> messages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages,
      };

  static Session? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || !_idOk(id)) return null;
    final msgs = raw['messages'];
    return Session(
      id: id,
      title: raw['title'] is String ? raw['title'] as String : '未命名',
      updatedAt: DateTime.tryParse('${raw['updatedAt']}') ?? DateTime.now(),
      messages: msgs is List
          ? msgs.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[],
    );
  }

  /// 只允许十六进制，杜绝 `../` 之类的路径拼接。
  static final _re = RegExp(r'^[0-9a-f]{8,32}$');
  static bool _idOk(String id) => _re.hasMatch(id);
}

class SessionStore {
  SessionStore(this.dirPath);

  final String dirPath;
  static const _maxBytes = 2 * 1024 * 1024;

  Directory get _dir => Directory(dirPath);

  Future<void> _ensure() => _dir.create(recursive: true);

  Future<List<Session>> list() async {
    await _ensure();
    final out = <Session>[];
    await for (final e in _dir.list(followLinks: false)) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final s = await _read(e);
      if (s != null) out.add(s);
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<Session> create([String title = '新会话']) async {
    final s = Session(
      id: _newId(),
      title: title,
      updatedAt: DateTime.now(),
      messages: <Map<String, dynamic>>[],
    );
    await save(s);
    return s;
  }

  Future<void> save(Session s) async {
    if (!Session._idOk(s.id)) throw ArgumentError('非法会话 id: ${s.id}');
    await _ensure();
    s.updatedAt = DateTime.now();
    final target = File('$dirPath/${s.id}.json');
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(s.toJson()), flush: true);
    await tmp.rename(target.path); // 原子替换，断电不会留半截文件
  }

  Future<Session?> load(String id) async {
    if (!Session._idOk(id)) return null;
    final f = File('$dirPath/$id.json');
    if (!await f.exists()) return null;
    return _read(f);
  }

  Future<void> delete(String id) async {
    if (!Session._idOk(id)) return;
    final f = File('$dirPath/$id.json');
    if (await f.exists()) await f.delete();
  }

  /// 只保留最新 keep 个，防止聊一年把手机塞满。
  Future<void> prune({int keep = 60}) async {
    final all = await list();
    for (final s in all.skip(keep < 0 ? 0 : keep)) {
      await delete(s.id);
    }
  }

  /// 抽屉里显示的一行摘要。
  String preview(Session s) {
    for (var i = s.messages.length - 1; i >= 0; i--) {
      final m = s.messages[i];
      if (m['role'] == 'user') {
        final t = '${m['content'] ?? ''}'.replaceAll('\n', ' ').trim();
        if (t.isEmpty) break;
        return t.length > 40 ? '${t.substring(0, 40)}…' : t;
      }
    }
    return s.title;
  }

  Future<Session?> _read(File f) async {
    try {
      final len = await f.length();
      if (len > _maxBytes) return null;
      final raw = jsonDecode(await f.readAsString());
      return Session.fromJson(raw);
    } catch (_) {
      return null; // 坏文件当不存在，绝不让一条脏数据拖垮整个列表
    }
  }

  String _newId() {
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16).substring(8);
    final id = '$t$r';
    return id.substring(id.length > 24 ? id.length - 24 : 0);
  }
}
