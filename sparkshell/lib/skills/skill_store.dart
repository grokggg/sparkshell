// 技能（Skill）存储层：一个目录 = 一个能力，热插拔，不重装、不改代码。
//
// 设计取舍（先看这四条，再看代码）：
// 1) 纯 Dart：只 import dart:io / dart:convert，不碰 Flutter。这样同一份代码可以在
//    手机里跑（Android 私有目录），也可以在桌面/CI 里用 `dart run` 直接跑测试。
// 2) 手写 frontmatter 解析，不引 yaml 包：
//    - pubspec.yaml 里没有 yaml 依赖（它只是别的包的传递依赖，不能直接 import，
//      否则换个依赖树就编译不过）；path 包同理，所以路径拼接也是手写的。
//    - SKILL.md 的头部是「极小子集」：key: value + 逗号列表。为这点语法拖一个完整
//      YAML 1.2 实现进来，等于把「用户随手写一个 markdown 就多一个能力」变成
//      「用户必须先学会 YAML」（缩进、引号、多行折叠、锚点……写错就整份技能加载失败）。
//    - 手写解析器可以刻意做成「宽容模式」：坏行跳过、缺 key 用兜底值、frontmatter
//      没闭合就当没有。技能是用户手写的内容，容错率比严格性重要得多。
// 3) 同名安装先备份成 SKILL.md.bak：技能是纯文本、用户会反复改，一旦写错就是
//    「能力消失」。单槽滚动备份的代价几乎为零（一份文本），却能让人在写坏之后
//    一条 `mv SKILL.md.bak SKILL.md` 就回滚；只留一版是为了不让目录随编辑次数膨胀，
//    真正的历史版本应该交给 git，而不是让 App 在手机上堆快照。
// 4) 缓存 + reload：扫描是 IO，Agent 每轮都要读技能列表，不能每次都 hit 磁盘；
//    但「多放一个目录就多一个能力」意味着文件会在运行期变化，所以 open() 扫一次、
//    reload() 手动重扫，`all` 返回不可变副本，避免调用方拿到内部 List 后被并发改坏。

import 'dart:convert';
import 'dart:io';

/// 一个技能 = 一份 SKILL.md 的解析结果。
///
/// 所有字段都是 final：技能对象是「某一时刻磁盘内容的快照」，改了文件就 reload
/// 生成新对象，不做原地可变状态，免得 UI 显示的内容和磁盘悄悄不一致。
class Skill {
  Skill({
    required this.name,
    required this.description,
    required this.body,
    required this.allowedTools,
    required this.dir,
    required this.tags,
  });

  /// 展示名。frontmatter 的 name 优先，缺失时退化到目录名/文件名。
  final String name;

  /// 一句话说明。frontmatter 的 description 优先，缺失时退化到正文第一行。
  final String description;

  /// 正文（markdown 原文，frontmatter 之后的部分）。
  final String body;

  /// 这个技能被允许调用的工具白名单；空表示不限制（由调用方决定默认策略）。
  final List<String> allowedTools;

  /// 技能所在目录。目录形式是 `<skills>/<slug>`，单文件形式是 `<skills>`。
  /// 需要读同目录下的模板/脚本时用它拼路径。
  final String dir;

  /// 分类标签，用于 UI 分组或检索。
  final List<String> tags;

  /// 列表里的一行摘要，最多 100 个字符（按 rune 截断，避免把 emoji/中文切成半个）。
  ///
  /// 为什么截断：技能名和描述都是用户写的，一条 500 字的描述会把列表撑爆；
  /// 100 字足够 Agent 决定「要不要深入读 body」。
  String get oneLine {
    final s = '$name — $description';
    final runes = s.runes.toList();
    if (runes.length <= 100) return s;
    // 留一个字符给省略号，保证结果恰好 100 字符。
    return '${String.fromCharCodes(runes.take(99))}…';
  }

  @override
  String toString() => 'Skill($name)';
}

