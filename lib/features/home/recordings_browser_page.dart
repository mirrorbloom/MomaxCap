import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/upload/models/upload_enqueue_result.dart';
import '../../core/upload/models/upload_task.dart';
import '../../core/upload/upload_providers.dart';
import 'upload_session_context_dialog.dart';

class RecordingsBrowserPage extends ConsumerStatefulWidget {
  const RecordingsBrowserPage({super.key});

  @override
  ConsumerState<RecordingsBrowserPage> createState() =>
      _RecordingsBrowserPageState();
}

class _RecordingsBrowserPageState extends ConsumerState<RecordingsBrowserPage> {
  Directory? _currentDir;
  List<FileSystemEntity> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRoot();
  }

  Future<void> _loadRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    final outputDir = Directory(p.join(docs.path, 'output'));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    await _openDirectory(outputDir);
  }

  Future<void> _openDirectory(Directory dir) async {
    setState(() {
      _loading = true;
    });

    final entries = dir.listSync(followLinks: false);
    entries.sort((a, b) {
      final aIsDir = a is Directory;
      final bIsDir = b is Directory;
      if (aIsDir != bIsDir) {
        return aIsDir ? -1 : 1;
      }
      return p.basename(a.path).compareTo(p.basename(b.path));
    });

    if (!mounted) return;
    setState(() {
      _currentDir = dir;
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _handleTap(FileSystemEntity entity) async {
    if (entity is Directory) {
      await _openDirectory(entity);
      return;
    }
    if (entity is File) {
      final stat = await entity.stat();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${p.basename(entity.path)} (${stat.size} bytes)'),
        ),
      );
    }
  }

  Future<void> _handleRecordingUpload(
    Directory directory,
    UploadTask? existingTask,
  ) async {
    try {
      final contextService = ref.read(uploadSessionContextServiceProvider);
      final existingContext = await contextService.readForSession(
        directory.path,
      );
      if (existingContext == null) {
        final ensuredContext = await contextService.ensureContextForSession(
          directory.path,
        );
        final uploadContext = await showUploadSessionContextDialog(
          context: context,
          sessionPath: directory.path,
          contextService: contextService,
        );
        if (uploadContext == null) {
          await contextService.writeForSession(directory.path, ensuredContext);
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已保留本地默认上传信息，未加入上传队列。')));
          return;
        }
        await contextService.writeForSession(directory.path, uploadContext);
      }

      if (existingTask != null &&
          (existingTask.status == UploadTaskStatus.failed ||
              existingTask.status == UploadTaskStatus.cancelled)) {
        await ref
            .read(uploadQueueControllerProvider.notifier)
            .retrySession(directory.path);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已重新加入上传队列。')));
        return;
      }

      final result = await ref
          .read(uploadQueueControllerProvider.notifier)
          .enqueueSession(directory.path);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_enqueueMessage(result))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加入上传队列失败：$e')));
    }
  }

  String _enqueueMessage(UploadEnqueueResult result) {
    switch (result) {
      case UploadEnqueueResult.created:
        return '已加入上传队列。';
      case UploadEnqueueResult.requeued:
        return '已重新加入上传队列。';
      case UploadEnqueueResult.alreadyQueued:
        return '该会话已在上传队列中。';
      case UploadEnqueueResult.alreadySuccess:
        return '该会话已上传成功。';
    }
  }

  UploadTask? _findTaskForSession(List<UploadTask> tasks, String sessionPath) {
    final normalizedPath = p.normalize(sessionPath);
    for (final task in tasks.reversed) {
      if (p.normalize(task.sessionPath) == normalizedPath) {
        return task;
      }
    }
    return null;
  }

  IconData _statusIcon(UploadTaskStatus status) {
    switch (status) {
      case UploadTaskStatus.waiting:
      case UploadTaskStatus.compressing:
      case UploadTaskStatus.retrying:
        return Icons.schedule;
      case UploadTaskStatus.uploading:
        return Icons.cloud_upload;
      case UploadTaskStatus.success:
        return Icons.check_circle;
      case UploadTaskStatus.failed:
        return Icons.error;
      case UploadTaskStatus.cancelled:
        return Icons.cancel;
    }
  }

  String _uploadActionLabel(UploadTask? task) {
    if (task == null) {
      return '上传';
    }
    if (task.status == UploadTaskStatus.failed ||
        task.status == UploadTaskStatus.cancelled) {
      return '重试上传';
    }
    if (task.status == UploadTaskStatus.success) {
      return '已上传';
    }
    return '上传中';
  }

  bool _canTriggerUpload(UploadTask? task) {
    if (task == null) {
      return true;
    }
    return task.status == UploadTaskStatus.failed ||
        task.status == UploadTaskStatus.cancelled;
  }

  @override
  Widget build(BuildContext context) {
    final dir = _currentDir;
    final uploadState = ref.watch(uploadQueueControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(dir == null ? '录制文件' : p.basename(dir.path)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            final current = _currentDir;
            if (current == null) {
              Navigator.of(context).maybePop();
              return;
            }
            final parent = current.parent;
            if (parent.path == current.path ||
                p.basename(current.path) == 'output') {
              Navigator.of(context).maybePop();
              return;
            }
            await _openDirectory(parent);
          },
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                final directory = entry is Directory ? entry : null;
                final isDir = directory != null;
                final name = p.basename(entry.path);
                final isRecordingDir = isDir && name.startsWith('recording_');
                final uploadTask = isRecordingDir
                    ? _findTaskForSession(uploadState.tasks, entry.path)
                    : null;

                return ListTile(
                  leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file),
                  title: Text(name),
                  subtitle: uploadTask == null
                      ? null
                      : Text(
                          _uploadActionLabel(uploadTask),
                          style: TextStyle(
                            color: uploadTask.status == UploadTaskStatus.failed
                                ? Colors.red
                                : null,
                          ),
                        ),
                  trailing: isRecordingDir
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (uploadTask != null)
                              Icon(
                                _statusIcon(uploadTask.status),
                                size: 18,
                                color:
                                    uploadTask.status == UploadTaskStatus.failed
                                    ? Colors.red
                                    : null,
                              ),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'upload') {
                                  _handleRecordingUpload(directory, uploadTask);
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem<String>(
                                  value: 'upload',
                                  enabled: _canTriggerUpload(uploadTask),
                                  child: Text(_uploadActionLabel(uploadTask)),
                                ),
                              ],
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        )
                      : Icon(isDir ? Icons.chevron_right : Icons.more_horiz),
                  onTap: () => _handleTap(entry),
                  onLongPress: isRecordingDir
                      ? () => _handleRecordingUpload(directory, uploadTask)
                      : null,
                );
              },
            ),
    );
  }
}
