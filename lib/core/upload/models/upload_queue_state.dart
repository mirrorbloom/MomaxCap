import 'upload_task.dart';

class UploadQueueState {
  const UploadQueueState({
    required this.tasks,
    required this.isProcessing,
    required this.activeTaskId,
  });

  const UploadQueueState.initial()
    : tasks = const <UploadTask>[],
      isProcessing = false,
      activeTaskId = null;

  final List<UploadTask> tasks;
  final bool isProcessing;
  final String? activeTaskId;

  UploadTask? get activeTask {
    final id = activeTaskId;
    if (id == null) {
      return null;
    }
    for (final task in tasks) {
      if (task.id == id) {
        return task;
      }
    }
    return null;
  }

  int get pendingCount {
    var count = 0;
    for (final task in tasks) {
      if (task.status == UploadTaskStatus.waiting ||
          task.status == UploadTaskStatus.retrying ||
          task.status == UploadTaskStatus.compressing ||
          task.status == UploadTaskStatus.uploading) {
        count += 1;
      }
    }
    return count;
  }

  UploadQueueState copyWith({
    List<UploadTask>? tasks,
    bool? isProcessing,
    String? activeTaskId,
    bool clearActiveTaskId = false,
  }) {
    return UploadQueueState(
      tasks: tasks ?? this.tasks,
      isProcessing: isProcessing ?? this.isProcessing,
      activeTaskId: clearActiveTaskId
          ? null
          : (activeTaskId ?? this.activeTaskId),
    );
  }
}
