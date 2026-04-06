class UploadConfig {
  const UploadConfig({
    required this.baseUrl,
    required this.uploadPath,
    this.connectTimeout = const Duration(seconds: 10),
    this.sendTimeout = const Duration(seconds: 60),
    this.receiveTimeout = const Duration(seconds: 30),
    this.extraHeaders = const <String, String>{},
    this.maxRetryAttempts = 3,
    this.retryBaseDelay = const Duration(seconds: 2),
    this.maxHistoryItems = 40,
  });

  final String baseUrl;
  final String uploadPath;
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
  final Map<String, String> extraHeaders;
  final int maxRetryAttempts;
  final Duration retryBaseDelay;
  final int maxHistoryItems;

  Uri get uploadUri {
    final normalizedBase = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final normalizedPath = uploadPath.startsWith('/')
        ? uploadPath.substring(1)
        : uploadPath;
    return Uri.parse(normalizedBase).resolve(normalizedPath);
  }

  UploadConfig copyWith({
    String? baseUrl,
    String? uploadPath,
    Duration? connectTimeout,
    Duration? sendTimeout,
    Duration? receiveTimeout,
    Map<String, String>? extraHeaders,
    int? maxRetryAttempts,
    Duration? retryBaseDelay,
    int? maxHistoryItems,
  }) {
    return UploadConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      uploadPath: uploadPath ?? this.uploadPath,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      extraHeaders: extraHeaders ?? this.extraHeaders,
      maxRetryAttempts: maxRetryAttempts ?? this.maxRetryAttempts,
      retryBaseDelay: retryBaseDelay ?? this.retryBaseDelay,
      maxHistoryItems: maxHistoryItems ?? this.maxHistoryItems,
    );
  }
}

const defaultUploadConfig = UploadConfig(
  // 占位地址，后续接入服务器时仅需替换这里或通过 Provider 覆盖。
  baseUrl: 'http://1080.alpen-y.top:8080',
  uploadPath: '/api/v1/slam/upload',
);
