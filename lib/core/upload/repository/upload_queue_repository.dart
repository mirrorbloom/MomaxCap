import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/upload_task.dart';

class UploadQueueRepository {
  UploadQueueRepository({
    Future<Directory> Function()? documentsDirectoryProvider,
  }) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectoryProvider;

  Future<List<UploadTask>> readTasks() async {
    final file = await _queueFile();
    if (!await file.exists()) {
      return const <UploadTask>[];
    }

    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const <UploadTask>[];
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const <UploadTask>[];
      }

      final tasksRaw = decoded['tasks'];
      if (tasksRaw is! List) {
        return const <UploadTask>[];
      }

      return tasksRaw
          .whereType<Map>()
          .map((item) => UploadTask.fromJson(item.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const <UploadTask>[];
    }
  }

  Future<void> writeTasks(List<UploadTask> tasks) async {
    final file = await _queueFile();
    final tempFile = File('${file.path}.tmp');

    final payload = <String, dynamic>{
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'tasks': tasks.map((task) => task.toJson()).toList(),
    };

    await tempFile.writeAsString(jsonEncode(payload), flush: true);

    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  Future<File> _queueFile() async {
    final docsDir = await _documentsDirectoryProvider();
    final outputDir = Directory(p.join(docsDir.path, 'output'));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    return File(p.join(outputDir.path, '.upload_queue.json'));
  }
}
