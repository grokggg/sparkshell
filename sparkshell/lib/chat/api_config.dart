import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'model_vault.dart';

/// 模型接入配置：OpenAI 兼容（DeepSeek / 通义 / Kimi / 本地 Ollama / vLLM 都能用）。
///
/// 落地在应用私有目录 `chat_config.json`（/data/data/<pkg>/files），
/// 只有本应用能读；不写进 APK、不进 git。
class ApiConfig {
  ApiConfig({
    this.baseUrl = 'https://api.qnaigc.com/v1',
    this.apiKey = '',
    this.model = 'qiniu/conatus-free',
    this.visionModel = '',
    this.systemPrompt = '你是 SparkShell 里的工程助手。回答简洁，给可执行命令。',
    this.temperature = 0.3,
    this.reasoning = 'auto',
  });

  String baseUrl;
  String apiKey;
  String model;

  /// 看图专用模型。留空 = 和主模型一样。
  ///
  /// 免费接入点（如 conatus-free）多是纯文本，图片塞进去会 400 或降级；
  /// 填一个真能读图的模型（qwen-vl / gpt-4o-mini 之类），只有带图那轮才切过去，
  /// 省额度，也不影响平时干活。
  String visionModel;

  String systemPrompt;
  double temperature;

  /// 思考深度：auto | off | low | high | max。
  ///
  /// DeepSeek 这类模型把这个当硬开关（不思考 = 直接出结果，快但浅），
  /// 对 agent 场景差别很大：查环境时「不思考」少绕弯路，复杂改造要「高」。
  /// auto 不带任何参数，行为与 3.4.0 完全一致。
  String reasoning = 'auto';

  /// 拼进请求体的思考参数；auto 返回空。
  ///
  /// 同时给 `thinking` 与 `reasoning_effort` 两套写法：前者是 DeepSeek/通义
  /// 的原生字段，后者是 OpenAI 兼容层的通用字段。多余的字段多数网关会忽略，
  /// 遇到严格校验的接入点会在「测试连接」里暴露出来。
  Map<String, dynamic> reasoningPayload() {
    switch (reasoning) {
      case 'off':
        return {'thinking': {'type': 'disabled'}, 'reasoning_effort': 'none'};
      case 'low':
      case 'high':
      case 'max':
        return {'reasoning_effort': reasoning};
      default:
        return const {};
    }
  }

  /// 模型档案库：固定项永不淘汰，按接入点分组记忆。
  /// 这是唯一的真源；下面的 [models]、[thinkingSupport] 只作旧版兼容镜像。
  final ModelVault vault = ModelVault();

  /// **旧版兼容字段**：曾经是「最近用过 / 拉到过」的滚动列表。
  /// 现在由 [vault] 派生（最近用过的名字，最多 80 条），只为老版本读得懂。
  final List<String> models = [];

  /// 用户手动标注过「这个模型到底吃不吃思考参数」。
  /// 名字猜不准的（比如 `qiniu/conatus-free`）由这里兜底，true=显示思考档位。
  /// 落盘时同步进 vault，读的时候 vault 优先。
  final Map<String, bool> thinkingSupport = {};

  /// 名字里带这些的，基本都吃 `reasoning_effort` / `thinking`。
  /// 规则本体搬去 [ModelVault.looksThinking]（vault 不能依赖配置类），这里只转发。
  static bool looksThinking(String id) => ModelVault.looksThinking(id);

  bool supportsThinking(String id) =>
      vault.thinkingOf(id) ?? thinkingSupport[id.trim()] ?? looksThinking(id);

  /// 记住一个模型名（只改内存，落盘由调用方决定）。
  ///
  /// 语义从「滚动列表」换成「留档」：不固定、归属当前接入点、
  /// 超出上限只淘汰未固定且最久未用的，用户固定过的一条都不动。
  void rememberModel(String id) {
    final m = id.trim();
    if (m.isEmpty) return;
    vault.add(m, baseUrl: baseUrl);
    vault.markUsed(m, baseUrl: baseUrl); // 刚用过的排最前，别按建档时间排
    _syncLegacyModels();
  }

  /// 选择器该显示什么：本接入点 + 通用项，当前模型保证在列。
  List<String> get selectableModels =>
      vault.chooseList(baseUrl: baseUrl, current: model);

  /// 固定 / 取消固定 / 删除都在「模型名」这一层生效，穿透到该名字的所有归档副本。
  ///
  /// 为什么不是只改当前接入点那份：升级迁移来的通用档（''）和后来从接入点拉到的
  /// 同名档，在用户眼里就是同一个模型；只改一份的话，UI 读到的往往正是另一份，
  /// 表现为「点了固定没反应」。
  void pinModel(String id) {
    if (!_eachCopy(id, (e) => e.pinned = true)) {
      vault.pin(id, baseUrl: baseUrl); // 一条都没有：按当前接入点建档
    }
    _afterVaultChange();
  }

  void unpinModel(String id) {
    _eachCopy(id, (e) => e.pinned = false);
    _afterVaultChange();
  }

  void removeModel(String id) {
    final name = id.trim();
    for (final e in vault.entries) {
      if (e.id == name) vault.remove(e.id, baseUrl: e.baseUrl);
    }
    _afterVaultChange();
  }

  /// 对同名条目逐个执行，返回是否至少命中一条。
  bool _eachCopy(String id, void Function(ModelEntry e) f) {
    final name = id.trim();
    var hit = false;
    for (final e in vault.entries) {
      if (e.id == name) {
        f(e);
        hit = true;
      }
    }
    return hit;
  }

