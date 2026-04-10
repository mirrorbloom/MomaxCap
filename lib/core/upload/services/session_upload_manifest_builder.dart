import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/upload_manifest.dart';
import '../models/upload_task.dart';
import '../upload_exceptions.dart';

class SessionUploadManifestBuilder {
  static const Set<String> _requiredRootFiles = <String>{
    'data.mov',
    'data.jsonl',
    'calibration.json',
    'metadata.json',
  };

  static const String _requiredFramesDir = 'frames2';

  Future<SessionUploadManifest> buildFromSessionPath(String sessionPath) async {
    final sessionDir = Directory(sessionPath);
    if (!await sessionDir.exists()) {
      throw UploadException(
        reason: UploadFailureReason.sessionNotFound,
        message: '会话目录不存在: $sessionPath',
      );
    }

    final sessionName = p.basename(sessionDir.path);
    final entries = <UploadManifestEntry>[];
    var totalSizeBytes = 0;

    for (final fileName in _requiredRootFiles) {
      final file = File(p.join(sessionDir.path, fileName));
      if (!await file.exists()) {
        throw UploadException(
          reason: UploadFailureReason.missingRequiredFile,
          message: '缺少必需文件: $fileName',
        );
      }

      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw UploadException(
          reason: UploadFailureReason.missingRequiredFile,
          message: '必需项不是文件: $fileName',
        );
      }

      totalSizeBytes += stat.size;
      entries.add(
        UploadManifestEntry(
          absolutePath: file.path,
          relativePath: fileName,
          sizeBytes: stat.size,
        ),
      );
    }

    final framesDir = Directory(p.join(sessionDir.path, _requiredFramesDir));
    if (!await framesDir.exists()) {
      throw UploadException(
        reason: UploadFailureReason.missingRequiredFile,
        message: '缺少必需目录: $_requiredFramesDir',
      );
    }

    final frameFiles = await framesDir
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();

    if (frameFiles.isEmpty) {
      throw UploadException(
        reason: UploadFailureReason.missingRequiredFile,
        message: '$_requiredFramesDir 目录为空，至少需要 1 个文件。',
      );
    }

    frameFiles.sort((a, b) => a.path.compareTo(b.path));

    for (final file in frameFiles) {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        continue;
      }
      final relativeInsideFrames = p.relative(file.path, from: framesDir.path);
      final relativePath = p.join(_requiredFramesDir, relativeInsideFrames);
      totalSizeBytes += stat.size;
      entries.add(
        UploadManifestEntry(
          absolutePath: file.path,
          relativePath: relativePath,
          sizeBytes: stat.size,
        ),
      );
    }

    if (entries.isEmpty) {
      throw UploadException(
        reason: UploadFailureReason.missingRequiredFile,
        message: '会话目录中没有可上传文件。',
      );
    }

    entries.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return SessionUploadManifest(
      sessionPath: sessionDir.path,
      sessionName: sessionName,
      entries: entries,
      totalSizeBytes: totalSizeBytes,
    );
  }
}
