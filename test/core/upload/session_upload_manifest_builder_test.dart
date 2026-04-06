import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spatial_data_recorder/core/upload/models/upload_task.dart';
import 'package:spatial_data_recorder/core/upload/services/session_upload_manifest_builder.dart';
import 'package:spatial_data_recorder/core/upload/upload_exceptions.dart';

void main() {
  group('SessionUploadManifestBuilder', () {
    late Directory tempRoot;
    late SessionUploadManifestBuilder builder;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'spatial_data_recorder_manifest_',
      );
      builder = SessionUploadManifestBuilder();
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('collects required files and optional contract files only', () async {
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
        p.join(sessionDir.path, 'data2.mov'),
      ).writeAsString('optional-data2');
      await File(
        p.join(sessionDir.path, 'README.md'),
      ).writeAsString('ignored-readme');
      await File(
        p.join(sessionDir.path, 'notes.txt'),
      ).writeAsString('ignored-extra');

      final frames2Dir = Directory(p.join(sessionDir.path, 'frames2'));
      await frames2Dir.create(recursive: true);
      await File(p.join(frames2Dir.path, '00000000.png')).writeAsString('png0');
      await File(p.join(frames2Dir.path, '00000001.png')).writeAsString('png1');

      final manifest = await builder.buildFromSessionPath(sessionDir.path);
      final relativePaths = manifest.entries
          .map((entry) => p.normalize(entry.relativePath))
          .toSet();

      expect(relativePaths, contains(p.normalize('data.mov')));
      expect(relativePaths, contains(p.normalize('data.jsonl')));
      expect(relativePaths, contains(p.normalize('calibration.json')));
      expect(relativePaths, contains(p.normalize('metadata.json')));
      expect(relativePaths, contains(p.normalize('data2.mov')));
      expect(relativePaths, contains(p.normalize('frames2/00000000.png')));
      expect(relativePaths, contains(p.normalize('frames2/00000001.png')));

      expect(relativePaths, isNot(contains(p.normalize('README.md'))));
      expect(relativePaths, isNot(contains(p.normalize('notes.txt'))));
    });

    test('throws missingRequiredFile when required file is missing', () async {
      final sessionDir = Directory(
        p.join(tempRoot.path, 'recording_2026-04-06'),
      );
      await sessionDir.create(recursive: true);

      await File(
        p.join(sessionDir.path, 'data.mov'),
      ).writeAsString('required-data.mov');
      await File(
        p.join(sessionDir.path, 'data.jsonl'),
      ).writeAsString('required-data.jsonl');
      await File(
        p.join(sessionDir.path, 'metadata.json'),
      ).writeAsString('required-metadata');

      expect(
        () => builder.buildFromSessionPath(sessionDir.path),
        throwsA(
          isA<UploadException>().having(
            (error) => error.reason,
            'reason',
            UploadFailureReason.missingRequiredFile,
          ),
        ),
      );
    });
  });
}
