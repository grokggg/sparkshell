import 'dart:convert';
import 'dart:io';

/// 模型接入配置：OpenAI 兼容（DeepSeek / 通义 / Kimi / 本地 Ollama / vLLM 都能用）。
///
/// 落地在应用私有目录 `chat_config.json`（/data/data/<pkg>/files），
/// 只有本应用能读；不写进 APK、不进 git。
class ApiConfig {
  ApiConfig({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = 'deepseek-chat',
    this.systemPrompt = '你是 SparkShell 里的工程助手。回答简洁，给可执行命令。',
    this.temperature = 0.3,
  });

  String baseUrl;
  String apiKey;
  String model;
  String systemPrompt;
  double temperature;

  /// 备用接入点：轮换用，元素是 {baseUrl, apiKey, model}。
  /// 主接入点 5xx / 连不上时，自动切到下一个，并把能用的那个转正。
  final List<Map<String, String>> backups = [];

  /// 配置落盘目录，rotate() 内部要写盘，所以自己记着。
  String filesDir = '';

  int get backupCount => backups.length;

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
        baseUrl: m['baseUrl'] as String? ?? 'https://api.deepseek.com/v1',
        apiKey: m['apiKey'] as String? ?? '',
        model: m['model'] as String? ?? 'deepseek-chat',
        systemPrompt: m['systemPrompt'] as String? ?? '',
        temperature: (m['temperature'] as num?)?.toDouble() ?? 0.3,
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
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'backups': backups,
    }), flush: true);
    this.filesDir = filesDir;
    if (Platform.isAndroid) {
      await Process.run('/system/bin/chmod', ['600', f.path]);
    }
  }

  bool get ready => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;
}
