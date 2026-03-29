import 'package:flutter/services.dart';

import '../constants/recorder_channel.dart';
import 'recorder_platform.dart';

class RecorderMethodChannel implements RecorderPlatform {
  RecorderMethodChannel()
      : _channel = const MethodChannel(RecorderChannel.name);

  final MethodChannel _channel;

  @override
  Future<Map<String, dynamic>> getRecordingStatus() async {
    final Object? result =
        await _channel.invokeMethod<Object?>('getRecordingStatus');
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return <String, dynamic>{};
  }

  @override
  Future<void> startRecording({required String outputDir}) async {
    await _channel.invokeMethod<void>('startRecording', <String, dynamic>{
      'outputDir': outputDir,
    });
  }

  @override
  Future<void> stopRecording() async {
    await _channel.invokeMethod<void>('stopRecording');
  }
}
