import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models/upload_manifest.dart';
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
  Future<UploadZipResult> compressManifest(
    SessionUploadManifest manifest, {
    void Function(int current, int total)? onProgress,
  }) async {
    final sessionDir = Directory(manifest.sessionPath);
    final outputRoot = sessionDir.parent;
    final cacheDir = Directory(p.join(outputRoot.path, '.upload_cache'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final zipFileName =
        '${manifest.sessionName}_${DateTime.now().millisecondsSinceEpoch}.zip';
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
}
