/// 录制能力抽象，便于测试与后续替换为假实现。
abstract class RecorderPlatform {
  Future<Map<String, dynamic>> getRecordingStatus();

  Future<void> startRecording({required String outputDir});

  Future<void> stopRecording();
}
