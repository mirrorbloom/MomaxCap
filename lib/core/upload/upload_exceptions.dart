import 'models/upload_task.dart';

class UploadException implements Exception {
  UploadException({
    required this.reason,
    required this.message,
    this.retryable = false,
  });

  final UploadFailureReason reason;
  final String message;
  final bool retryable;

  @override
  String toString() => 'UploadException($reason): $message';
}
