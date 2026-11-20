import 'dart:convert';
import 'dart:io';

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
    await f.writeAsString(jsonEncode({
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'model': model,
      'visionModel': visionModel,
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'reasoning': reasoning,
      'backups': backups,
    }), flush: true);
    this.filesDir = filesDir;
    if (Platform.isAndroid) {
      await Process.run('/system/bin/chmod', ['600', f.path]);
    }
  }

  bool get ready => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;
}
