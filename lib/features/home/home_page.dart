import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/recorder/recorder_providers.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Map<String, dynamic>? _status;
  Object? _lastError;

  Future<void> _refreshStatus() async {
    setState(() {
      _lastError = null;
    });
    try {
      final status =
          await ref.read(recorderPlatformProvider).getRecordingStatus();
      if (mounted) {
        setState(() {
          _status = status;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _lastError = e;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStatus());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spatial Data Recorder'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'iOS 采集：在 Mac 上执行 flutter run 连接真机；'
              '本页用于验证 MethodChannel 是否注册。',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _refreshStatus,
              icon: const Icon(Icons.sync),
              label: const Text('读取录制状态 (getRecordingStatus)'),
            ),
            const SizedBox(height: 16),
            if (_lastError != null)
              Text(
                '错误: $_lastError',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (_status != null)
              Text('状态: $_status')
            else
              const Text('尚未加载'),
          ],
        ),
      ),
    );
  }
}
