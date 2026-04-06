import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spatial_data_recorder/core/upload/services/session_upload_manifest_builder.dart';
import 'package:spatial_data_recorder/core/upload/services/upload_zip_service.dart';

void main() {
  group('UploadZipService', () {
    late Directory tempRoot;
    late SessionUploadManifestBuilder builder;
    late UploadZipService zipService;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'spatial_data_recorder_zip_',
      );
      builder = SessionUploadManifestBuilder();
      zipService = UploadZipService();
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('compresses manifest and preserves relative paths in zip', () async {
      final sessionDir = Directory(
        p.join(tempRoot.path, 'recording_2026-04-06'),
      );
      await sessionDir.create(recursive: true);

      for (final name in const <String>[
        'data.mov',
        'data.jsonl',
        'calibration.json',
        'metadata.json',
      ]) {
        await File(
          p.join(sessionDir.path, name),
        ).writeAsString('required-$name');
      }

      final frames2Dir = Directory(p.join(sessionDir.path, 'frames2'));
      await frames2Dir.create(recursive: true);
      await File(p.join(frames2Dir.path, '00000000.png')).writeAsString('png0');

      final manifest = await builder.buildFromSessionPath(sessionDir.path);
      final zipResult = await zipService.compressManifest(manifest);

      final zipFile = File(zipResult.zipPath);
      expect(await zipFile.exists(), isTrue);
      expect(zipResult.fileCount, manifest.fileCount);
      expect(zipResult.zipSizeBytes, greaterThan(0));

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final zipNames = archive.files
          .map((file) => p.normalize(file.name))
          .toSet();

      for (final entry in manifest.entries) {
        expect(zipNames, contains(p.normalize(entry.relativePath)));
      }
    });
  });
}
