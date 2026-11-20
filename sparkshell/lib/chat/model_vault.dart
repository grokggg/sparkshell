import 'dart:convert';

/// 一条模型记录：名字 + 归属接入点 + 用户态度（固定 / 思考标注）。
///
/// 字段可变，pin 和思考开关都是就地改；增删一律走 [ModelVault]，
/// 免得外面拿到 entry 后绕过上限和去重规则。
class ModelEntry {
  ModelEntry({
    required this.id,
    this.baseUrl = '',
    this.pinned = false,
    this.thinking,
    int? addedAt,
    this.lastUsedAt = 0,
  }) : addedAt = addedAt ?? DateTime.now().millisecondsSinceEpoch;

  /// 模型名，如 'kilo-auto/free'。
  String id;

  /// 归属接入点；'' = 通用，任何接入点都能选到。
  String baseUrl;

  /// 固定：永不被上限淘汰，也不会被「从接入点拉取」的批量结果冲掉。
  bool pinned;

  /// null = 按名字猜；true/false = 用户手动标注过。
  bool? thinking;

  int addedAt;
  int lastUsedAt; // 0 = 没用过

  bool get used => lastUsedAt > 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseUrl': baseUrl,
        'pinned': pinned,
        'thinking': thinking,
        'addedAt': addedAt,
        'lastUsedAt': lastUsedAt,
      };

  /// 脏数据返回 null 直接丢掉：一条坏记录不该带崩整份配置。
  static ModelEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final t = raw['thinking'];
    return ModelEntry(
      id: id,
      baseUrl: '${raw['baseUrl'] ?? ''}'.trim(),
      pinned: raw['pinned'] == true,
      thinking: t is bool ? t : null,
      addedAt: (raw['addedAt'] as num?)?.toInt() ?? 0,
      lastUsedAt: (raw['lastUsedAt'] as num?)?.toInt() ?? 0,
    );
  }

  ModelEntry copy() => ModelEntry(
        id: id,
        baseUrl: baseUrl,
        pinned: pinned,
        thinking: thinking,
        addedAt: addedAt,
        lastUsedAt: lastUsedAt,
      );

  @override
  String toString() =>
      '$id${baseUrl.isEmpty ? '' : '@$baseUrl'}${pinned ? ' [固定]' : ''}';
}

/// 模型档案库：见过的模型都留档，固定项永不丢。
///
/// 为什么不再用「一个滚动列表」：模型是用户资产，手填一次就该留在原地；
/// 从 /v1/models 拉回来的一大堆只是缓存，可以按上限淘汰。
/// 两者的区别就是 [ModelEntry.pinned] 这一个位。
class ModelVault {
  ModelVault({this.maxUnpinned = 200});

  /// 未固定项的上限；固定项不占额度、也永不淘汰。
  int maxUnpinned;

  final List<ModelEntry> _items = [];

  /// 只读视图，已按「固定优先、再按最近使用」排好。
  List<ModelEntry> get entries => List.unmodifiable(_ordered());

  ModelEntry? find(String id, {String baseUrl = ''}) {
    final name = id.trim();
    final url = baseUrl.trim();
    for (final e in _items) {
      if (e.id == name && e.baseUrl == url) return e;
    }
    return null;
  }

  /// 时间戳强行单调递增：同一毫秒里连续 add 也能排出先后，
  /// 否则「最近使用」和淘汰顺序在快机器上全是随机数。
  int _stamp() {
    var now = DateTime.now().millisecondsSinceEpoch;
    for (final e in _items) {
      if (e.lastUsedAt >= now) now = e.lastUsedAt + 1;
      if (e.addedAt >= now) now = e.addedAt + 1;
    }
    return now;
  }

  /// 追加一条。同 id + 同 baseUrl 只更新 thinking，不产生重复，
  /// 也不碰 pinned/addedAt —— 拉取式批量写不能把用户固定过的那条降级。
  /// 返回是否新建。
  bool add(String id, {String baseUrl = '', bool? thinking}) {
    final name = id.trim();
    if (name.isEmpty) return false;
    final url = baseUrl.trim();
    final hit = find(name, baseUrl: url);
    if (hit != null) {
      if (thinking != null) hit.thinking = thinking;
      return false;
    }
    _items.add(ModelEntry(
      id: name,
      baseUrl: url,
      thinking: thinking,
      addedAt: _stamp(),
    ));
    _evict();
    return true;
  }

  /// 设为固定；不存在就先建档再固定。
  void pin(String id, {String baseUrl = ''}) {
    final name = id.trim();
    if (name.isEmpty) return;
    final url = baseUrl.trim();
    final hit = find(name, baseUrl: url);
    if (hit != null) {
      hit.pinned = true;
      return;
    }
    _items.add(ModelEntry(
      id: name,
      baseUrl: url,
      pinned: true,
      addedAt: _stamp(),
    ));
    _evict();
  }

  void unpin(String id, {String baseUrl = ''}) {
    final hit = find(id, baseUrl: baseUrl);
    if (hit == null) return;
    hit.pinned = false;
    _evict(); // 取消固定后可能超额度，按最久未用淘汰
  }

  void remove(String id, {String baseUrl = ''}) {
    final name = id.trim();
    final url = baseUrl.trim();
    _items.removeWhere((e) => e.id == name && e.baseUrl == url);
  }

