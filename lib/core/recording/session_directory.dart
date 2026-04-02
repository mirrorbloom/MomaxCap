import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 在应用文档目录下创建 `output/recording_YYYY-MM-DD_HH-mm-ss/` 作为一次采集会话目录。
Future<Directory> createSessionDirectory() async {
  final root = await getApplicationDocumentsDirectory();
  final outputRoot = Directory(p.join(root.path, 'output'));
  await outputRoot.create(recursive: true);

  final now = DateTime.now();
  final baseName =
      'recording_${_fourDigits(now.year)}-${_twoDigits(now.month)}-${_twoDigits(now.day)}_${_twoDigits(now.hour)}-${_twoDigits(now.minute)}-${_twoDigits(now.second)}';

  var dir = Directory(p.join(outputRoot.path, baseName));
  var collisionIndex = 1;
  while (await dir.exists()) {
    dir = Directory(p.join(outputRoot.path, '${baseName}_$collisionIndex'));
    collisionIndex += 1;
  }

  await dir.create(recursive: true);
  return dir;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _fourDigits(int value) => value.toString().padLeft(4, '0');