/// 技能仓库：负责扫描、解析、安装、删除。
///
/// 目录布局（两种都支持，可混放）：
/// ```
/// <dir>/                    // dir == baseDir/skills
///   my-skill/SKILL.md       // 目录形式：一个技能一个目录，能给技能配附带文件
///   quick-note.md           // 单文件形式：只想丢一个小技能时不用建目录
/// ```
class SkillStore {
  SkillStore._(this._dirPath);

  /// 技能根目录（`baseDir/skills`），不存在时 open() 会建出来。
  final String _dirPath;

  /// 缓存：按扫描顺序排好序的不可变列表。
  List<Skill> _skills = const <Skill>[];

  /// 名字（小写）→ 实际文件，remove() 用它定位要删的文件。
  Map<String, File> _files = const <String, File>{};

  /// 单个 SKILL.md 的读取上限。技能是提示词正文，512KB 已经很夸张了；
  /// 设上限是为了防止误放一个日志文件进来把内存和列表渲染拖死。
  static const int _maxBytes = 512 * 1024;

  /// 打开（或初始化）一个技能仓库。
  ///
  /// 目录不存在就递归创建空目录并返回空列表 —— 不抛异常。理由：首次启动时
  /// 「还没有任何技能」是正常状态，不该让上层写 try/catch 去区分「没装」和「坏了」。
  static Future<SkillStore> open(String baseDir) async {
    final store = SkillStore._(_join(baseDir, 'skills'));
    try {
      await Directory(store._dirPath).create(recursive: true);
    } on FileSystemException {
      // 只读挂载点 / 权限不足：仍然返回可用对象（只是空仓库），
      // 让 UI 能显示「无法写入技能目录」，而不是启动即崩。
    }
    await store.reload();
    return store;
  }

  /// 技能根目录路径（`baseDir/skills`）。
  String get dir => _dirPath;

  /// 当前全部技能。返回不可变副本：调用方 sort/remove 都不会污染缓存。
  List<Skill> get all => List<Skill>.unmodifiable(_skills);

  /// 按名字查（大小写不敏感，忽略首尾空格）。
  ///
  /// 为什么要宽松：用户在聊天里说「用 code-review 技能」，
  /// 实际目录可能叫 `Code-Review`，不该因为大小写就找不到。
  Skill? byName(String name) {
    final key = _norm(name);
    if (key.isEmpty) return null;
    for (final s in _skills) {
      if (_norm(s.name) == key) return s;
    }
    return null;
  }

  /// 全部技能名，顺序与 [all] 一致。
  List<String> get names => List<String>.unmodifiable(_skills.map((s) => s.name));

  /// 重新扫描磁盘。
  ///
  /// 全量重扫而不是增量：技能数量是几十级别，全扫的 IO 成本远低于维护
  /// mtime 索引的复杂度；全扫也天然处理了「文件被外部编辑器改过」这种情况。
  Future<void> reload() async {
    final root = Directory(_dirPath);
    final found = <Skill>[];
    final files = <String, File>{};

    List<FileSystemEntity> entries;
    try {
      entries = await root.list(followLinks: false).toList();
    } on FileSystemException {
      // 目录被删掉了（比如用户清了应用数据）：当作空仓库，下次 install 会重建。
      _skills = const <Skill>[];
      _files = const <String, File>{};
      return;
    }

    // 排序后再遍历，保证同一份磁盘内容每次扫描得到同样的顺序（文件系统不保证顺序）。
    entries.sort((a, b) => a.path.compareTo(b.path));

    for (final e in entries) {
      final base = _basename(e.path);
      if (base.startsWith('.')) continue; // .git / .DS_Store 等
      try {
        if (e is Directory) {
          // 目录形式：认 SKILL.md（大小写不敏感，Android 上有从桌面拷来的 Skill.md）。
          final md = await _findSkillFile(e);
          if (md == null) continue; // 没有 SKILL.md 的目录直接忽略，不当错误
          final text = await _readText(md);
          if (text == null) continue;
          final skill = _parse(text, fallbackName: base, dirPath: e.path);
          found.add(skill);
          files.putIfAbsent(_norm(skill.name), () => md);
        } else if (e is File && base.toLowerCase().endsWith('.md')) {
          // 单文件形式：文件名（去掉 .md）作为兜底 name。
          if (base.toLowerCase() == 'skill.md') continue; // 根目录下裸的 SKILL.md 不当作技能
          final text = await _readText(e);
          if (text == null) continue;
          final skill = _parse(
            text,
            fallbackName: base.substring(0, base.length - 3),
            dirPath: _dirPath,
          );
          found.add(skill);
          files.putIfAbsent(_norm(skill.name), () => e);
        }
      } on FileSystemException {
        // 单个技能坏了不该拖垮整个仓库：跳过，其它技能照常可用。
        continue;
      }
    }

    // 重名（比如目录 `foo/` 和 `foo.md` 同时在）保留扫描顺序里的第一个，
    // 让结果稳定可预测，而不是「谁后写谁赢」。
    final dedup = <String, Skill>{};
    for (final s in found) {
      dedup.putIfAbsent(_norm(s.name), () => s);
    }

    final list = dedup.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _skills = List<Skill>.unmodifiable(list);
    _files = Map<String, File>.unmodifiable(files);
  }

