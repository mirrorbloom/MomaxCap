import 'dart:convert';

import 'upload_session_context.dart';

class UploadGroupShare {
  const UploadGroupShare({
    required this.captureType,
    required this.sceneName,
    required this.seqName,
    required this.pairGroupId,
    this.captureName,
  });

  static const String shareCodePrefix = 'sdrgrp1_';

  final String? captureName;
  final UploadCaptureType captureType;
  final String sceneName;
  final String seqName;
  final String pairGroupId;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': 1,
      'kind': 'group_share',
      if (captureName != null && captureName!.isNotEmpty)
        'captureName': captureName,
      'captureType': captureType.wireValue,
      'sceneName': sceneName,
      'seqName': seqName,
      'pairGroupId': pairGroupId,
    };
  }

  String toShareCode() {
    final payload = utf8.encode(jsonEncode(toJson()));
    return '$shareCodePrefix${base64Url.encode(payload)}';
  }

  UploadSessionContext applyTo(UploadSessionContext base) {
    return base.copyWith(
      captureName: captureName,
      captureType: captureType,
      sceneName: sceneName,
      seqName: seqName,
      pairGroupId: pairGroupId,
    );
  }

  factory UploadGroupShare.fromJson(Map<String, dynamic> json) {
    return UploadGroupShare(
      captureName: json['captureName'] as String?,
      captureType: UploadCaptureType.fromWireValue(
        json['captureType'] as String?,
      ),
      sceneName: (json['sceneName'] as String? ?? '').trim(),
      seqName: (json['seqName'] as String? ?? '').trim(),
      pairGroupId: (json['pairGroupId'] as String? ?? '').trim(),
    );
  }

  static UploadGroupShare? tryParse(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty || !trimmed.startsWith(shareCodePrefix)) {
      return null;
    }
    final encoded = trimmed.substring(shareCodePrefix.length);
    if (encoded.isEmpty) {
      return null;
    }
    try {
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(encoded)),
      );
      final json = jsonDecode(decoded);
      if (json is! Map) {
        return null;
      }
      final share = UploadGroupShare.fromJson(json.cast<String, dynamic>());
      if (share.sceneName.isEmpty ||
          share.seqName.isEmpty ||
          share.pairGroupId.isEmpty) {
        return null;
      }
      return share;
    } catch (_) {
      return null;
    }
  }
}
