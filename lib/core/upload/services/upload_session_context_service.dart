import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/upload_session_context.dart';

class UploadSessionContextService {
  static final RegExp _allowedSegmentPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]*$',
  );
  static final RegExp _allowedSeqNamePattern = RegExp(r'^seq\d+$');
  static const String _defaultsFileName = '.upload_context_defaults.json';

  Future<UploadSessionContext> ensureContextForSession(String sessionPath) async {
    final existing = await readForSession(sessionPath);
    if (existing != null) {
      return existing;
    }

    final created = UploadSessionContext(
      captureType: UploadCaptureType.sceneOnly,
      sceneName: generateSceneName(p.basename(sessionPath)),
      seqName: generateSeqName(p.basename(sessionPath)),
      audioTrackPresent: await readAudioTrackPresent(sessionPath),
      confirmedAt: DateTime.now().toUtc(),
    );
    await writeForSession(sessionPath, created);
    return created;
  }

  Future<UploadSessionContext?> readForSession(String sessionPath) async {
    final file = File(p.join(sessionPath, UploadSessionContext.fileName));
    if (!await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final context = UploadSessionContext.fromJson(decoded.cast<String, dynamic>());
      if (!_isValidContext(context)) {
        return null;
      }
      return context;
    } catch (_) {
      return null;
    }
  }

  Future<UploadSessionContext?> readDefaults(String sessionPath) async {
    final file = File(p.join(_outputRootPath(sessionPath), _defaultsFileName));
    if (!await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final context = UploadSessionContext.fromJson(decoded.cast<String, dynamic>());
      if (!_isValidContext(context)) {
        return null;
      }
      return context;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeForSession(
    String sessionPath,
    UploadSessionContext context,
  ) async {
    if (!_isValidContext(context)) {
      throw const FormatException('Invalid upload session context.');
    }
    final file = File(p.join(sessionPath, UploadSessionContext.fileName));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(context.toJson()),
      flush: true,
    );

    final defaultsFile = File(p.join(_outputRootPath(sessionPath), _defaultsFileName));
    await defaultsFile.writeAsString(jsonEncode(context.toJson()), flush: true);
  }

  Future<bool> readAudioTrackPresent(String sessionPath) async {
    final file = File(p.join(sessionPath, 'metadata.json'));
    if (!await file.exists()) {
      return false;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return false;
      }
      return decoded['audio_track_present'] == true;
    } catch (_) {
      return false;
    }
  }

  String generateSceneName(String sessionName) {
    final suffix = _sessionTimestampSuffix(sessionName);
    return 'scene_$suffix';
  }

  String generateSeqName(String sessionName) {
    return 'seq0';
  }

  String generatePairGroupId(String sessionName) {
    final suffix = _sessionTimestampSuffix(sessionName);
    return 'group_$suffix';
  }

  bool isValidSegment(String value) {
    final trimmed = value.trim();
    return trimmed.isNotEmpty &&
        trimmed != '.' &&
        trimmed != '..' &&
        _allowedSegmentPattern.hasMatch(trimmed);
  }

  bool isValidSeqName(String value) {
    final trimmed = value.trim();
    return isValidSegment(trimmed) && _allowedSeqNamePattern.hasMatch(trimmed);
  }

  String normalizeSegment(String value) {
    final trimmed = value.trim();
    final normalized = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return normalized.replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  }

  bool _isValidContext(UploadSessionContext context) {
    if (!isValidSegment(context.sceneName) || !isValidSegment(context.seqName)) {
      return false;
    }
    if (context.captureType == UploadCaptureType.humanInScene) {
      if (!isValidSeqName(context.seqName)) {
        return false;
      }
      if (context.cam == null) {
        return false;
      }
    }

    if (context.captureType == UploadCaptureType.sceneOnly) {
      // scene-only ignores cam; keep it unset to avoid confusion.
      if (context.cam != null) {
        return false;
      }
    }

    if (context.captureName != null &&
        context.captureName!.isNotEmpty &&
        !isValidSegment(context.captureName!)) {
      return false;
    }
    if (context.pairGroupId != null &&
        context.pairGroupId!.isNotEmpty &&
        !isValidSegment(context.pairGroupId!)) {
      return false;
    }
    return true;
  }

  String _outputRootPath(String sessionPath) {
    return Directory(sessionPath).parent.path;
  }

  String _sessionTimestampSuffix(String sessionName) {
    final match = RegExp(
      r'(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})',
    ).firstMatch(sessionName);
    if (match != null) {
      return '${match.group(1)}${match.group(2)}${match.group(3)}_${match.group(4)}${match.group(5)}${match.group(6)}';
    }
    final now = DateTime.now();
    final safe = now.toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');
    return safe.substring(0, safe.length >= 14 ? 14 : safe.length);
  }
}