  /// 安装（或覆盖）一个技能。
  ///
  /// 写入 `<skills>/<slug>/SKILL.md`，内容原样落盘 —— 不在这一层改写用户 markdown，
  /// 否则「我明明写了 A，存进去变成 B」会让人怀疑文件被篡改。
  ///
  /// 因此：如果 [markdown] 没有 frontmatter，装完之后的 name 会等于 slug
  /// （解析规则：没有 frontmatter 时 name 取父目录名）。想要中文/带空格的名字，
  /// 请在 frontmatter 里写 `name:`，slug 只决定目录。
  ///
  /// 同名覆盖前会把旧文件滚动备份成 SKILL.md.bak（见文件头注释第 3 条）。
  Future<Skill> install(String name, String markdown) async {
    final slug = _slugify(name);
    final skillDir = Directory(_join(_dirPath, slug));
    await skillDir.create(recursive: true);

    final target = File(_join(skillDir.path, 'SKILL.md'));

    // 备份：只留最近一版。File.copy 在同一文件系统上是原子的读+写，
    // 不会出现「备份只写了一半」的中间态被用户看到。
    if (await target.exists()) {
      try {
        await target.copy('${target.path}.bak');
      } on FileSystemException {
        // 备份失败（磁盘满/只读）不阻断安装：宁可丢旧版，也不能让用户装不上。
      }
    }

    // 先写临时文件再 rename：中途被杀进程也不会留下一份被截断的 SKILL.md
    // （被截断的技能 = 解析出半截 body，比重装更迷惑）。
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(markdown, encoding: utf8, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // 某些平台 rename 覆盖已存在文件会失败：退回直接写。
      await tmp.delete();
      await target.writeAsString(markdown, encoding: utf8, flush: true);
    }

    await reload();

    final installed = byName(name);
    if (installed != null) return installed;
    // 极端情况：markdown 里写了另一个 name，导致按传入的 name 查不到。
    // 直接按目录里的内容重新解析一份返回，保证返回值一定代表落盘结果。
    final text = await _readText(target);
    return _parse(text ?? markdown, fallbackName: slug, dirPath: skillDir.path);
  }

  /// 删除一个技能，返回是否真的删掉了东西。
  ///
  /// 目录形式会把空目录一起删掉（否则会留下一个空壳，用户以为没生效）；
  /// 目录里还有别的文件（模板、脚本）就保留目录，只删 SKILL.md —— 那些文件是
  /// 用户资产，不该由「删技能」顺手毁掉。
  Future<bool> remove(String name) async {
    final key = _norm(name);
    final file = _files[key];
    if (file == null) return false;
    try {
      if (await file.exists()) await file.delete();
      // 滚动备份是我们自己产生的中间物，不是用户资产，删技能时一起清掉，
      // 否则会留下 `SKILL.md.bak` 让目录看起来「还有东西」。
      final bak = File('${file.path}.bak');
      if (await bak.exists()) await bak.delete();
      final parent = file.parent;
      if (_basename(parent.path) != 'skills') {
        final rest = await parent.list().toList();
        if (rest.isEmpty) await parent.delete();
      }
    } on FileSystemException {
      return false;
    }
    await reload();
    return true;
  }

