import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'controller/upload_queue_controller.dart';
import 'models/upload_queue_state.dart';
import 'models/upload_task.dart';
import 'repository/upload_queue_repository.dart';
import 'services/session_upload_manifest_builder.dart';
import 'services/upload_http_client.dart';
import 'services/upload_zip_service.dart';
import 'upload_config.dart';

final uploadConfigProvider = Provider<UploadConfig>((ref) {
  return defaultUploadConfig;
});

final uploadDioProvider = Provider<Dio>((ref) {
  final config = ref.watch(uploadConfigProvider);
  final dio = Dio(
    BaseOptions(
      connectTimeout: config.connectTimeout,
      sendTimeout: config.sendTimeout,
      receiveTimeout: config.receiveTimeout,
    ),
  );
  ref.onDispose(() {
    dio.close(force: true);
  });
  return dio;
});

final sessionUploadManifestBuilderProvider =
    Provider<SessionUploadManifestBuilder>((ref) {
      return SessionUploadManifestBuilder();
    });

final uploadZipServiceProvider = Provider<UploadZipService>((ref) {
  return UploadZipService();
});

final uploadHttpClientProvider = Provider<UploadHttpClient>((ref) {
  return UploadHttpClient(
    dio: ref.watch(uploadDioProvider),
    config: ref.watch(uploadConfigProvider),
  );
});

final uploadQueueRepositoryProvider = Provider<UploadQueueRepository>((ref) {
  return UploadQueueRepository();
});

final uploadQueueControllerProvider =
    StateNotifierProvider<UploadQueueController, UploadQueueState>((ref) {
      return UploadQueueController(
        repository: ref.watch(uploadQueueRepositoryProvider),
        manifestBuilder: ref.watch(sessionUploadManifestBuilderProvider),
        zipService: ref.watch(uploadZipServiceProvider),
        httpClient: ref.watch(uploadHttpClientProvider),
        config: ref.watch(uploadConfigProvider),
      );
    });

final latestUploadTaskProvider = Provider<UploadTask?>((ref) {
  final tasks = ref.watch(uploadQueueControllerProvider).tasks;
  if (tasks.isEmpty) {
    return null;
  }
  UploadTask? latest;
  for (final task in tasks) {
    if (latest == null || task.updatedAt.isAfter(latest.updatedAt)) {
      latest = task;
    }
  }
  return latest;
});
