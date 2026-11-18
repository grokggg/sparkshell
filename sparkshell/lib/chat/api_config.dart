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

  static File _file(String filesDir) => File('$filesDir/chat_config.json');

  static Future<ApiConfig> load(String filesDir) async {
    try {
      final f = _file(filesDir);
      if (!await f.exists()) return ApiConfig();
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return ApiConfig(
        baseUrl: m['baseUrl'] as String? ?? 'https://api.deepseek.com/v1',
        apiKey: m['apiKey'] as String? ?? '',
        model: m['model'] as String? ?? 'deepseek-chat',
        systemPrompt: m['systemPrompt'] as String? ?? '',
        temperature: (m['temperature'] as num?)?.toDouble() ?? 0.3,
      );
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
    }), flush: true);
    if (Platform.isAndroid) {
      await Process.run('/system/bin/chmod', ['600', f.path]);
    }
  }

  bool get ready => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;
}