  // ── 解析 ────────────────────────────────────────────────────────────────

  /// 解析一份 SKILL.md 文本。
  ///
  /// 容错清单（都是实际会遇到的）：
  ///   - CRLF / 裸 CR：Windows、安卓剪贴板、微信转发都会带进来；
  ///   - UTF-8 BOM：Windows 记事本默认加；
  ///   - 值带引号：`name: "code review"`；
  ///   - 空值：`tags:` 后面啥都没有；
  ///   - key 前后空格、行尾空格；
  ///   - yaml 的 `- item` 块列表（顺手支持，比逗号更好读）；
  ///   - frontmatter 没闭合（用户忘了写第二个 ---）：整份当正文，绝不吞内容。
  Skill _parse(String raw, {required String fallbackName, required String dirPath}) {
    var text = raw;
    if (text.startsWith('\uFEFF')) text = text.substring(1); // 去 BOM
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'); // 统一行尾

    final lines = text.split('\n');
    var i = 0;
    // 允许文件开头有空行：有的编辑器会留下前导空行。
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }

    if (i >= lines.length || !_isFence(lines[i])) {
      // 没有 frontmatter：name 用父目录名，description 用正文第一行（去掉 # 号）。
      return Skill(
        name: fallbackName.trim().isEmpty ? 'untitled' : fallbackName.trim(),
        description: _firstLineAsDescription(text),
        body: text, // 全文原样保留，不改一个字符
        allowedTools: const <String>[],
        dir: dirPath,
        tags: const <String>[],
      );
    }

    final kv = <String, String>{};
    var j = i + 1;
    String? listKey; // 支持 `tags:` 换行后跟 `- a` 块列表
    var closed = false;

    for (; j < lines.length; j++) {
      final line = lines[j];
      if (_isFence(line)) {
        closed = true;
        break;
      }
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue; // 空行/注释跳过

      // 块列表项
      if (t == '-' || t.startsWith('- ')) {
        if (listKey != null) {
          final item = _unquote(t.length > 1 ? t.substring(1).trim() : '');
          if (item.isNotEmpty) {
            final old = kv[listKey] ?? '';
            kv[listKey] = old.isEmpty ? item : '$old, $item';
          }
        }
        continue;
      }

      final colon = t.indexOf(':');
      if (colon <= 0) {
        // 既不是 key: value 也不是列表项：坏行，跳过但保留后面的内容。
        listKey = null;
        continue;
      }
      final key = t.substring(0, colon).trim().toLowerCase();
      if (key.isEmpty) continue;
      final value = _unquote(t.substring(colon + 1).trim());
      if (value.isEmpty) {
        kv[key] = '';
        listKey = key; // 后面可能跟着块列表
      } else {
        kv[key] = value;
        listKey = null;
      }
    }

    if (!closed) {
      // frontmatter 没闭合：当整份都是正文。宁可少解析，也不要丢内容。
      return Skill(
        name: fallbackName.trim().isEmpty ? 'untitled' : fallbackName.trim(),
        description: _firstLineAsDescription(text),
        body: text,
        allowedTools: const <String>[],
        dir: dirPath,
        tags: const <String>[],
      );
    }

    // body = 结束分隔线之后的内容；去掉紧跟分隔线的那几个空行（纯粹是格式噪声）。
    var body = lines.skip(j + 1).join('\n');
    body = body.replaceFirst(RegExp(r'^\n+'), '');

    final fmName = (kv['name'] ?? '').trim();
    final fmDesc = (kv['description'] ?? '').trim();

