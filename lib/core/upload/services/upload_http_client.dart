import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/upload_task.dart';
import '../upload_config.dart';
import '../upload_exceptions.dart';

class UploadHttpClient {
  const UploadHttpClient({required Dio dio, required UploadConfig config})
    : _dio = dio,
      _config = config;

  final Dio _dio;
  final UploadConfig _config;

  Future<Map<String, dynamic>?> uploadZip({
    required UploadTask task,
    required File zipFile,
    required void Function(int sent, int total) onSendProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      final formData = FormData.fromMap(<String, dynamic>{
        'file': await MultipartFile.fromFile(
          zipFile.path,
          filename: p.basename(zipFile.path),
        ),
        'sessionName': task.sessionName,
        'sessionPath': task.sessionPath,
      });

      final headers = <String, String>{
        ..._config.extraHeaders,
        'X-Upload-Task-Id': task.id,
      };

      final response = await _dio.postUri(
        _config.uploadUri,
        data: formData,
        options: Options(headers: headers),
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
      );

      final data = response.data;
      if (data is Map) {
        return data.cast<String, dynamic>();
      }
      return <String, dynamic>{'statusCode': response.statusCode, 'data': data};
    } on DioException catch (e) {
      throw _mapDioException(e);
    } catch (e) {
      throw UploadException(
        reason: UploadFailureReason.unknown,
        message: '上传失败: $e',
        retryable: true,
      );
    }
  }

  UploadException _mapDioException(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return UploadException(
          reason: UploadFailureReason.timeout,
          message: '上传超时。',
          retryable: true,
        );
      case DioExceptionType.cancel:
        return UploadException(
          reason: UploadFailureReason.cancelled,
          message: '上传已取消。',
          retryable: false,
        );
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode ?? 0;
        if (statusCode == 401 || statusCode == 403) {
          return UploadException(
            reason: UploadFailureReason.unauthorized,
            message: '鉴权失败，服务器拒绝上传。',
            retryable: false,
          );
        }
        if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
          return UploadException(
            reason: UploadFailureReason.serverRejected,
            message: '服务器暂时不可用（$statusCode）。',
            retryable: true,
          );
        }
        return UploadException(
          reason: UploadFailureReason.serverRejected,
          message: '服务器返回错误（$statusCode）。',
          retryable: false,
        );
      case DioExceptionType.connectionError:
        return UploadException(
          reason: UploadFailureReason.network,
          message: '网络连接失败。',
          retryable: true,
        );
      case DioExceptionType.badCertificate:
        return UploadException(
          reason: UploadFailureReason.network,
          message: '证书校验失败。',
          retryable: false,
        );
      case DioExceptionType.unknown:
        if (error.error is SocketException) {
          return UploadException(
            reason: UploadFailureReason.network,
            message: '网络不可用。',
            retryable: true,
          );
        }
        return UploadException(
          reason: UploadFailureReason.unknown,
          message: '未知上传错误: ${error.message ?? error.error}',
          retryable: true,
        );
    }
  }
}
