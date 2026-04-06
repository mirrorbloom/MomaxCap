import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/recording/session_directory.dart';
import '../../core/recorder/recorder_providers.dart';
import '../../core/upload/models/upload_enqueue_result.dart';
import '../../core/upload/models/upload_task.dart';
import '../../core/upload/upload_providers.dart';
import 'recordings_browser_page.dart';
import 'recorder_live_preview.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Map<String, dynamic>? _status;
  bool _busy = false;

  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<bool> _ensureCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted) return true;

    status = await Permission.camera.request();
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied || status.isRestricted) {
      if (!mounted) return false;
      final goSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要相机权限'),
          content: const Text(
            '当前相机权限被拒绝，请前往 iOS 设置中为 Spatial Data Recorder 打开相机权限。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (goSettings == true) {
        await openAppSettings();
      }
      return false;
    }

    _toast('需要相机权限才能录制视频。');
    return false;
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await ref
          .read(recorderPlatformProvider)
          .getRecordingStatus();
      if (mounted) {
        setState(() {
          _status = status;
        });
      }
    } catch (e) {
      _toast('刷新状态失败：$e');
    }
  }

  Future<void> _startRecording() async {
    if (!_isIos) {
      _toast('P0 采集仅在 iOS 真机上可用。');
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      final ok = await _ensureCameraPermission();
      if (!ok) {
        return;
      }

      final dir = await createSessionDirectory();

      await ref
          .read(recorderPlatformProvider)
          .startRecording(outputDir: dir.path);
      await _refreshStatus();
      if (mounted) {
        _toast('已开始录制');
      }
    } catch (e) {
      _toast('开始录制失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _stopRecording() async {
    if (!_isIos) {
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      final sessionPath = await ref
          .read(recorderPlatformProvider)
          .stopRecording();

      var uploadMessage = '上传任务状态未知。';
      try {
        final enqueueResult = await ref
            .read(uploadQueueControllerProvider.notifier)
            .enqueueSession(sessionPath);
        uploadMessage = _enqueueMessage(enqueueResult);
      } catch (e) {
        uploadMessage = '录制已完成，但加入上传队列失败：$e';
      }

      await _refreshStatus();
      if (mounted) {
        _toast('已停止录制，$uploadMessage');
      }
    } catch (e) {
      _toast('停止录制失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _toggleRecording() async {
    final recording = _status?['recording'] == true;
    if (recording) {
      await _stopRecording();
      return;
    }
    await _startRecording();
  }

  Future<void> _openRecordings() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RecordingsBrowserPage()),
    );
  }

  void _toast(String msg) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_isIos) {
        try {
          await ref.read(recorderPlatformProvider).preparePreview();
        } catch (_) {}
      }
      await _refreshStatus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final recording = _status?['recording'] == true;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final latestUploadTask = ref.watch(latestUploadTaskProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isIos)
              const RecorderLivePreview()
            else
              Center(
                child: Text(
                  '当前平台：${_platformLabel()}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            if (_busy)
              const Align(
                alignment: Alignment.topCenter,
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (latestUploadTask != null)
              Positioned(
                left: 12,
                right: 12,
                top: 10,
                child: _UploadStatusBanner(
                  task: latestUploadTask,
                  onRetry: latestUploadTask.status == UploadTaskStatus.failed
                      ? () {
                          ref
                              .read(uploadQueueControllerProvider.notifier)
                              .retryTask(latestUploadTask.id);
                        }
                      : null,
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: bottomInset + 12,
              child: Row(
                children: [
                  const SizedBox(width: 56),
                  Expanded(
                    child: Center(
                      child: GestureDetector(
                        onTap: (_busy || !_isIos) ? null : _toggleRecording,
                        child: Container(
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: recording ? 30 : 62,
                              height: recording ? 30 : 62,
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(
                                  recording ? 8 : 31,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: IconButton(
                        onPressed: _openRecordings,
                        tooltip: '打开文件夹',
                        icon: const Icon(
                          Icons.folder_open,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _platformLabel() {
    if (kIsWeb) {
      return 'Web';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      case TargetPlatform.fuchsia:
        return 'Fuchsia';
    }
  }

  String _enqueueMessage(UploadEnqueueResult result) {
    switch (result) {
      case UploadEnqueueResult.created:
        return '上传任务已加入队列。';
      case UploadEnqueueResult.requeued:
        return '上传任务已重新加入队列。';
      case UploadEnqueueResult.alreadyQueued:
        return '上传任务已在队列中。';
      case UploadEnqueueResult.alreadySuccess:
        return '该会话已上传成功。';
    }
  }
}

class _UploadStatusBanner extends StatelessWidget {
  const _UploadStatusBanner({required this.task, required this.onRetry});

  final UploadTask task;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final message = _messageForTask(task);
    final progress = task.progress.fraction;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  _iconForStatus(task.status),
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onRetry != null)
                  TextButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
            if (task.status == UploadTaskStatus.uploading)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  minHeight: 4,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _messageForTask(UploadTask task) {
    switch (task.status) {
      case UploadTaskStatus.waiting:
        return '等待上传：${task.sessionName}';
      case UploadTaskStatus.compressing:
        return '正在压缩：${task.sessionName}';
      case UploadTaskStatus.uploading:
        final percent = (task.progress.fraction * 100).toStringAsFixed(1);
        return '正在上传：$percent%';
      case UploadTaskStatus.retrying:
        return '上传失败，等待重试（第 ${task.attempt} 次）';
      case UploadTaskStatus.success:
        return '上传成功：${task.sessionName}';
      case UploadTaskStatus.failed:
        final failure = task.failureMessage;
        if (failure == null || failure.isEmpty) {
          return '上传失败：${task.sessionName}';
        }
        return '上传失败：$failure';
      case UploadTaskStatus.cancelled:
        return '上传已取消：${task.sessionName}';
    }
  }

  IconData _iconForStatus(UploadTaskStatus status) {
    switch (status) {
      case UploadTaskStatus.waiting:
      case UploadTaskStatus.compressing:
      case UploadTaskStatus.retrying:
        return Icons.schedule;
      case UploadTaskStatus.uploading:
        return Icons.cloud_upload;
      case UploadTaskStatus.success:
        return Icons.check_circle_outline;
      case UploadTaskStatus.failed:
        return Icons.error_outline;
      case UploadTaskStatus.cancelled:
        return Icons.cancel_outlined;
    }
  }
}
