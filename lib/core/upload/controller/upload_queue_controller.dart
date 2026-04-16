import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/upload_enqueue_result.dart';
import '../models/upload_queue_state.dart';
import '../models/upload_task.dart';
import '../repository/upload_queue_repository.dart';
import '../services/session_upload_manifest_builder.dart';
import '../services/upload_http_client.dart';
import '../services/upload_session_context_service.dart';
import '../services/upload_zip_service.dart';
import '../upload_config.dart';
import '../upload_exceptions.dart';

class UploadQueueController extends StateNotifier<UploadQueueState> {
  UploadQueueController({
    required UploadQueueRepository repository,
    required SessionUploadManifestBuilder manifestBuilder,
    required UploadZipService zipService,
    required UploadSessionContextService contextService,
    required UploadHttpClient httpClient,
    required UploadConfig config,
    DateTime Function()? now,
  }) : _repository = repository,
       _manifestBuilder = manifestBuilder,
       _zipService = zipService,
       _contextService = contextService,
       _httpClient = httpClient,
       _config = config,
       _now = now ?? DateTime.now,
       super(const UploadQueueState.initial()) {
    _bootstrapFuture = _bootstrap();
  }

  final UploadQueueRepository _repository;
  final SessionUploadManifestBuilder _manifestBuilder;
  final UploadZipService _zipService;
  final UploadSessionContextService _contextService;
  final UploadHttpClient _httpClient;
  final UploadConfig _config;
  final DateTime Function() _now;

  late final Future<void> _bootstrapFuture;

  bool _disposed = false;
  bool _loopRunning = false;
  Timer? _wakeUpTimer;
  CancelToken? _activeCancelToken;

  Future<void> _bootstrap() async {
    final storedTasks = await _repository.readTasks();
    final normalizedTasks = <UploadTask>[];

    for (final task in storedTasks) {
      await _zipService.deleteZipIfExists(task.zipPath);
      normalizedTasks.add(_normalizeRecoveredTask(task));
    }

    final trimmed = _trimHistory(normalizedTasks);
    state = state.copyWith(tasks: trimmed);
    await _repository.writeTasks(trimmed);
    _kickLoop();
  }

  UploadTask _normalizeRecoveredTask(UploadTask task) {
    if (task.status == UploadTaskStatus.compressing ||
        task.status == UploadTaskStatus.uploading) {
      return task.copyWith(
        status: UploadTaskStatus.waiting,
        updatedAt: _now(),
        clearNextRetryAt: true,
        clearZipPath: true,
        clearZipSizeBytes: true,
        progress: UploadProgress.zero,
      );
    }

    if (task.status == UploadTaskStatus.retrying && task.nextRetryAt == null) {
      return task.copyWith(
        status: UploadTaskStatus.waiting,
        updatedAt: _now(),
        clearFailureMessage: true,
        failureReason: UploadFailureReason.none,
        clearNextRetryAt: true,
      );
    }

    return task.copyWith(clearZipPath: true, clearZipSizeBytes: true);
  }

  Future<UploadEnqueueResult> enqueueSession(String sessionPath) async {
    await _bootstrapFuture;

    final normalizedSessionPath = p.normalize(sessionPath);
    final tasks = <UploadTask>[...state.tasks];
    final index = tasks.indexWhere(
      (task) => p.normalize(task.sessionPath) == normalizedSessionPath,
    );

    if (index < 0) {
      tasks.add(
        UploadTask.create(
          id: const Uuid().v4(),
          sessionPath: normalizedSessionPath,
          sessionName: p.basename(normalizedSessionPath),
          maxAttempts: _config.maxRetryAttempts,
        ),
      );
      await _setTasksAndPersist(tasks);
      _kickLoop();
      return UploadEnqueueResult.created;
    }

    final existing = tasks[index];
    if (existing.status == UploadTaskStatus.success) {
      return UploadEnqueueResult.alreadySuccess;
    }

    if (existing.status == UploadTaskStatus.waiting ||
        existing.status == UploadTaskStatus.compressing ||
        existing.status == UploadTaskStatus.uploading ||
        existing.status == UploadTaskStatus.retrying) {
      _kickLoop();
      return UploadEnqueueResult.alreadyQueued;
    }

    tasks[index] = existing.copyWith(
      status: UploadTaskStatus.waiting,
      failureReason: UploadFailureReason.none,
      clearFailureMessage: true,
      clearNextRetryAt: true,
      clearZipPath: true,
      clearZipSizeBytes: true,
      clearServerResponse: true,
      progress: UploadProgress.zero,
      updatedAt: _now(),
      attempt: 0,
    );
    await _setTasksAndPersist(tasks);
    _kickLoop();
    return UploadEnqueueResult.requeued;
  }

