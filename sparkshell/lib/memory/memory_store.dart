import 'dart:convert';
import 'dart:io';

/// 一条跨会话长期记忆。
///
/// 故意做得很扁：只有一段文本 + 几个标签 + 时间，不搞向量、不搞图谱。
/// 手机端要在几百条量级上秒开，且条目要能直接塞进 system prompt 给人看，
/// 结构越简单越不容易出问题。
class MemoryFact {
  MemoryFact({
    required this.id,
    required this.text,
    required this.tags,
    required this.at,
  });

  final String id;
  final String text;
  final List<String> tags;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'tags': tags,
    'at': at.toIso8601String(),
  };

  /// 单条脏数据只丢自己，不连累整个文件；返回 null 由调用方跳过。
  static MemoryFact? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || id.isEmpty) return null;
    if (text is! String || text.trim().isEmpty) return null;
    final tags = raw['tags'];
    return MemoryFact(
      id: id,
      text: text.trim(),
      tags: tags is List
          ? tags
                .whereType<String>()
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList()
          : const <String>[],
      // 时间坏掉就落到最早：宁可当成很久以前，也不要冒充最新记忆挤到 prompt 前面
      at:
          DateTime.tryParse('${raw['at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 跨会话记忆库：整库一个 `memory.json`，读进内存后所有查询都走内存。
///
/// 为什么整库一个文件而不是一条一个文件：记忆总量有上限（几百条），
/// 一次启动就读完，改写时整体原子替换即可；不像会话那样会无限增长，
/// 也没有按 id 单独读取的需求。
class MemoryStore {
  MemoryStore(this.dirPath);

  /// 应用私有目录，实际落盘到 `$dirPath/memory.json`。
  final String dirPath;

  static const int _maxFacts = 500;
  static const int _maxBytes = 4 * 1024 * 1024;
  static const String _fileName = 'memory.json';

  final List<MemoryFact> _facts = <MemoryFact>[];

  /// 进程内自增序号，给 id 兜底去重（不引 uuid 包）。
  static int _seq = 0;

  String get _path => '$dirPath/$_fileName';

  /// 最近的在前。返回只读视图，避免调用方直接改乱内部顺序。
  List<MemoryFact> get facts => List<MemoryFact>.unmodifiable(_facts);

  int get count => _facts.length;

  /// 读盘。文件不存在、内容不是 JSON、结构不对，一律当空库，绝不抛。
  Future<void> load() async {
    _facts.clear();
    try {
      final f = File(_path);
      if (!await f.exists()) return;
      // 异常大的文件直接当坏文件：宁可丢记忆，也不要在主 isolate 里解析半天
      if (await f.length() > _maxBytes) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return;
      final list = raw['facts'];
      if (list is! List) return;
      for (final e in list) {
        final fact = MemoryFact.fromJson(e);
        if (fact != null) _facts.add(fact);
      }
      _tidy();
    } catch (_) {
      // 半截 JSON（写盘途中被打断）之类，当没有记忆继续跑，App 不能因此起不来
      _facts.clear();
    }
  }

  /// 新增一条记忆。同文本（trim 后相同）视为同一条，只刷新时间和标签。
  Future<MemoryFact> add(String text, {List<String> tags = const []}) async {
    final t = text.trim();
    final clean = _cleanTags(tags);
    var at = DateTime.now();
    final i = _facts.indexWhere((f) => f.text.trim() == t);

    final MemoryFact fact;
    if (i >= 0) {
      // 沿用旧 id，换成新时间：调用方手里的旧引用仍然能按 id 找到它
      if (!at.isAfter(_facts[i].at)) {
        // 同一毫秒内连说两遍也要能看出「更新过」，排序也才稳定
        at = _facts[i].at.add(const Duration(milliseconds: 1));
      }
      fact = MemoryFact(id: _facts[i].id, text: t, tags: clean, at: at);
      _facts[i] = fact;
    } else {
      fact = MemoryFact(id: _newId(at), text: t, tags: clean, at: at);
      _facts.add(fact);
    }

    _tidy();
    await save();
    return fact;
  }

  /// 按 id 删除；不存在返回 false（幂等，重复调用不产生副作用）。
  Future<bool> remove(String id) async {
    final before = _facts.length;
    _facts.removeWhere((f) => f.id == id);
    if (_facts.length == before) return false;
    await save();
    return true;
  }

  /// 空白 query 返回最近 limit 条；否则按「命中词数」打分，同分按时间新旧。
  ///
  /// 中文没有空格分词，这里不引分词包：整句当一个词做子串匹配，
  /// 用户输入多个词（空格/逗号分隔）时按命中个数排相关度，够用且可预测。
  List<MemoryFact> search(String query, {int limit = 8}) {
    if (limit <= 0) return <MemoryFact>[];
    final q = query.trim();
    if (q.isEmpty) return _facts.take(limit).toList();

    final full = q.toLowerCase();
    final words = q
        .toLowerCase()
        .split(RegExp(r'[\s,，、]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return _facts.take(limit).toList();

    final hits = <_Scored>[];
    for (var i = 0; i < _facts.length; i++) {
      final f = _facts[i];
      final hay = '${f.text} ${f.tags.join(' ')}'.toLowerCase();
      var score = 0;
      for (final w in words) {
        if (hay.contains(w)) score++;
      }
      if (score == 0) continue;
      // 整串命中比零散命中更可信，多词时给个加成，压过只中一个词的
      if (words.length > 1 && hay.contains(full)) score += words.length;
      hits.add(_Scored(f, score, i));
    }

    hits.sort((a, b) {
      final c = b.score.compareTo(a.score);
      // 同分时保持原有顺序（本来就已经是最近的在前）
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    return hits.take(limit).map((h) => h.fact).toList();
  }

  /// 给 system prompt 用的纯文本清单，每条一行「- 文本（#标签1 #标签2）」。
  ///
  /// 所有长度都按 rune 算：String.length 是 UTF-16 code unit，
  /// 用 substring 截 emoji 会劈出孤立代理项，模型那边就是乱码。
  String digest({int maxChars = 1200}) {
    final total = _facts.length;
    if (total == 0 || maxChars <= 0) return '';

    final lines = <String>[for (final f in _facts) _line(f)];

    // prefix[k] = 前 k+1 行拼起来的字符数（含行间换行）
    final prefix = List<int>.filled(total, 0);
    var acc = 0;
    for (var i = 0; i < total; i++) {
      acc += lines[i].runes.length + (i == 0 ? 0 : 1);
      prefix[i] = acc;
    }

    var keep = 0;
    while (keep < total && prefix[keep] <= maxChars) {
      keep++;
    }
    if (keep == total) return lines.join('\n');

    // 末尾「（还有 N 条）」那行也占预算，放不下就再少放一条
    while (keep > 0) {
      final tail = '…（还有 ${total - keep} 条）';
      if (prefix[keep - 1] + 1 + tail.runes.length <= maxChars) {
        return '${lines.take(keep).join('\n')}\n$tail';
      }
      keep--;
    }

    // 一条完整行都放不下：按 rune 截前半截给模型看，剩下的只说数量
    final tail = '…（还有 $total 条）';
    final room = maxChars - tail.runes.length - 1;
    if (room <= 0) return _cut(tail, maxChars);
    return '${_cut(lines.first, room)}\n$tail';
  }

  /// 原子写：先写 `.tmp` 再 rename，断电最多丢这次改动，不会留半截 JSON。
  Future<void> save() async {
    try {
      await Directory(dirPath).create(recursive: true);
      final tmp = File('$_path.tmp');
      await tmp.writeAsString(jsonEncode(_toJson()), flush: true);
      await tmp.rename(_path);
    } catch (_) {
      // 落盘失败不该打断对话：这一轮内存里的记忆照样能用，下次 add 再试
    }
  }

  Map<String, dynamic> _toJson() => {
    'version': 1,
    'facts': _facts.map((f) => f.toJson()).toList(),
  };

  /// 排好序（最近在前）、按文本去重（留最新那条）、砍到上限。
  void _tidy() {
    _facts.sort((a, b) => b.at.compareTo(a.at));
    final seen = <String>{};
    _facts.retainWhere((f) => seen.add(f.text.trim()));
    if (_facts.length > _maxFacts) {
      _facts.removeRange(_maxFacts, _facts.length);
    }
  }

  /// 渲染一行，换行压成空格，免得一条记忆把整个清单撑成多行。
  String _line(MemoryFact f) {
    final text = f.text.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
    final tags = _cleanTags(f.tags);
    if (tags.isEmpty) return '- $text';
    return '- $text（${tags.map((t) => '#$t').join(' ')}）';
  }

  /// 标签去空白、去重、去掉用户顺手打进来的 `#`。
  static List<String> _cleanTags(List<String> tags) {
    final out = <String>[];
    for (final t in tags) {
      final v = t.trim().replaceAll('#', '');
      if (v.isEmpty || out.contains(v)) continue;
      out.add(v);
    }
    return out;
  }

  /// 按 rune 截断，绝不把汉字/emoji 劈成半个。
  static String _cut(String s, int maxRunes) {
    if (maxRunes <= 0) return '';
    final runes = s.runes.toList(growable: false);
    if (runes.length <= maxRunes) return s;
    return String.fromCharCodes(runes.take(maxRunes));
  }

  String _newId(DateTime at) {
    // 时间戳在前保证 id 大致有序（便于肉眼排查），后面拼进程内序号 + 对象哈希
    // 防同一微秒内碰撞；pubspec 不加依赖是硬约束，所以不用 uuid 包。
    final t = at.microsecondsSinceEpoch.toRadixString(36);
    final seq = (_seq++ & 0xffff).toRadixString(36);
    final r = Object().hashCode.toUnsigned(32).toRadixString(36);
    return 'm$t$seq$r';
  }
}

/// search 的中间结果，只为了排序时带上原始位置做稳定的同分兜底。
class _Scored {
  _Scored(this.fact, this.score, this.order);

  final MemoryFact fact;
  final int score;
  final int order;
}
