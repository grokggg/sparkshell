/// 一个「接入点」= 一套 baseUrl + apiKey（+ 它上次用的模型）。
///
/// 为什么单独建模：3.8.3 只有一个 baseUrl/apiKey 字段，用户填第二个 key 时
/// 整份配置被覆盖成新的，旧 key 的模型虽然还躺在 [ModelVault] 里（按 baseUrl 归属），
/// 但界面只按「当前 baseUrl」过滤，看起来就是「没了」。
/// 用户原话：「我就一个七牛云 key……我另一个 key 的模型就没了，不能这样。」
/// 所以接入点必须是**一份清单**，每个 key 一行，各自带自己的模型档案。
class ApiEndpoint {
  ApiEndpoint({
    required this.id,
    this.name = '',
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
    this.lastUsedAt = 0,
  });

  /// 稳定标识：规范化后的 baseUrl。模型档案库（ModelVault）也用它做分组键，
  /// 两边必须用同一个字符串，否则「切换接入点」后模型会认不回来。
  final String id;

  /// 用户起的名字（「七牛云」「DeepSeek 官方」…）。空则回落到域名。
  String name;

  String baseUrl;
  String apiKey;

  /// 这个接入点上次用的模型；切回来时跟着恢复。
  String model;

  int lastUsedAt;

  /// 展示名：优先用用户起的名字，否则用域名（同域名不同路径时补上路径尾段）。
  String get label {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    final u = Uri.tryParse(baseUrl.trim());
    if (u == null || u.host.isEmpty) {
      return baseUrl.trim().isEmpty ? '未填地址' : baseUrl.trim();
    }
    var host = u.host;
    if (host.startsWith('www.')) host = host.substring(4);
    final p = u.path.replaceAll(RegExp(r'/+$'), '');
    if (p.isEmpty || p == '/' || p == '/v1') return host;
    final seg = p.split('/').where((s) => s.isNotEmpty).toList();
    return seg.isEmpty ? host : '$host/${seg.last}';
  }

  /// 地址规范化：去掉首尾空白与结尾斜杠。
  /// 只在比较/建档时用，发请求仍走 [baseUrl] 原文（有些网关对结尾斜杠敏感）。
  static String normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  bool get ready => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  ApiEndpoint copyWith({String? name, String? baseUrl, String? apiKey, String? model, int? lastUsedAt}) =>
      ApiEndpoint(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'lastUsedAt': lastUsedAt,
      };

  static ApiEndpoint fromJson(Map<String, dynamic> m) {
    final base = '${m['baseUrl'] ?? ''}';
    final id = '${m['id'] ?? ''}'.trim();
    return ApiEndpoint(
      id: id.isEmpty ? normalize(base) : id,
      name: '${m['name'] ?? ''}',
      baseUrl: base,
      apiKey: '${m['apiKey'] ?? ''}',
      model: '${m['model'] ?? ''}',
      lastUsedAt: (m['lastUsedAt'] as num?)?.toInt() ?? 0,
    );
  }
}
