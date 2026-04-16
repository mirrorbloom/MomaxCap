import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spatial_data_recorder/core/upload/models/upload_session_context.dart';
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
      await File(
        p.join(sessionDir.path, 'upload_context.json'),
      ).writeAsString('{"sceneName":"scene_demo","seqName":"seq_demo"}');

      final frames2Dir = Directory(p.join(sessionDir.path, 'frames2'));
      await frames2Dir.create(recursive: true);
      await File(p.join(frames2Dir.path, '00000000.png')).writeAsString('png0');

      final manifest = await builder.buildFromSessionPath(sessionDir.path);
      final sessionContext = UploadSessionContext(
        captureType: UploadCaptureType.sceneOnly,
        sceneName: 'scene_demo',
        seqName: 'seq0',
        cam: null,
        pairGroupId: null,
        audioTrackPresent: false,
        confirmedAt: DateTime.utc(2026, 4, 6),
      );
      final zipResult = await zipService.compressManifest(
        manifest,
        sessionContext: sessionContext,
      );

      final zipFile = File(zipResult.zipPath);
      expect(await zipFile.exists(), isTrue);
      expect(
        p.basename(zipResult.zipPath),
        'recording_2026-04-06__scene=scene_demo__type=scene.zip',
      );
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

    test('adds seq/cam tokens for human capture zip name', () async {
      final sessionDir = Directory(
        p.join(tempRoot.path, 'recording_2026-04-06_human'),
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
      final sessionContext = UploadSessionContext(
        captureType: UploadCaptureType.humanInScene,
        sceneName: 'scene_demo',
        seqName: 'seq0',
        cam: UploadCam.A,
        pairGroupId: 'group_demo',
        audioTrackPresent: false,
        confirmedAt: DateTime.utc(2026, 4, 6),
      );

      final zipResult = await zipService.compressManifest(
        manifest,
        sessionContext: sessionContext,
      );

      expect(
        p.basename(zipResult.zipPath),
        'recording_2026-04-06_human__scene=scene_demo__type=human__seq=seq0__cam=A.zip',
      );
    });
  });
}