  Future<void> retryTask(String taskId) async {
    await _bootstrapFuture;

    final tasks = <UploadTask>[...state.tasks];
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      return;
    }

    final task = tasks[index];
    if (task.status != UploadTaskStatus.failed &&
        task.status != UploadTaskStatus.cancelled) {
      return;
    }

    tasks[index] = task.copyWith(
      status: UploadTaskStatus.waiting,
      failureReason: UploadFailureReason.none,
      clearFailureMessage: true,
      clearNextRetryAt: true,
      clearZipPath: true,
      clearZipSizeBytes: true,
      progress: UploadProgress.zero,
      updatedAt: _now(),
      attempt: 0,
      clearServerResponse: true,
    );

    await _setTasksAndPersist(tasks);
    _kickLoop();
  }

  Future<void> retrySession(String sessionPath) async {
    await _bootstrapFuture;
    final normalizedSessionPath = p.normalize(sessionPath);

    for (final task in state.tasks.reversed) {
      if (p.normalize(task.sessionPath) == normalizedSessionPath) {
        await retryTask(task.id);
        return;
      }
    }

    await enqueueSession(normalizedSessionPath);
  }

  Future<void> cancelActiveTask(String taskId) async {
    await _bootstrapFuture;

    if (state.activeTaskId == taskId) {
      _activeCancelToken?.cancel('cancelled_by_user');
      return;
    }

    final updated = await _updateTaskAndPersist(
      taskId,
      (task) => task.copyWith(
        status: UploadTaskStatus.cancelled,
        failureReason: UploadFailureReason.cancelled,
        failureMessage: '任务已取消。',
        progress: UploadProgress.zero,
        updatedAt: _now(),
      ),
    );

    if (updated != null) {
      await _zipService.deleteZipIfExists(updated.zipPath);
    }
  }

  void _kickLoop() {
    if (_disposed || _loopRunning) {
      return;
    }

    _loopRunning = true;
    unawaited(_processLoop());
  }

  Future<void> _processLoop() async {
    try {
      await _bootstrapFuture;

      while (!_disposed) {
        final now = _now();
        final nextTask = _pickRunnableTask(now);

        if (nextTask == null) {
          state = state.copyWith(isProcessing: false, clearActiveTaskId: true);
          _scheduleWakeUpForRetry(now);
          return;
        }

        _cancelWakeUp();
        state = state.copyWith(isProcessing: true, activeTaskId: nextTask.id);

        await _executeTask(nextTask.id);
      }
    } finally {
      _loopRunning = false;
    }
  }

  UploadTask? _pickRunnableTask(DateTime now) {
    for (final task in state.tasks) {
      if (task.status == UploadTaskStatus.waiting) {
        return task;
      }
      if (task.status == UploadTaskStatus.retrying) {
        final retryAt = task.nextRetryAt;
        if (retryAt == null || !retryAt.isAfter(now)) {
          return task;
        }
      }
    }
    return null;
  }

  void _scheduleWakeUpForRetry(DateTime now) {
    DateTime? nearest;
    for (final task in state.tasks) {
      if (task.status != UploadTaskStatus.retrying ||
          task.nextRetryAt == null) {
        continue;
      }
      if (nearest == null || task.nextRetryAt!.isBefore(nearest)) {
        nearest = task.nextRetryAt;
      }
    }

    if (nearest == null) {
      _cancelWakeUp();
      return;
    }

    _wakeUpTimer?.cancel();
    final delay = nearest.difference(now);
    _wakeUpTimer = Timer(delay.isNegative ? Duration.zero : delay, _kickLoop);
  }

  void _cancelWakeUp() {
    _wakeUpTimer?.cancel();
    _wakeUpTimer = null;
  }

  Future<void> _executeTask(String taskId) async {
    var task = _taskById(taskId);
    if (task == null) {
      return;
    }

    await _zipService.deleteZipIfExists(task.zipPath);

    task = await _updateTaskAndPersist(
      taskId,
      (current) => current.copyWith(
        status: UploadTaskStatus.compressing,
        failureReason: UploadFailureReason.none,
        clearFailureMessage: true,
        clearNextRetryAt: true,
        clearZipPath: true,
        clearZipSizeBytes: true,
        progress: UploadProgress.zero,
        updatedAt: _now(),
      ),
    );
    if (task == null) {
      return;
    }

    try {
      final manifest = await _manifestBuilder.buildFromSessionPath(
        task.sessionPath,
      );
      final sessionContext = await _contextService.ensureContextForSession(
        task.sessionPath,
      );
      final zipResult = await _zipService.compressManifest(
        manifest,
        sessionContext: sessionContext,
      );

      task = await _updateTaskAndPersist(
        taskId,
        (current) => current.copyWith(
          status: UploadTaskStatus.uploading,
          zipPath: zipResult.zipPath,
          zipSizeBytes: zipResult.zipSizeBytes,
          progress: UploadProgress.zero,
          updatedAt: _now(),
        ),
      );
      if (task == null) {
        return;
      }

      task = await _updateTaskAndPersist(
        taskId,
        (current) =>
            current.copyWith(attempt: current.attempt + 1, updatedAt: _now()),
      );
      if (task == null) {
        return;
      }

      final zipFile = File(zipResult.zipPath);
      _activeCancelToken = CancelToken();
      final response = await _httpClient.uploadZip(
        task: task,
        zipFile: zipFile,
        sessionContext: sessionContext,
        cancelToken: _activeCancelToken,
        onSendProgress: (sent, total) {
          _updateTaskInMemory(
            taskId,
            (current) => current.copyWith(
              progress: UploadProgress(sentBytes: sent, totalBytes: total),
              updatedAt: _now(),
            ),
          );
        },
      );
      _activeCancelToken = null;

      await _zipService.deleteZipIfExists(zipResult.zipPath);

      await _updateTaskAndPersist(
        taskId,
        (current) => current.copyWith(
          status: UploadTaskStatus.success,
          failureReason: UploadFailureReason.none,
          clearFailureMessage: true,
          clearNextRetryAt: true,
          clearZipPath: true,
          clearZipSizeBytes: true,
          progress: UploadProgress(
            sentBytes: current.progress.totalBytes,
            totalBytes: current.progress.totalBytes,
          ),
          updatedAt: _now(),
          serverResponse: response,
        ),
      );
    } on UploadException catch (e) {
      _activeCancelToken = null;
      final latest = _taskById(taskId);
      if (latest == null) {
        return;
      }

      await _zipService.deleteZipIfExists(latest.zipPath);

      if (e.reason == UploadFailureReason.cancelled) {
        await _updateTaskAndPersist(
          taskId,
          (current) => current.copyWith(
            status: UploadTaskStatus.cancelled,
            failureReason: UploadFailureReason.cancelled,
            failureMessage: e.message,
            clearNextRetryAt: true,
            clearZipPath: true,
            clearZipSizeBytes: true,
            progress: UploadProgress.zero,
            updatedAt: _now(),
          ),
        );
        return;
      }

      if (e.retryable && latest.attempt < latest.maxAttempts) {
        final retryAt = _now().add(_retryDelayForAttempt(latest.attempt));
        await _updateTaskAndPersist(
          taskId,
          (current) => current.copyWith(
            status: UploadTaskStatus.retrying,
            failureReason: e.reason,
            failureMessage: e.message,
            nextRetryAt: retryAt,
            clearZipPath: true,
            clearZipSizeBytes: true,
            progress: UploadProgress.zero,
            updatedAt: _now(),
          ),
        );
      } else {
        await _updateTaskAndPersist(
          taskId,
          (current) => current.copyWith(
            status: UploadTaskStatus.failed,
            failureReason: e.reason,
            failureMessage: e.message,
            clearNextRetryAt: true,
            clearZipPath: true,
            clearZipSizeBytes: true,
            progress: UploadProgress.zero,
            updatedAt: _now(),
          ),
        );
      }
    } catch (e) {
      _activeCancelToken = null;
      final latest = _taskById(taskId);
      if (latest == null) {
        return;
      }

      await _zipService.deleteZipIfExists(latest.zipPath);

      final retryable = latest.attempt < latest.maxAttempts;
      if (retryable) {
        final retryAt = _now().add(_retryDelayForAttempt(latest.attempt));
        await _updateTaskAndPersist(
          taskId,
          (current) => current.copyWith(
            status: UploadTaskStatus.retrying,
            failureReason: UploadFailureReason.unknown,
            failureMessage: '上传异常: $e',
            nextRetryAt: retryAt,
            clearZipPath: true,
            clearZipSizeBytes: true,
            progress: UploadProgress.zero,
            updatedAt: _now(),
          ),
        );
      } else {
        await _updateTaskAndPersist(
          taskId,
          (current) => current.copyWith(
            status: UploadTaskStatus.failed,
            failureReason: UploadFailureReason.unknown,
            failureMessage: '上传异常: $e',
            clearNextRetryAt: true,
            clearZipPath: true,
            clearZipSizeBytes: true,
            progress: UploadProgress.zero,
            updatedAt: _now(),
          ),
        );
      }
    }
  }

  Duration _retryDelayForAttempt(int attempt) {
    final safeAttempt = attempt <= 0 ? 1 : attempt;
    final multiplier = 1 << (safeAttempt - 1);
    final milliseconds = _config.retryBaseDelay.inMilliseconds * multiplier;
    final capped = milliseconds > const Duration(minutes: 5).inMilliseconds
        ? const Duration(minutes: 5).inMilliseconds
        : milliseconds;
    return Duration(milliseconds: capped);
  }

  UploadTask? _taskById(String id) {
    for (final task in state.tasks) {
      if (task.id == id) {
        return task;
      }
    }
    return null;
  }

  void _updateTaskInMemory(
    String taskId,
    UploadTask Function(UploadTask current) transform,
  ) {
    final tasks = <UploadTask>[...state.tasks];
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      return;
    }

    tasks[index] = transform(tasks[index]);
    state = state.copyWith(tasks: tasks);
  }

  Future<UploadTask?> _updateTaskAndPersist(
    String taskId,
    UploadTask Function(UploadTask current) transform,
  ) async {
    final tasks = <UploadTask>[...state.tasks];
    final index = tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      return null;
    }

    tasks[index] = transform(tasks[index]);
    await _setTasksAndPersist(tasks);
    return _taskById(taskId);
  }

  Future<void> _setTasksAndPersist(List<UploadTask> tasks) async {
    final trimmed = _trimHistory(tasks);
    state = state.copyWith(tasks: trimmed);
    await _repository.writeTasks(trimmed);
  }

  List<UploadTask> _trimHistory(List<UploadTask> tasks) {
    final active = <UploadTask>[];
    final terminal = <UploadTask>[];

    for (final task in tasks) {
      if (task.isTerminal) {
        terminal.add(task);
      } else {
        active.add(task);
      }
    }

    terminal.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final trimmedTerminal = terminal.take(_config.maxHistoryItems).toList();

    final merged = <UploadTask>[...active, ...trimmedTerminal];
    merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return merged;
  }

  @override
  void dispose() {
    _disposed = true;
    _wakeUpTimer?.cancel();
    _activeCancelToken?.cancel('controller_disposed');
    super.dispose();
  }
}