  void _afterVaultChange() {
    _syncLegacyModels();
    final dir = filesDir;
    if (dir.isEmpty) return; // 还没 load 过，等下次 save
    unawaited(save(dir).catchError((Object _) {}));
  }

  /// 把 vault 里最近用过的名字回写到旧 `models` 字段（最多 80）。
  ///
  /// 只做并集、不做重建：老代码和老配置会直接往 models 里 add，
  /// 先把这些名字收进档案库再按「固定 + 最近使用」排序，一个都不丢。
  /// 不往这里塞当前模型 —— 旧版本另有 model 字段，塞进来只会污染历史列表
  /// （曾经把 reasoning_retry_test 的 ['a','b'] 顶成 ['qiniu/conatus-free','a']）。
  void _syncLegacyModels() {
    for (final n in List<String>.from(models)) {
      final v = n.trim();
      if (v.isEmpty) continue;
      if (vault.entries.every((e) => e.id != v)) vault.add(v);
    }
    models
      ..clear()
      ..addAll(vault.recentNames(limit: 80));
  }

  /// 备用接入点：轮换用，元素是 {baseUrl, apiKey, model}。
  /// 主接入点 5xx / 连不上时，自动切到下一个，并把能用的那个转正。
  final List<Map<String, String>> backups = [];

  /// 配置落盘目录，rotate() 内部要写盘，所以自己记着。
  String filesDir = '';

  int get backupCount => backups.length;

  /// 这一轮该用哪个模型：带图且配了看图模型才切。
  String modelFor({bool hasImages = false}) =>
      hasImages && visionModel.trim().isNotEmpty ? visionModel.trim() : model;

  /// 切到下一个备用接入点；把当前这个挪到队尾，形成环形轮换。
  Future<bool> rotate() async {
    if (backups.isEmpty) return false;
    final cur = {'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};
    final next = backups.removeAt(0);
    backups.add(cur);
    baseUrl = next['baseUrl'] ?? baseUrl;
    apiKey = next['apiKey'] ?? apiKey;
    model = next['model'] ?? model;
    if (filesDir.isNotEmpty) {
      try {
        await save(filesDir);
      } catch (_) {}
    }
    return true;
  }

  static File _file(String filesDir) => File('$filesDir/chat_config.json');

  static Future<ApiConfig> load(String filesDir) async {
    try {
      final f = _file(filesDir);
      if (!await f.exists()) return ApiConfig();
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final cfg = ApiConfig(
        baseUrl: m['baseUrl'] as String? ?? 'https://api.qnaigc.com/v1',
        apiKey: m['apiKey'] as String? ?? '',
        model: m['model'] as String? ?? 'qiniu/conatus-free',
        visionModel: m['visionModel'] as String? ?? '',
        systemPrompt: m['systemPrompt'] as String? ?? '',
        temperature: (m['temperature'] as num?)?.toDouble() ?? 0.3,
        reasoning: m['reasoning'] as String? ?? 'auto',
      );
      cfg.filesDir = filesDir;
      final vs = m['vault'];
      if (vs is Map) {
        final v = ModelVault.fromJson(vs);
        cfg.vault.restore(v.entries, maxUnpinned: v.maxUnpinned);
        // vault 与旧 models 可能不同步（比如手工改过文件），缺的补进来
        final ms = m['models'];
        if (ms is List) {
          for (final e in ms) {
            final v = '$e'.trim();
            if (v.isEmpty) continue;
            if (cfg.vault.entries.every((x) => x.id != v)) cfg.vault.add(v);
          }
        }
      } else {
        // 老配置升级：旧的 models 全是「拉到手」的，先按不固定灌进档案库；
        // 当前模型单独固定 —— 否则升级后第一次拉取就可能把用户手填的冲没。
        final ms = m['models'];
        if (ms is List) {
          for (final e in ms) {
            final v = '$e'.trim();
            if (v.isNotEmpty) cfg.vault.add(v);
          }
        }
        cfg.vault.pin(cfg.model);
      }
      final ts = m['thinking'];
      if (ts is Map) {
        ts.forEach((k, v) {
          if (v is bool) {
            cfg.thinkingSupport['$k'] = v;
            cfg.vault.annotate('$k', v); // 标注落到档案库，别只留在旧字段里
          }
        });
      }
      cfg._syncLegacyModels();
      final bs = m['backups'];
      if (bs is List) {
        for (final e in bs) {
          if (e is Map) {
            cfg.backups.add({
              'baseUrl': '${e['baseUrl'] ?? ''}',
              'apiKey': '${e['apiKey'] ?? ''}',
              'model': '${e['model'] ?? ''}',
            });
          }
        }
      }
      return cfg;
    } catch (_) {
      return ApiConfig();
    }
  }

  Future<void> save(String filesDir) async {
    final f = _file(filesDir);
    // 旧字段 thinking 里可能刚被 UI 直接改过（chat_page 就是直接写 map），
    // 落盘前并进 vault，保证档案库不落后。
    thinkingSupport.forEach(vault.annotate);
    _syncLegacyModels();
    await f.writeAsString(jsonEncode({
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'model': model,
      'visionModel': visionModel,
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'reasoning': reasoning,
      'vault': vault.toJson(),
      // 旧版本只认这个数组：保持「最近用过的名字」，别让回滚丢档
      'models': models,
      'thinking': thinkingSupport,
      'backups': backups,
    }), flush: true);
    this.filesDir = filesDir;
    if (Platform.isAndroid) {
      await Process.run('/system/bin/chmod', ['600', f.path]);
    }
  }

  bool get ready => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;
}