    return Skill(
      name: fmName.isNotEmpty ? fmName : (fallbackName.trim().isEmpty ? 'untitled' : fallbackName.trim()),
      // description 缺省也退到正文第一行：列表里至少有一句人话，而不是空白行。
      description: fmDesc.isNotEmpty ? fmDesc : _firstLineAsDescription(body),
      body: body,
      allowedTools: _splitList(kv['allowed-tools'] ?? kv['allowed_tools'] ?? kv['allowedtools']),
      dir: dirPath,
      tags: _splitList(kv['tags']),
    );
  }

  /// 分隔线判定：容忍 `---   ` 这种行尾空格。
  static bool _isFence(String line) => line.trim() == '---';

  /// 去掉成对的引号。只处理最外层一对，不做转义还原 —— frontmatter 的值是展示文本，
  /// 过度处理反而会把用户真想要的 `\"` 吃掉。
  static String _unquote(String v) {
    if (v.length >= 2) {
      final first = v[0];
      final last = v[v.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return v.substring(1, v.length - 1).trim();
      }
    }
    return v;
  }

  /// 逗号分隔列表。另外兼容 `allowed-tools: bash read_file`（空格分隔）
  /// 这种 Claude Skill 习惯写法 —— 工具名不含空格，按空白再切一刀是安全的。
  static List<String> _splitList(String? raw) {
    if (raw == null) return const <String>[];
    var parts = raw
        .split(',')
        .map((e) => _unquote(e.trim()))
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.length == 1 && parts.first.contains(RegExp(r'\s'))) {
      parts = parts.first
          .split(RegExp(r'\s+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return List<String>.unmodifiable(parts);
  }

  /// 正文第一行当描述：去掉行首的 # 号和列表符号，去掉行尾空白。
  static String _firstLineAsDescription(String body) {
    for (final line in body.split('\n')) {
      var t = line.trim();
      if (t.isEmpty) continue;
      t = t.replaceFirst(RegExp(r'^#+\s*'), '');
      t = t.replaceFirst(RegExp(r'^[-*+]\s+'), '');
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  // ── 工具函数（没有 path 包，手写）────────────────────────────────────────

  /// 拼接路径。分隔符跟随 base 的写法（Windows 上收到反斜杠路径也能用），
  /// 其余情况用 `/` —— Android/Linux 上 `/` 永远合法。
  static String _join(String base, String child) {
    final sep = (!base.contains('/') && base.contains(r'\')) ? r'\' : '/';
    var b = base;
    while (b.isNotEmpty && (b.endsWith('/') || b.endsWith(r'\'))) {
      b = b.substring(0, b.length - 1);
    }
    if (b.isEmpty) return child;
    return '$b$sep$child';
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  /// 在一个目录里找 SKILL.md（大小写不敏感）。
  static Future<File?> _findSkillFile(Directory dir) async {
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      if (_basename(e.path).toLowerCase() == 'skill.md') return e;
    }
    return null;
  }

  /// 读文本。超限/坏编码时返回 null（跳过这个技能），而不是抛异常。
  static Future<String?> _readText(File f) async {
    try {
      final len = await f.length();
      if (len == 0) return null; // 空文件没有意义，别在列表里放个空技能
      if (len > _maxBytes) return null;
      // allowMalformed：非 UTF-8 字节不要炸，替换成 U+FFFD 继续用。
      return await f.readAsString(encoding: const Utf8Codec(allowMalformed: true));
    } on FileSystemException {
      return null;
    }
  }

  /// 名字归一化：大小写不敏感比较用。
  static String _norm(String s) => s.trim().toLowerCase();

  /// 目录 slug：小写 → 非 ASCII 字母数字转 `-` → 去首尾 `-` → 空则 untitled。
  ///
  /// 注意：规则是「非字母数字」，所以纯中文名会全部变成 `-`，最终落到 `untitled`。
  /// 这是为了目录名在 shell/zip/跨平台文件系统里绝对安全；需要中文名请写进
  /// frontmatter 的 `name:`，目录名用拉丁 slug。
  static String _slugify(String name) {
    var s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceFirst(RegExp(r'^-+'), '').replaceFirst(RegExp(r'-+$'), '');
    // 折叠重复的 `-`，让 `Hello   World` 变成 hello-world 而不是 hello---world。
    s = s.replaceAll(RegExp(r'-{2,}'), '-');
    if (s.isEmpty) return 'untitled';
    // 目录名长度兜底，避免某些文件系统 255 字节限制。
    if (s.length > 64) {
      s = s.substring(0, 64).replaceFirst(RegExp(r'-+$'), '');
      if (s.isEmpty) return 'untitled';
    }
    return s;
  }
}
