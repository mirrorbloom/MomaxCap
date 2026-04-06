enum UploadTaskStatus {
  waiting,
  compressing,
  uploading,
  retrying,
  success,
  failed,
  cancelled,
}

enum UploadFailureReason {
  none,
  sessionNotFound,
  missingRequiredFile,
  zipFailed,
  network,
  timeout,
  unauthorized,
  serverRejected,
  cancelled,
  unknown,
}

class UploadProgress {
  const UploadProgress({this.sentBytes = 0, this.totalBytes = 0});

  static const zero = UploadProgress();

  final int sentBytes;
  final int totalBytes;

  double get fraction {
    if (totalBytes <= 0) {
      return 0;
    }
    return sentBytes / totalBytes;
  }

  UploadProgress copyWith({int? sentBytes, int? totalBytes}) {
    return UploadProgress(
      sentBytes: sentBytes ?? this.sentBytes,
      totalBytes: totalBytes ?? this.totalBytes,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'sentBytes': sentBytes, 'totalBytes': totalBytes};
  }

  factory UploadProgress.fromJson(Map<String, dynamic> json) {
    return UploadProgress(
      sentBytes: (json['sentBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class UploadTask {
  const UploadTask({
    required this.id,
    required this.sessionPath,
    required this.sessionName,
    required this.status,
    required this.failureReason,
    required this.failureMessage,
    required this.progress,
    required this.attempt,
    required this.maxAttempts,
    required this.createdAt,
    required this.updatedAt,
    required this.nextRetryAt,
    required this.zipPath,
    required this.zipSizeBytes,
    required this.serverResponse,
  });

  factory UploadTask.create({
    required String id,
    required String sessionPath,
    required String sessionName,
    required int maxAttempts,
  }) {
    final now = DateTime.now();
    return UploadTask(
      id: id,
      sessionPath: sessionPath,
      sessionName: sessionName,
      status: UploadTaskStatus.waiting,
      failureReason: UploadFailureReason.none,
      failureMessage: null,
      progress: UploadProgress.zero,
      attempt: 0,
      maxAttempts: maxAttempts,
      createdAt: now,
      updatedAt: now,
      nextRetryAt: null,
      zipPath: null,
      zipSizeBytes: null,
      serverResponse: null,
    );
  }

  final String id;
  final String sessionPath;
  final String sessionName;
  final UploadTaskStatus status;
  final UploadFailureReason failureReason;
  final String? failureMessage;
  final UploadProgress progress;
  final int attempt;
  final int maxAttempts;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? nextRetryAt;
  final String? zipPath;
  final int? zipSizeBytes;
  final Map<String, dynamic>? serverResponse;

  bool get isTerminal {
    return status == UploadTaskStatus.success ||
        status == UploadTaskStatus.failed ||
        status == UploadTaskStatus.cancelled;
  }

  UploadTask copyWith({
    String? id,
    String? sessionPath,
    String? sessionName,
    UploadTaskStatus? status,
    UploadFailureReason? failureReason,
    String? failureMessage,
    bool clearFailureMessage = false,
    UploadProgress? progress,
    int? attempt,
    int? maxAttempts,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? nextRetryAt,
    bool clearNextRetryAt = false,
    String? zipPath,
    bool clearZipPath = false,
    int? zipSizeBytes,
    bool clearZipSizeBytes = false,
    Map<String, dynamic>? serverResponse,
    bool clearServerResponse = false,
  }) {
    return UploadTask(
      id: id ?? this.id,
      sessionPath: sessionPath ?? this.sessionPath,
      sessionName: sessionName ?? this.sessionName,
      status: status ?? this.status,
      failureReason: failureReason ?? this.failureReason,
      failureMessage: clearFailureMessage
          ? null
          : (failureMessage ?? this.failureMessage),
      progress: progress ?? this.progress,
      attempt: attempt ?? this.attempt,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      nextRetryAt: clearNextRetryAt ? null : (nextRetryAt ?? this.nextRetryAt),
      zipPath: clearZipPath ? null : (zipPath ?? this.zipPath),
      zipSizeBytes: clearZipSizeBytes
          ? null
          : (zipSizeBytes ?? this.zipSizeBytes),
      serverResponse: clearServerResponse
          ? null
          : (serverResponse ?? this.serverResponse),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'sessionPath': sessionPath,
      'sessionName': sessionName,
      'status': status.name,
      'failureReason': failureReason.name,
      'failureMessage': failureMessage,
      'progress': progress.toJson(),
      'attempt': attempt,
      'maxAttempts': maxAttempts,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'nextRetryAt': nextRetryAt?.toIso8601String(),
      'zipPath': zipPath,
      'zipSizeBytes': zipSizeBytes,
      'serverResponse': serverResponse,
    };
  }

  factory UploadTask.fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String?;
    final failureReasonName = json['failureReason'] as String?;

    return UploadTask(
      id: json['id'] as String,
      sessionPath: json['sessionPath'] as String,
      sessionName: json['sessionName'] as String,
      status: UploadTaskStatus.values.firstWhere(
        (value) => value.name == statusName,
        orElse: () => UploadTaskStatus.waiting,
      ),
      failureReason: UploadFailureReason.values.firstWhere(
        (value) => value.name == failureReasonName,
        orElse: () => UploadFailureReason.none,
      ),
      failureMessage: json['failureMessage'] as String?,
      progress: UploadProgress.fromJson(
        Map<String, dynamic>.from(
          (json['progress'] as Map?) ?? const <String, dynamic>{},
        ),
      ),
      attempt: (json['attempt'] as num?)?.toInt() ?? 0,
      maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 3,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      nextRetryAt: DateTime.tryParse(json['nextRetryAt'] as String? ?? ''),
      zipPath: json['zipPath'] as String?,
      zipSizeBytes: (json['zipSizeBytes'] as num?)?.toInt(),
      serverResponse: (json['serverResponse'] as Map?)?.cast<String, dynamic>(),
    );
  }
}
