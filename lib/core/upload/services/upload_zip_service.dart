import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models/upload_manifest.dart';
import '../models/upload_session_context.dart';
import '../models/upload_task.dart';
import '../upload_exceptions.dart';

class UploadZipResult {
  const UploadZipResult({
    required this.zipPath,
    required this.zipSizeBytes,
    required this.fileCount,
  });

  final String zipPath;
  final int zipSizeBytes;
  final int fileCount;
}

class UploadZipService {
  static final RegExp _sceneAllowed = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
  static final RegExp _seqAllowed = RegExp(r'^seq\d+$');

  Future<UploadZipResult> compressManifest(
    SessionUploadManifest manifest, {
    UploadSessionContext? sessionContext,
    void Function(int current, int total)? onProgress,
  }) async {
    final sessionDir = Directory(manifest.sessionPath);
    final outputRoot = sessionDir.parent;
    final cacheDir = Directory(p.join(outputRoot.path, '.upload_cache'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final zipFileName = _buildZipFileName(manifest, sessionContext);
    final zipPath = p.join(cacheDir.path, zipFileName);

    try {
      final archive = Archive();
      final total = manifest.entries.length;
      for (var i = 0; i < total; i += 1) {
        final entry = manifest.entries[i];
        final file = File(entry.absolutePath);
        if (!await file.exists()) {
          throw UploadException(
            reason: UploadFailureReason.missingRequiredFile,
            message: '打包时文件不存在: ${entry.relativePath}',
          );
        }

        final bytes = await file.readAsBytes();
        archive.addFile(ArchiveFile(entry.relativePath, bytes.length, bytes));
        onProgress?.call(i + 1, total);
      }

      final encoded = ZipEncoder().encode(archive);

      final zipFile = File(zipPath);
      await zipFile.writeAsBytes(encoded, flush: true);

      if (!await zipFile.exists()) {
        throw UploadException(
          reason: UploadFailureReason.zipFailed,
          message: 'ZIP 文件未生成。',
        );
      }

      final stat = await zipFile.stat();
      return UploadZipResult(
        zipPath: zipPath,
        zipSizeBytes: stat.size,
        fileCount: manifest.fileCount,
      );
    } on UploadException {
      rethrow;
    } catch (e) {
      throw UploadException(
        reason: UploadFailureReason.zipFailed,
        message: '压缩失败: $e',
      );
    }
  }

  Future<void> deleteZipIfExists(String? zipPath) async {
    if (zipPath == null || zipPath.isEmpty) {
      return;
    }
    final file = File(zipPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  String _buildZipFileName(
    SessionUploadManifest manifest,
    UploadSessionContext? sessionContext,
  ) {
    if (sessionContext == null) {
      return '${manifest.sessionName}_${DateTime.now().millisecondsSinceEpoch}.zip';
    }

    final base = manifest.sessionName.startsWith('recording_')
        ? manifest.sessionName
        : 'recording_${manifest.sessionName}';

    final sceneName = sessionContext.sceneName.trim();
    if (!_sceneAllowed.hasMatch(sceneName)) {
      throw UploadException(
        reason: UploadFailureReason.unknown,
        message: 'Scene 名称不合法，无法生成 ZIP 文件名：$sceneName',
        retryable: false,
      );
    }

    final typeToken = sessionContext.captureType == UploadCaptureType.humanInScene
        ? 'human'
        : 'scene';

    final parts = <String>['${base}__scene=$sceneName', 'type=$typeToken'];

    if (typeToken == 'human') {
      final seqName = sessionContext.seqName.trim();
      if (!_seqAllowed.hasMatch(seqName)) {
        throw UploadException(
          reason: UploadFailureReason.unknown,
          message: 'Seq 名称不合法（需为 seq0/seq1/...），无法生成 ZIP 文件名：$seqName',
          retryable: false,
        );
      }
      final cam = sessionContext.cam;
      if (cam == null) {
        throw UploadException(
          reason: UploadFailureReason.unknown,
          message: '带人拍摄缺少 cam=A/B，无法生成 ZIP 文件名。',
          retryable: false,
        );
      }
      parts.add('seq=$seqName');
      parts.add('cam=${cam.wireValue}');
    }

    return '${parts.join('__')}.zip';
  }
}
