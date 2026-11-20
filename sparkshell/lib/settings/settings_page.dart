import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:sparkshell/app_version.dart';
import 'package:sparkshell/chat/api_config.dart';
import 'package:sparkshell/chat/llm_client.dart';
import 'package:sparkshell/chat/model_vault.dart';
import 'package:sparkshell/memory/memory_store.dart';
import 'package:sparkshell/plugins/gallery.dart';
import 'package:sparkshell/plugins/plugin.dart';
import 'package:sparkshell/plugins/plugin_store.dart';
import 'package:sparkshell/settings/settings_theme.dart';

/// 设置中心。
///
/// 设计上是「独立页面」而不是对话框：五个分区各自有滚动区，模型页底部常驻
/// 保存条，其它分区改了就落盘。配置读写全部走 [ApiConfig] / 插件库 / 记忆库，
/// 不碰 chat_page 的任何私有成员。
///
/// [cfgPath] 是应用 files 目录（chat_config.json、sessions/、ctx.json 都在这里）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.cfgPath,
    required this.initialTab,
    this.onChanged,
  });

  /// 应用 files 目录绝对路径。
  final String cfgPath;

  /// 0 模型 · 1 插件 · 2 记忆 · 3 上下文 · 4 高级
  final int initialTab;

  /// 任一设置变更后回调，让聊天页重新读 cfg（模型/预算/插件/记忆都会影响下一轮）。
  final VoidCallback? onChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  static const Map<String, String> _reasoningOptions = {
    'auto': '自动',
    'off': '不思考',
    'low': '低',
    'high': '高',
    'max': '极高',
  };

  static const int _minChars = 8000;
  static const int _maxCharsLimit = 120000;

  late final TabController _tab;

  /// 只构建一次，避免每次 build 都重新造主题。
  late final ThemeData _theme = settingsTheme();

  ApiConfig? _cfg;
  String? _bootError;

  // —— 模型 ——
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _vision = TextEditingController();
  final _sys = TextEditingController();

  /// 「添加模型」那一行的输入框（只在内存里，回车/点添加后清空）。
  final _newModel = TextEditingController();
  double _temp = 0.3;
  String _reasoning = 'auto';
  bool _obscure = true;
  bool _testing = false;
  PingResult? _ping;
  bool _dirty = false;
  bool _saving = false;

  // —— 插件 ——
  PluginStore? _plugins;
  String? _pluginError;
  bool _pluginsLoading = true;

  // —— 记忆 ——
  MemoryStore? _memory;
  List<MemoryFact> _facts = const <MemoryFact>[];
  String? _memoryError;
  bool _memoryLoading = true;
  final _factText = TextEditingController();
  bool _addingFact = false;

  // —— 上下文 ——
  bool _compact = true;
  int _maxChars = 24000;
  int _cacheFiles = 0;
  int _cacheBytes = 0;

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 5,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 4),
    );
    _tab.addListener(_onTabChanged);
    _boot();
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _base.dispose();
    _key.dispose();
    _model.dispose();
    _vision.dispose();
    _sys.dispose();
    _newModel.dispose();
    _factText.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  // ══════════════════════════════════════════════════════════════════
  // 读取 / 落盘
  // ══════════════════════════════════════════════════════════════════

  Future<void> _boot() async {
    try {
      final cfg = await ApiConfig.load(widget.cfgPath);
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _base.text = cfg.baseUrl;
        _key.text = cfg.apiKey;
        _model.text = cfg.model;
        _vision.text = cfg.visionModel;
        _sys.text = cfg.systemPrompt;
        _temp = cfg.temperature.clamp(0.0, 1.0);
        _reasoning = _reasoningOptions.containsKey(cfg.reasoning)
            ? cfg.reasoning
            : 'auto';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _bootError = '$e');
      return;
    }
    await _loadCtx();
    _loadPlugins();
    _loadMemory();
    _scanCache();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _saveModel() async {
    final cfg = _cfg;
    if (cfg == null || _saving) return;
    setState(() => _saving = true);
    cfg
      ..baseUrl = _base.text.trim()
      ..apiKey = _key.text.trim()
      ..model = _model.text.trim()
      ..visionModel = _vision.text.trim()
      ..reasoning = _reasoning
      ..systemPrompt = _sys.text
      ..temperature = _temp;
    cfg.rememberModel(cfg.model);
    try {
      await cfg.save(widget.cfgPath);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      widget.onChanged?.call();
      _snack('已保存');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('保存失败：$e');
    }
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _ping = null;
    });
    // 用输入框里的草稿测，不要求先保存——但也不会写进配置。
    final draft = ApiConfig(
      baseUrl: _base.text.trim(),
      apiKey: _key.text.trim(),
      model: _model.text.trim(),
      visionModel: _vision.text.trim(),
      systemPrompt: _sys.text,
      temperature: _temp,
      reasoning: _reasoning,
    );
    final client = LlmClient(draft);
    PingResult r;
    try {
      r = await client.ping();
    } catch (e) {
      r = PingResult(ok: false, message: '请求异常：$e', ms: 0);
    } finally {
      client.dispose();
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ping = r;
    });
    _snack(r.ok ? '连接正常 · ${r.ms}ms' : '连接失败：${r.message}');
  }

  // —— 上下文预算：本地 ctx.json，聊天页自己也读这个文件 ——

  File get _ctxFile => File('${widget.cfgPath}/ctx.json');

  Future<void> _loadCtx() async {
    var compact = true;
    var max = 24000;
    try {
      if (await _ctxFile.exists()) {
        final raw = jsonDecode(await _ctxFile.readAsString());
        if (raw is Map) {
          final c = raw['compactEnabled'];
          if (c is bool) compact = c;
          final m = raw['maxChars'];
          if (m is num) max = m.toInt();
        }
      }
    } catch (_) {
      // 坏文件按默认值走，设置页不能因为一个 json 挂了
    }
    if (!mounted) return;
    setState(() {
      _compact = compact;
      _maxChars = max.clamp(_minChars, _maxCharsLimit);
    });
  }

  Future<void> _saveCtx() async {
    try {
      await _ctxFile.parent.create(recursive: true);
      await _ctxFile.writeAsString(
        jsonEncode({'compactEnabled': _compact, 'maxChars': _maxChars}),
        flush: true,
      );
      widget.onChanged?.call();
    } catch (e) {
      _snack('预算没存上：$e');
    }
  }

  // —— 插件 ——

  Future<void> _loadPlugins() async {
    setState(() {
      _pluginsLoading = true;
      _pluginError = null;
    });
    try {
      final store = PluginStore(widget.cfgPath);
      await store.load();
      if (!mounted) return;
      setState(() {
        _plugins = store;
        _pluginsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pluginsLoading = false;
        _pluginError = '$e';
      });
    }
  }

  Future<void> _togglePlugin(Plugin p, bool on) async {
    final store = _plugins;
    if (store == null) return;
    try {
      await store.setEnabled(p.id, on);
      await store.save();
      if (!mounted) return;
      setState(() {});
      widget.onChanged?.call();
    } catch (e) {
      _snack('操作失败：$e');
    }
  }

  Future<void> _removePlugin(Plugin p) async {
    final store = _plugins;
    if (store == null) return;
    final ok = await _confirm(
      title: '删除插件',
      message: '「${p.name}」会从本机移除。内置仓库里还能再加回来。',
      dangerText: '删除',
    );
    if (ok != true) return;
    try {
      await store.remove(p.id);
      await store.save();
      if (!mounted) return;
      setState(() {});
      widget.onChanged?.call();
      _snack('已删除「${p.name}」');
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  Future<void> _openGallery() async {
    final store = _plugins;
    if (store == null) return;
    final installed = {for (final p in store.all) p.id};
    final candidates = builtinGallery()
        .where((p) => !installed.contains(p.id))
        .toList();
    if (candidates.isEmpty) {
      _snack('内置仓库里的插件都装上了');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Sk.card,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.72,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                    child: Row(
                      children: [
                        const Text(
                          '内置仓库',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Sk.text,
                          ),
                        ),
                        const Spacer(),
                        SkTag('${candidates.length} 个可添加'),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
                    child: Text(
                      '插件只是本地的一段说明和代码文件，装进来不会自动执行。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Sk.dim,
                        height: 1.5,
                      ),
                    ),
                  ),
                  Flexible(
                    child: candidates.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(28),
                            child: Center(
                              child: Text(
                                '都装好了',
                                style: TextStyle(color: Sk.dim, fontSize: 13),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                            itemCount: candidates.length,
                            itemBuilder: (_, i) {
                              final p = candidates[i];
                              return SkCard(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  10,
                                  10,
                                  10,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            p.name,
                                            style: const TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                              color: Sk.text,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            p.description,
                                            style: const TextStyle(
                                              fontSize: 11.5,
                                              color: Sk.dim,
                                              height: 1.45,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      height: 30,
                                      child: FilledButton(
                                        onPressed: () async {
                                          // 先抓住 Navigator：await 之后不能再碰 sheetCtx
                                          final nav = Navigator.of(sheetCtx);
                                          try {
                                            await store.install(p);
                                            await store.save();
                                            if (!mounted) return;
                                            setState(() {});
                                            widget.onChanged?.call();
                                            setSheet(
                                              () => candidates.remove(p),
                                            );
                                            _snack('已添加「${p.name}」');
                                            // 都装完了就收起来，别留个空列表
                                            if (candidates.isEmpty) {
                                              nav.maybePop();
                                            }
                                          } catch (e) {
                                            _snack('添加失败：$e');
                                          }
                                        },
                                        style: FilledButton.styleFrom(
                                          backgroundColor: Sk.primary,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          textStyle: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        child: const Text('添加'),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // —— 记忆 ——

  Future<void> _loadMemory() async {
    setState(() {
      _memoryLoading = true;
      _memoryError = null;
    });
    try {
      final store = MemoryStore(widget.cfgPath);
      await store.load();
      if (!mounted) return;
      setState(() {
        _memory = store;
        _facts = List<MemoryFact>.of(store.facts);
        _memoryLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _memoryLoading = false;
        _memoryError = '$e';
      });
    }
  }

  Future<void> _addFact() async {
    final store = _memory;
    if (store == null || _addingFact) return;
    final text = _factText.text.trim();
    if (text.isEmpty) return;
    setState(() => _addingFact = true);
    try {
      await store.add(text, tags: _parseTags(text));
      if (!mounted) return;
      setState(() {
        _facts = List<MemoryFact>.of(store.facts);
        _addingFact = false;
        _factText.clear();
      });
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _addingFact = false);
      _snack('没记住：$e');
    }
  }

  Future<void> _removeFact(MemoryFact f) async {
    final store = _memory;
    if (store == null) return;
    setState(() => _facts = _facts.where((e) => e.id != f.id).toList());
    try {
      await store.remove(f.id);
      widget.onChanged?.call();
    } catch (e) {
      _snack('删除失败：$e');
      _loadMemory();
    }
  }

  /// 文本里的 `#标签` 直接当 tag 用，省一个输入框。
  List<String> _parseTags(String text) {
    final out = <String>[];
    for (final m in RegExp(r'#([\w\u4e00-\u9fa5-]{1,16})').allMatches(text)) {
      final t = m.group(1);
      if (t != null && t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  // —— 本地缓存 ——

  Future<void> _scanCache() async {
    var files = 0;
    var bytes = 0;
    try {
      final dir = Directory('${widget.cfgPath}/sessions');
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File && e.path.endsWith('.json')) {
            files++;
            bytes += await e.length();
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _cacheFiles = files;
      _cacheBytes = bytes;
    });
  }

  Future<void> _exportConfig() async {
    try {
      final f = File('${widget.cfgPath}/chat_config.json');
      if (!await f.exists()) {
        _snack('还没保存过配置，先在上面点一次保存');
        return;
      }
      final raw = await f.readAsString();
      await Clipboard.setData(ClipboardData(text: raw));
      if (!mounted) return;
      _snack('配置已复制到剪贴板（${raw.length} 字符）');
    } catch (e) {
      _snack('导出失败：$e');
    }
  }

  Future<void> _clearSessions() async {
    final ok = await _confirm(
      title: '清空会话缓存',
      message:
          '会删除本地 sessions/ 下的全部会话（$_cacheFiles 个文件）。聊天记录删了就找不回来，模型那边也没有备份。',
      dangerText: '清空',
    );
    if (ok != true) return;
    var n = 0;
    try {
      final dir = Directory('${widget.cfgPath}/sessions');
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File) {
            await e.delete();
            n++;
          } else if (e is Directory) {
            await e.delete(recursive: true);
          }
        }
      }
      widget.onChanged?.call();
      await _scanCache();
      _snack(n == 0 ? '本来就没有会话缓存' : '已删除 $n 个会话文件');
    } catch (e) {
      _snack('清空失败：$e');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String dangerText,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Sk.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Sk.text,
          ),
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 13, color: Sk.dim, height: 1.6),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Sk.dim)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Sk.danger,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: Text(dangerText),
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 骨架
  // ══════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _theme,
      child: Scaffold(
        backgroundColor: Sk.bg,
        appBar: _buildAppBar(),
        body: _buildBody(),
        bottomNavigationBar: AnimatedBuilder(
          animation: _tab,
          builder: (_, _) =>
              _tab.index == 0 ? _buildSaveBar() : const SizedBox.shrink(),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Sk.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 0,
      leadingWidth: 44,
      leading: IconButton(
        icon: const Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 17,
          color: Sk.text,
        ),
        splashRadius: 22,
        tooltip: '返回',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '设置',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Sk.text,
              height: 1.2,
            ),
          ),
          Text(
            'SparkShell $appVersion',
            style: TextStyle(
              fontSize: 10.5,
              color: Sk.dim.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
        ],
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TabBar(
            controller: _tab,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: const EdgeInsets.symmetric(vertical: 7),
            indicator: BoxDecoration(
              color: Sk.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Sk.primary.withValues(alpha: 0.35)),
            ),
            dividerColor: Colors.transparent,
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            labelColor: const Color(0xFFD9E4FF),
            unselectedLabelColor: Sk.dim,
            labelStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
            splashBorderRadius: BorderRadius.circular(10),
            tabs: const [
              Tab(height: 34, child: _TabLabel(Icons.hub_outlined, '模型')),
              Tab(height: 34, child: _TabLabel(Icons.extension_outlined, '插件')),
              Tab(
                height: 34,
                child: _TabLabel(Icons.psychology_outlined, '记忆'),
              ),
              Tab(height: 34, child: _TabLabel(Icons.compress_rounded, '上下文')),
              Tab(height: 34, child: _TabLabel(Icons.tune_rounded, '高级')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_bootError != null) {
      return SkEmpty(
        icon: Icons.warning_amber_rounded,
        title: '配置读不出来',
        note: _bootError,
        action: FilledButton.tonal(
          onPressed: () {
            setState(() => _bootError = null);
            _boot();
          },
          child: const Text('重试'),
        ),
      );
    }
    if (_cfg == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Sk.primary),
        ),
      );
    }
    return TabBarView(
      controller: _tab,
      children: [
        _buildModelTab(),
        _buildPluginTab(),
        _buildMemoryTab(),
        _buildContextTab(),
        _buildAdvancedTab(),
      ],
    );
  }

  /// 模型页常驻底栏：改了什么一眼能看到，保存不用滚到底。
  Widget _buildSaveBar() {
    final warn = _dirty;
    return Container(
      decoration: const BoxDecoration(
        color: Sk.card,
        border: Border(top: BorderSide(color: Sk.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
          child: Row(
            children: [
              Icon(
                warn ? Icons.edit_rounded : Icons.check_circle_outline_rounded,
                size: 14,
                color: warn ? const Color(0xFFFFB020) : Sk.dim,
              ),
              const SizedBox(width: 6),
              Text(
                warn ? '有未保存的修改' : '已是最新',
                style: TextStyle(
                  fontSize: 11.5,
                  color: warn ? const Color(0xFFFFB020) : Sk.dim,
                ),
              ),
              const Spacer(),
              SizedBox(
                height: 36,
                child: FilledButton(
                  onPressed: _saving ? null : _saveModel,
                  style: FilledButton.styleFrom(
                    backgroundColor: Sk.primary,
                    disabledBackgroundColor: Sk.primary.withValues(alpha: 0.5),
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 1. 模型
  // ══════════════════════════════════════════════════════════════════

  /// 当前接入点。以「接口地址」草稿为准：用户改了地址，列表立刻切到那个接入点。
  String _endpoint() {
    final t = _base.text.trim();
    return t.isEmpty ? (_cfg?.baseUrl.trim() ?? '') : t;
  }

  /// 当前接入点下已保存的模型：固定的在前，其次按最近使用，再其次按添加时间。
  ///
  /// `forEndpoint` 会把 `baseUrl == ''` 的「通用」档一并给到（缺省任何接入点都能选），
  /// 所以这里再按 id 收一遍口：通用档和接入点档并存时只留排名靠前的那条，
  /// 否则同一个模型会出现两行（删除是全副本穿透的，少一行不影响操作）。
  List<ModelEntry> _savedModels() {
    final cfg = _cfg;
    if (cfg == null) return const <ModelEntry>[];
    final list = cfg.vault.forEndpoint(_endpoint()).toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final byUsed = b.lastUsedAt.compareTo(a.lastUsedAt);
      if (byUsed != 0) return byUsed;
      final byAdded = b.addedAt.compareTo(a.addedAt);
      if (byAdded != 0) return byAdded;
      return a.id.compareTo(b.id);
    });
    final seen = <String>{};
    return list.where((e) => seen.add(e.id)).toList();
  }

  void _onBaseChanged(String _) {
    // 地址决定「当前接入点」看到哪些模型，必须重建，不能只标脏。
    setState(() => _dirty = true);
  }

  /// 设为当前主模型：只改草稿 + 内存，列表一项不动，写盘仍走底部「保存」。
  void _useModel(ModelEntry e) {
    final cfg = _cfg;
    if (cfg == null || e.id == _model.text.trim()) return;
    setState(() {
      _model.text = e.id;
      cfg.model = e.id;
      _dirty = true;
    });
    // 带上 baseUrl 精确命中这一条（同名可能还有别的接入点 / 通用档）。
    cfg.vault.markUsed(e.id, baseUrl: e.baseUrl);
    widget.onChanged?.call();
  }

  void _togglePin(ModelEntry e) {
    final cfg = _cfg;
    if (cfg == null) return;
    // pinModel / unpinModel 内部落到 vault 并立即写盘。
    if (e.pinned) {
      cfg.unpinModel(e.id);
    } else {
      cfg.pinModel(e.id);
    }
    setState(() {});
  }

  void _deleteModel(ModelEntry e) {
    final cfg = _cfg;
    if (cfg == null) return;
    final wasCurrent = e.id == _model.text.trim();
    cfg.removeModel(e.id);
    setState(() {});
    _snack(
      wasCurrent ? '已删除「${e.id}」，当前模型仍是它，可另选一个' : '已删除「${e.id}」',
    );
  }

  /// 添加模型：**只追加，绝不覆盖**。
  ///
  /// 列表里已经有这个名字（含 `baseUrl == ''` 的「通用」档）就只把它设为当前，
  /// 不再追加一条同名副本；真没见过的才 `vault.add` 到当前接入点。
  /// 已有项一条都不动——同名同接入点走 add 也只更新 thinking，固定状态不会降级。
  Future<void> _addModel() async {
    final cfg = _cfg;
    if (cfg == null) return;
    final id = _newModel.text.trim();
    if (id.isEmpty) {
      _snack('先填模型名');
      return;
    }
    final endpoint = _endpoint();
    final known = cfg.vault.forEndpoint(endpoint).any((e) => e.id == id);
    final isNew = known ? false : cfg.vault.add(id, baseUrl: endpoint);
    // 手填 = 表态要长期用：直接固定，永不参与淘汰。
    // （用户原话「必须填上就固定住」——不钉住的话，拉取几百个模型后仍可能被挤掉。）
    if (!cfg.vault.forEndpoint(endpoint).any((e) => e.id == id && e.pinned)) {
      cfg.vault.pin(id, baseUrl: endpoint);
    }
    cfg.vault.markUsed(id);
    setState(() {
      _model.text = id; // 当前模型跟着切；列表保留，不清空
      cfg.model = id;
      _newModel.clear();
    });
    try {
      await cfg.save(widget.cfgPath);
      if (!mounted) return;
      setState(() => _dirty = _pendingEdits(cfg));
      widget.onChanged?.call();
      _snack(isNew ? '已添加「$id」并设为当前' : '「$id」已在列表，已设为当前');
    } catch (e) {
      if (!mounted) return;
      setState(() => _dirty = true);
      _snack('已加入列表，但写盘失败：$e');
    }
  }

  /// 草稿里还有没有没落盘的改动（添加模型会顺手写盘，别把别处的脏标记误清了）。
  bool _pendingEdits(ApiConfig cfg) =>
      _base.text.trim() != cfg.baseUrl.trim() ||
      _key.text.trim() != cfg.apiKey.trim() ||
      _model.text.trim() != cfg.model.trim() ||
      _vision.text.trim() != cfg.visionModel.trim() ||
      _sys.text != cfg.systemPrompt ||
      (_temp - cfg.temperature).abs() > 0.0001 ||
      _reasoning != cfg.reasoning;

  /// 看图模型：从同一份已保存列表里挑，允许留空（= 跟主模型一样）。走底部弹层，不新开页面。
  Future<void> _pickVisionModel() async {
    final cfg = _cfg;
    if (cfg == null) return;
    final models = _savedModels();
    final cur = _vision.text.trim();
    // 手填过、但不在列表里的值也要能看见并保留（用空串当「没有」的哨兵，模型名不可能是空）。
    final orphan = cur.isNotEmpty && !models.any((e) => e.id == cur) ? cur : '';
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Sk.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '看图模型',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Sk.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  '和主模型同一份列表；留空 = 跟主模型一样。纯文本模型收到图片会 400。',
                  style: TextStyle(fontSize: 11, color: Sk.dim, height: 1.5),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.5,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _VisionPickRow(
                        label: '留空 · 与主模型相同',
                        selected: cur.isEmpty,
                        onTap: () => Navigator.of(ctx).pop(''),
                      ),
                      for (final e in models)
                        _VisionPickRow(
                          label: e.id,
                          sub: e.baseUrl.trim().isEmpty ? '通用' : e.baseUrl.trim(),
                          selected: e.id == cur,
                          onTap: () => Navigator.of(ctx).pop(e.id),
                        ),
                      if (orphan.isNotEmpty)
                        _VisionPickRow(
                          label: orphan,
                          sub: '当前值（不在列表里）',
                          selected: true,
                          onTap: () => Navigator.of(ctx).pop(orphan),
                        ),
                      if (models.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            '这个接入点还没有保存的模型，先在上面「添加模型」里加一个。',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Sk.dim,
                              height: 1.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return; // null = 用户点外面取消
    setState(() {
      _vision.text = picked;
      _dirty = true;
    });
  }

  Widget _buildModelTab() {
    final cfg = _cfg!;
    final saved = _savedModels();
    // 按名字去重：通用档和接入点档可能是同一个模型的两份档案。
    final total = cfg.vault.entries.map((e) => e.id).toSet().length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
      children: [
        const SkSection('接入点'),
        SkCard(
          child: Column(
            children: [
              SkField(
                controller: _base,
                label: '接口地址',
                hint: 'https://api.qnaigc.com/v1',
                keyboardType: TextInputType.url,
                onChanged: _onBaseChanged,
              ),
              const SizedBox(height: 6),
              const Text(
                '换接入点不会丢掉别的接入点下已保存的模型；下面列的是当前这个接入点的模型。',
                style: TextStyle(fontSize: 11, color: Sk.dim, height: 1.5),
              ),
              const SizedBox(height: 14),
              SkField(
                controller: _key,
                label: 'API Key',
                hint: 'sk-…（只存在本机）',
                obscure: _obscure,
                onChanged: (_) => _markDirty(),
                suffix: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  splashRadius: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 38,
                    minHeight: 34,
                  ),
                  tooltip: _obscure ? '显示' : '隐藏',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 17,
                    color: Sk.dim,
                  ),
                ),
              ),
            ],
          ),
        ),
        SkSection(
          '模型',
          trailing: Text(
            saved.isEmpty ? '还没有保存的模型' : '${saved.length} 个',
            style: const TextStyle(fontSize: 11, color: Sk.dim),
          ),
        ),
        SkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 当前主模型 = 列表里打勾的那一项；换它只改草稿，底部「保存」才写盘。
              Row(
                children: [
                  const Text(
                    '当前主模型',
                    style: TextStyle(fontSize: 12, color: Sk.dim),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      _model.text.trim().isEmpty ? '未设置' : _model.text.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Sk.primary,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 18, color: Sk.line),
              if (saved.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '这个接入点下还没有保存的模型，在下面添加一个。',
                    style: TextStyle(fontSize: 11.5, color: Sk.dim, height: 1.5),
                  ),
                )
              else
                for (var i = 0; i < saved.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: Sk.line),
                  _ModelRow(
                    entry: saved[i],
                    current: saved[i].id == _model.text.trim(),
                    thinking: cfg.supportsThinking(saved[i].id),
                    onUse: () => _useModel(saved[i]),
                    onPin: () => _togglePin(saved[i]),
                    onDelete: () => _deleteModel(saved[i]),
                  ),
                ],
              const Divider(height: 18, color: Sk.line),
              // 添加：只追加。vault.add 按 id 去重，已有项一项都不会被顶掉。
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newModel,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addModel(),
                      cursorColor: Sk.primary,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Sk.text,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '新模型名，如 qwen-vl-max',
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: Sk.dim.withValues(alpha: 0.55),
                        ),
                        filled: true,
                        fillColor: Sk.bg.withValues(alpha: 0.55),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 11,
                        ),
                        border: _inputBorder(Sk.line),
                        enabledBorder: _inputBorder(Sk.line),
                        focusedBorder: _inputBorder(Sk.primary, width: 1.4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 40,
                    child: FilledButton(
                      onPressed: _addModel,
                      style: FilledButton.styleFrom(
                        backgroundColor: Sk.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('添加'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                total > saved.length
                    ? '添加是追加，不会覆盖已有项，加完自动设为当前。另有 ${total - saved.length} 个模型在别的接入点下，换接口地址即可看到。'
                    : '添加是追加，不会覆盖已有项，加完自动设为当前。固定的模型一直排在列表最前。',
                style: const TextStyle(fontSize: 11, color: Sk.dim, height: 1.5),
              ),
            ],
          ),
        ),
        const SkSection('看图模型'),
        SkCard(
          padding: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(Sk.radius),
            onTap: _pickVisionModel,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _vision.text.trim().isEmpty
                              ? '与主模型相同（留空）'
                              : _vision.text.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontFamily: 'monospace',
                            color: _vision.text.trim().isEmpty
                                ? Sk.dim
                                : Sk.text,
                          ),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          '纯文本模型收到图片会 400；配一个能读图的模型，只有带图那轮才切过去。',
                          style: TextStyle(
                            fontSize: 11,
                            color: Sk.dim,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.expand_more, size: 18, color: Sk.dim),
                ],
              ),
            ),
          ),
        ),
        const SkSection('生成参数'),
        SkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '温度',
                    style: TextStyle(
                      fontSize: 13,
                      color: Sk.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _temp.toStringAsFixed(1),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Sk.primary,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text(
                    '稳',
                    style: TextStyle(fontSize: 10.5, color: Sk.dim),
                  ),
                  Expanded(
                    child: Slider(
                      value: _temp,
                      min: 0,
                      max: 1,
                      divisions: 10,
                      label: _temp.toStringAsFixed(1),
                      onChanged: (v) => setState(() {
                        _temp = v;
                        _markDirty();
                      }),
                    ),
                  ),
                  const Text(
                    '活',
                    style: TextStyle(fontSize: 10.5, color: Sk.dim),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Divider(height: 18, color: Sk.line),
              const Text(
                '思考深度',
                style: TextStyle(
                  fontSize: 13,
                  color: Sk.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _reasoningOptions.entries)
                    ChoiceChip(
                      label: Text(
                        e.value,
                        style: TextStyle(
                          fontSize: 12,
                          color: _reasoning == e.key
                              ? const Color(0xFFD9E4FF)
                              : Sk.dim,
                        ),
                      ),
                      selected: _reasoning == e.key,
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _reasoning = e.key;
                        _markDirty();
                      }),
                      selectedColor: Sk.primary.withValues(alpha: 0.18),
                      backgroundColor: Sk.bg.withValues(alpha: 0.55),
                      side: BorderSide(
                        color: _reasoning == e.key
                            ? Sk.primary.withValues(alpha: 0.45)
                            : Sk.line,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '「不思考」最快，查环境时少绕弯；复杂改造用「高 / 极高」。自动 = 不额外下发参数。',
                style: TextStyle(fontSize: 11, color: Sk.dim, height: 1.5),
              ),
            ],
          ),
        ),
        const SkSection('系统提示'),
        SkCard(
          child: SkField(
            controller: _sys,
            label: '角色设定',
            hint: '留空则用默认提示',
            maxLines: 3,
            minLines: 2,
            onChanged: (_) => _markDirty(),
          ),
        ),
        const SkSection('连通性'),
        SkCard(
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '测试连接',
                          style: TextStyle(
                            fontSize: 13,
                            color: Sk.text,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '用上面填写的内容发一次极短请求',
                          style: TextStyle(fontSize: 11, color: Sk.dim),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 34,
                    child: OutlinedButton(
                      onPressed: _testing ? null : _test,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Sk.primary,
                        side: BorderSide(
                          color: Sk.primary.withValues(alpha: 0.45),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: _testing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Sk.primary,
                              ),
                            )
                          : const Text('测试'),
                    ),
                  ),
                ],
              ),
              if (_ping != null) ...[
                const SizedBox(height: 12),
                _PingBanner(ping: _ping!),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 2. 插件
  // ══════════════════════════════════════════════════════════════════

  Widget _buildPluginTab() {
    final store = _plugins;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  store == null ? '插件' : '已安装 ${store.all.length} 个',
                  style: const TextStyle(fontSize: 12, color: Sk.dim),
                ),
              ),
              _GhostButton(
                icon: Icons.add_rounded,
                label: '从内置仓库添加',
                onTap: store == null || _pluginsLoading ? null : _openGallery,
              ),
            ],
          ),
        ),
        Expanded(child: _buildPluginList()),
      ],
    );
  }

  Widget _buildPluginList() {
    if (_pluginsLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Sk.primary),
        ),
      );
    }
    final err = _pluginError;
    if (err != null) {
      return SkEmpty(
        icon: Icons.extension_off_outlined,
        title: '插件库读不出来',
        note: err,
        action: FilledButton.tonal(
          onPressed: _loadPlugins,
          child: const Text('重试'),
        ),
      );
    }
    final store = _plugins;
    final all = store?.all ?? const <Plugin>[];
    if (all.isEmpty) {
      return SkEmpty(
        icon: Icons.extension_outlined,
        title: '还没有插件',
        note: '从内置仓库挑一个开始。插件只是本地文件，页面不会执行它。',
        action: FilledButton.tonal(
          onPressed: _openGallery,
          child: const Text('从内置仓库添加'),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
      itemCount: all.length,
      itemBuilder: (_, i) => _pluginCard(all[i]),
    );
  }

  Widget _pluginCard(Plugin p) {
    final on = p.enabled;
    final desc = p.description.trim();
    return SkCard(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Sk.primary.withValues(alpha: on ? 0.15 : 0.06),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.extension_rounded,
                  size: 17,
                  color: on ? Sk.primary : Sk.dim.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: on ? Sk.text : Sk.dim,
                  ),
                ),
              ),
              _MiniSwitch(value: on, onChanged: (v) => _togglePlugin(p, v)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 42),
              Expanded(
                child: Text(
                  desc.isEmpty ? '暂无说明' : desc,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Sk.dim,
                    height: 1.5,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                tooltip: '更多',
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 18,
                  color: Sk.dim.withValues(alpha: 0.8),
                ),
                color: const Color(0xFF1C2534),
                surfaceTintColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                onSelected: (v) {
                  if (v == 'delete') _removePlugin(p);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'delete',
                    height: 40,
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          size: 16,
                          color: Sk.danger,
                        ),
                        SizedBox(width: 8),
                        Text(
                          '删除',
                          style: TextStyle(fontSize: 13, color: Sk.danger),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 3. 记忆
  // ══════════════════════════════════════════════════════════════════

  Widget _buildMemoryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(
            children: [
              Text(
                _memoryLoading ? '记忆' : '${_facts.length} 条记忆',
                style: const TextStyle(fontSize: 12, color: Sk.dim),
              ),
              const Spacer(),
              if (_facts.isNotEmpty) const SkTag('每轮自动带上'),
            ],
          ),
        ),
        Expanded(child: _buildMemoryList()),
        _buildMemoryInput(),
      ],
    );
  }

  Widget _buildMemoryList() {
    if (_memoryLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Sk.primary),
        ),
      );
    }
    final err = _memoryError;
    if (err != null) {
      return SkEmpty(
        icon: Icons.psychology_alt_outlined,
        title: '记忆库读不出来',
        note: err,
        action: FilledButton.tonal(
          onPressed: _loadMemory,
          child: const Text('重试'),
        ),
      );
    }
    if (_facts.isEmpty) {
      return const SkEmpty(
        icon: Icons.psychology_outlined,
        title: '还没记住任何事',
        note: '你的偏好、项目路径、常用命令都可以记在这里，之后每次对话会自动带上。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      itemCount: _facts.length,
      itemBuilder: (_, i) {
        final f = _facts[i];
        return Dismissible(
          key: ValueKey<String>(f.id),
          direction: DismissDirection.endToStart,
          background: Container(
            margin: const EdgeInsets.only(bottom: 8),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 18),
            decoration: BoxDecoration(
              color: Sk.danger.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(Sk.radius),
              border: Border.all(color: Sk.danger.withValues(alpha: 0.25)),
            ),
            child: const Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: Sk.danger,
            ),
          ),
          onDismissed: (_) => _removeFact(f),
          child: SkCard(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (f.tags.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final t in f.tags) SkTag('#$t', color: Sk.primary),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  f.text,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Sk.text,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _when(f.at),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Sk.dim.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMemoryInput() {
    return Container(
      decoration: const BoxDecoration(
        color: Sk.bg,
        border: Border(top: BorderSide(color: Sk.line)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Sk.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Sk.line),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  controller: _factText,
                  minLines: 1,
                  maxLines: 4,
                  cursorColor: Sk.primary,
                  style: const TextStyle(fontSize: 13, color: Sk.text),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '记一条偏好或事实，可写 #标签',
                    hintStyle: TextStyle(
                      fontSize: 12.5,
                      color: Sk.dim.withValues(alpha: 0.6),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              height: 44,
              child: FilledButton(
                onPressed: _addingFact ? null : _addFact,
                style: FilledButton.styleFrom(
                  backgroundColor: Sk.primary,
                  disabledBackgroundColor: Sk.primary.withValues(alpha: 0.4),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _addingFact
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.arrow_upward_rounded,
                        size: 19,
                        color: Colors.white,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 4. 上下文
  // ══════════════════════════════════════════════════════════════════

  Widget _buildContextTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
      children: [
        SkCard(
          color: Sk.primary.withValues(alpha: 0.08),
          borderColor: Sk.primary.withValues(alpha: 0.22),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: Sk.primary),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '模型的上下文窗口由服务商决定，这里改不了。这里控制的是「每次发多少」：'
                  '超预算就压缩早期消息，把最近的对话留给模型。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFFC6D2E4),
                    height: 1.65,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SkSection('压缩策略'),
        SkCard(
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '超预算时压缩早期消息',
                      style: TextStyle(
                        fontSize: 13,
                        color: Sk.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '关掉后只做截断，早期内容直接丢，不生成摘要',
                      style: TextStyle(
                        fontSize: 11,
                        color: Sk.dim,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _MiniSwitch(
                value: _compact,
                onChanged: (v) {
                  setState(() => _compact = v);
                  _saveCtx();
                },
              ),
            ],
          ),
        ),
        const SkSection('每次发送上限'),
        SkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _fmtInt(_maxChars),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Sk.text,
                      fontFamily: 'monospace',
                      height: 1.1,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 3, left: 4),
                    child: Text(
                      '字',
                      style: TextStyle(fontSize: 11, color: Sk.dim),
                    ),
                  ),
                  const Spacer(),
                  SkTag('约 ${(_maxChars / 1600).toStringAsFixed(1)}k tokens'),
                ],
              ),
              Slider(
                value: _maxChars.toDouble(),
                min: _minChars.toDouble(),
                max: _maxCharsLimit.toDouble(),
                divisions: (_maxCharsLimit - _minChars) ~/ 2000,
                label: '${(_maxChars / 1000).round()}k',
                onChanged: (v) => setState(() => _maxChars = v.round()),
                onChangeEnd: (v) {
                  setState(() => _maxChars = v.round());
                  _saveCtx();
                },
              ),
              const Row(
                children: [
                  Text('8k', style: TextStyle(fontSize: 10.5, color: Sk.dim)),
                  Spacer(),
                  Text('120k', style: TextStyle(fontSize: 10.5, color: Sk.dim)),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '按字数算，不是按 token。设太大可能超出而报 400，设太小会丢上下文——'
                '手机上一轮长对话建议 24k – 48k。',
                style: TextStyle(fontSize: 11, color: Sk.dim, height: 1.5),
              ),
            ],
          ),
        ),
        const SkSection('本地缓存'),
        SkCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _cacheFiles == 0 ? '还没有本地会话' : '$_cacheFiles 个会话文件',
                      style: const TextStyle(fontSize: 13, color: Sk.text),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _cacheFiles == 0
                          ? '存在 ${widget.cfgPath}/sessions'
                          : '${_fmtBytes(_cacheBytes)} · 存在 sessions/',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Sk.dim,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _scanCache,
                splashRadius: 18,
                tooltip: '刷新',
                icon: Icon(Icons.refresh_rounded, size: 18, color: Sk.dim),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 5. 高级
  // ══════════════════════════════════════════════════════════════════

  Widget _buildAdvancedTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
      children: [
        SkCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Sk.primary, Color(0xFF6A4BFF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Center(
                  child: Text(
                    'S',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SparkShell',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Sk.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '版本 $appVersion · build $appCode',
                      style: const TextStyle(fontSize: 11.5, color: Sk.dim),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SkSection('配置'),
        _actionCard(
          icon: Icons.content_copy_rounded,
          title: '导出配置',
          note: '把 chat_config.json 的原文复制到剪贴板',
          onTap: _exportConfig,
        ),
        _actionCard(
          icon: Icons.delete_sweep_outlined,
          title: '清空会话缓存',
          note: '删除本地 sessions/ 下的 $_cacheFiles 个会话文件',
          onTap: _clearSessions,
          danger: true,
        ),
        const SkSection('关于'),
        const SkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SparkShell 是一个把 Linux 终端、SSH、文件管理和 AI 助手装进同一部手机的工具。'
                '模型接口走 OpenAI 兼容协议，配置和会话只落在应用私有目录，不经过任何中转服务器。',
                style: TextStyle(fontSize: 12, color: Sk.dim, height: 1.7),
              ),
              SizedBox(height: 12),
              Divider(height: 1, color: Sk.line),
              SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.lock_outline_rounded, size: 13, color: Sk.dim),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'API Key 以 600 权限保存在本机，导出配置时请自行注意脱敏。',
                      style: TextStyle(
                        fontSize: 11,
                        color: Sk.dim,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actionCard({
    required IconData icon,
    required String title,
    required String note,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final tint = danger ? Sk.danger : Sk.primary;
    return SkCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(Sk.radius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 17, color: tint),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: danger ? Sk.danger : Sk.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        note,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Sk.dim,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Sk.dim.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// 小部件
// ══════════════════════════════════════════════════════════════════════

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 14), const SizedBox(width: 5), Text(text)],
    );
  }
}

class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? Sk.primary
            : const Color(0xFF2A3547),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 模型列表的一行：模型名（+ 接入点 / 思考标记，单行省略）+ 固定 / 设为当前 / 删除。
///
/// 整行可点 = 设为当前；点当前行不响应，避免无意义的 setState。
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.entry,
    required this.current,
    required this.thinking,
    required this.onUse,
    required this.onPin,
    required this.onDelete,
  });

  final ModelEntry entry;
  final bool current;
  final bool thinking;
  final VoidCallback onUse;
  final VoidCallback onPin;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ep = entry.baseUrl.trim().isEmpty ? '通用' : entry.baseUrl.trim();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: current ? null : onUse,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 3, 0, 3),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: entry.id,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                          color: current ? Sk.text : Sk.dim,
                          fontWeight: current
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      TextSpan(
                        text: '  ·  $ep',
                        style: const TextStyle(fontSize: 10.5, color: Sk.dim),
                      ),
                      if (thinking)
                        const TextSpan(
                          text: '  ·  思考',
                          style: TextStyle(fontSize: 10.5, color: Sk.dim),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _RowIcon(
                icon: entry.pinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                color: entry.pinned ? Sk.primary : Sk.dim,
                tooltip: entry.pinned ? '取消固定' : '固定到最前',
                onTap: onPin,
              ),
              _RowIcon(
                icon: current
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                color: current ? Sk.primary : Sk.dim,
                tooltip: current ? '当前模型' : '设为当前',
                onTap: current ? null : onUse,
              ),
              _RowIcon(
                icon: Icons.delete_outline_rounded,
                color: Sk.danger,
                tooltip: '从列表删除',
                onTap: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表行右侧的小图标动作（比默认 IconButton 窄，三个并排放得下）。
class _RowIcon extends StatelessWidget {
  const _RowIcon({
    required this.icon,
    required this.color,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      splashRadius: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(icon, size: 17, color: color),
    );
  }
}

/// 看图模型弹层里的一行：单选圈 + 模型名（+ 来源接入点），单行省略。
class _VisionPickRow extends StatelessWidget {
  const _VisionPickRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.sub,
  });

  final String label;
  final String? sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = sub?.trim() ?? '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                size: 15,
                color: selected ? Sk.primary : Sk.dim,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                          color: selected ? Sk.text : Sk.dim,
                        ),
                      ),
                      if (s.isNotEmpty)
                        TextSpan(
                          text: '  ·  $s',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Sk.dim,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: on ? Sk.primary.withValues(alpha: 0.12) : Sk.card,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: on ? Sk.primary.withValues(alpha: 0.35) : Sk.line,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: on ? Sk.primary : Sk.dim),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: on ? Sk.primary : Sk.dim,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PingBanner extends StatelessWidget {
  const _PingBanner({required this.ping});

  final PingResult ping;

  @override
  Widget build(BuildContext context) {
    final ok = ping.ok;
    final c = ok ? Sk.ok : Sk.danger;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            size: 15,
            color: c,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '${ping.message}${ping.ms > 0 ? ' · ${ping.ms}ms' : ''}',
              style: TextStyle(fontSize: 12, color: c, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// 纯函数
// ══════════════════════════════════════════════════════════════════════

/// 输入框描边（跟 SkField 内部那套保持一致，添加行是裸 TextField 所以自己拼）。
OutlineInputBorder _inputBorder(Color c, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(Sk.fieldRadius),
      borderSide: BorderSide(color: c, width: width),
    );

/// 千分位，滑杆上方那个大数字要用。
String _fmtInt(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// MemoryFact.at 可能是 DateTime，也可能是 ISO 字符串，两种都吃得下。
String _when(Object? at) {
  DateTime? d;
  if (at is DateTime) {
    d = at;
  } else if (at != null) {
    d = DateTime.tryParse('$at');
  }
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.isNegative) return '刚刚';
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}