  /// 记录一次使用：更新 lastUsedAt，排序时自然靠前。
  ///
  /// baseUrl 缺省时（UI 里常常只拿得到模型名）就近认领同名条目，
  /// 不另建一条「通用」档 —— 否则同一个模型会同时存在通用档和接入点档两份。
  void markUsed(String id, {String baseUrl = ''}) {
    final name = id.trim();
    if (name.isEmpty) return;
    var hit = find(name, baseUrl: baseUrl);
    if (hit == null) {
      for (final e in _ordered()) {
        if (e.id == name) {
          hit = e;
          break;
        }
      }
    }
    if (hit == null) {
      add(name); // 真没见过才建档
      hit = find(name);
      if (hit == null) return;
    }
    hit.lastUsedAt = _stamp();
  }

  /// 手动标注思考支持；同名任意接入点的条目一起改，
  /// 一个都没有就补一条通用（''）的，免得标注跟着接入点走丢。
  void annotate(String id, bool? thinking) {
    final name = id.trim();
    if (name.isEmpty) return;
    var any = false;
    for (final e in _items) {
      if (e.id == name) {
        e.thinking = thinking;
        any = true;
      }
    }
    if (!any) add(name, thinking: thinking);
  }

  /// 用户手动标注的值；null = 没标注过，交给名字规则猜。
  bool? thinkingOf(String id) {
    final name = id.trim();
    for (final e in _ordered()) {
      if (e.id == name && e.thinking != null) return e.thinking;
    }
    return null;
  }

  /// 某个接入点能选什么：本接入点的 + 通用的（''）。
  List<ModelEntry> forEndpoint(String baseUrl) {
    final url = baseUrl.trim();
    return _ordered()
        .where((e) => e.baseUrl.isEmpty || e.baseUrl == url)
        .toList();
  }

  /// 给选择器用的名字列表；current 不在其中就插到最前，
  /// 保证「当前模型」永远可选可显示（配置里写了个没见过的名字也不至于看不见）。
  List<String> chooseList({String baseUrl = '', String current = ''}) {
    final out = <String>[];
    for (final e in forEndpoint(baseUrl)) {
      if (!out.contains(e.id)) out.add(e.id);
    }
    final cur = current.trim();
    if (cur.isNotEmpty && !out.contains(cur)) out.insert(0, cur);
    return out;
  }

  /// 最近用过的名字（去重），旧版 `models` 字段靠它保持可读。
  List<String> recentNames({int limit = 80}) {
    if (limit <= 0) return const [];
    final list = [..._items]..sort((a, b) {
        final u = b.lastUsedAt.compareTo(a.lastUsedAt);
        return u != 0 ? u : b.addedAt.compareTo(a.addedAt);
      });
    final out = <String>[];
    for (final e in list) {
      if (!out.contains(e.id)) out.add(e.id);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 该模型吃不吃思考参数：手动标注优先，否则回落到名字正则。
  bool supportsThinking(String id) => thinkingOf(id) ?? looksThinking(id);

  /// 名字里带这些的基本都吃 `reasoning_effort` / `thinking`：
  /// reasoner / thinking / r1 / qwq / qwen3 / glm-4.5 / z1 / kimi-k2 / o1-o4 / gpt-5。
  static bool looksThinking(String id) => RegExp(
        r'(reasoner|thinking|deepseek-r1|qwq|qwen3|glm-4\.5|glm-z1|kimi-k2|(^|[/-])o[1-4]([/-]|$)|gpt-5)',
        caseSensitive: false,
      ).hasMatch(id);

  /// 整体替换内容：load() 反序列化 / 旧格式迁移时用，别在外面随手调。
  void restore(Iterable<ModelEntry> items, {int? maxUnpinned}) {
    if (maxUnpinned != null) this.maxUnpinned = maxUnpinned;
    _items
      ..clear()
      ..addAll(items.map((e) => e.copy()));
    _dedupe();
    _evict();
  }

  Map<String, dynamic> toJson() => {
        'maxUnpinned': maxUnpinned,
        'entries': [for (final e in _items) e.toJson()],
      };

  static ModelVault fromJson(Object? raw, {int maxUnpinned = 200}) {
    final v = ModelVault(maxUnpinned: maxUnpinned);
    if (raw is! Map) return v;
    final cap = raw['maxUnpinned'];
    if (cap is int && cap >= 0) v.maxUnpinned = cap;
    final list = raw['entries'];
    if (list is List) {
      for (final e in list) {
        final entry = ModelEntry.tryParse(e);
        if (entry != null) v._items.add(entry);
      }
    }
    v._dedupe();
    return v;
  }

  /// 固定优先，再按最近使用倒序。
  List<ModelEntry> _ordered() {
    final list = [..._items];
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final u = b.lastUsedAt.compareTo(a.lastUsedAt);
      return u != 0 ? u : b.addedAt.compareTo(a.addedAt);
    });
    return list;
  }

  void _dedupe() {
    final seen = <String>{};
    _items.retainWhere((e) => seen.add('${e.id}\u0000${e.baseUrl}'));
  }

  /// 超额度就淘汰「未固定、最久未使用」的那条；全固定则一条不动。
  void _evict() {
    if (maxUnpinned < 0) return;
    while (true) {
      final unpinned = _items.where((e) => !e.pinned).toList();
      if (unpinned.length <= maxUnpinned) return;
      ModelEntry? worst;
      for (final e in unpinned) {
        if (worst == null || _older(e, worst)) worst = e;
      }
      if (worst == null) return;
      _items.remove(worst);
    }
  }

  static bool _older(ModelEntry a, ModelEntry b) {
    // 没用过的（lastUsedAt=0）优先淘汰；同分再看谁先建档。
    if (a.lastUsedAt != b.lastUsedAt) return a.lastUsedAt < b.lastUsedAt;
    return a.addedAt < b.addedAt;
  }

  /// 落盘前自检用：整份档案变字符串，方便肉眼比对。
  String dump() => jsonEncode(toJson());
}
