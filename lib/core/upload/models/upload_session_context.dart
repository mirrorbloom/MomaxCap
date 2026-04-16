enum UploadCaptureType {
  sceneOnly,
  humanInScene;

  String get wireValue {
    switch (this) {
      case UploadCaptureType.sceneOnly:
        return 'scene_only';
      case UploadCaptureType.humanInScene:
        return 'human_in_scene';
    }
  }

  static UploadCaptureType fromWireValue(String? value) {
    switch (value) {
      case 'human_in_scene':
        return UploadCaptureType.humanInScene;
      case 'scene_only':
      default:
        return UploadCaptureType.sceneOnly;
    }
  }
}

enum UploadCam {
  A,
  B;

  String get wireValue {
    switch (this) {
      case UploadCam.A:
        return 'A';
      case UploadCam.B:
        return 'B';
    }
  }

  static UploadCam? fromWireValue(String? value) {
    final normalized = (value ?? '').trim().toUpperCase();
    switch (normalized) {
      case 'A':
      case 'L':
      case '1':
        return UploadCam.A;
      case 'B':
      case 'R':
      case '2':
        return UploadCam.B;
    }
    return null;
  }
}

class UploadSessionContext {
  const UploadSessionContext({
    required this.captureType,
    required this.sceneName,
    required this.seqName,
    required this.audioTrackPresent,
    required this.confirmedAt,
    this.captureName,
    this.cam,
    this.pairGroupId,
  });

  static const fileName = 'upload_context.json';

  final String? captureName;
  final UploadCaptureType captureType;
  final String sceneName;
  final String seqName;
  final UploadCam? cam;
  final String? pairGroupId;
  final bool audioTrackPresent;
  final DateTime confirmedAt;

  bool get isGrouped => pairGroupId != null && pairGroupId!.isNotEmpty;

  UploadSessionContext copyWith({
    String? captureName,
    bool clearCaptureName = false,
    UploadCaptureType? captureType,
    String? sceneName,
    String? seqName,
    UploadCam? cam,
    bool clearCam = false,
    String? pairGroupId,
    bool clearPairGroupId = false,
    bool? audioTrackPresent,
    DateTime? confirmedAt,
  }) {
    return UploadSessionContext(
      captureName: clearCaptureName ? null : (captureName ?? this.captureName),
      captureType: captureType ?? this.captureType,
      sceneName: sceneName ?? this.sceneName,
      seqName: seqName ?? this.seqName,
      cam: clearCam ? null : (cam ?? this.cam),
      pairGroupId: clearPairGroupId ? null : (pairGroupId ?? this.pairGroupId),
      audioTrackPresent: audioTrackPresent ?? this.audioTrackPresent,
      confirmedAt: confirmedAt ?? this.confirmedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': 1,
      if (captureName != null && captureName!.isNotEmpty)
        'captureName': captureName,
      'captureType': captureType.wireValue,
      'sceneName': sceneName,
      'seqName': seqName,
      if (cam != null) 'cam': cam!.wireValue,
      if (pairGroupId != null && pairGroupId!.isNotEmpty)
        'pairGroupId': pairGroupId,
      'audioTrackPresent': audioTrackPresent,
      'confirmedAt': confirmedAt.toUtc().toIso8601String(),
    };
  }

  factory UploadSessionContext.fromJson(Map<String, dynamic> json) {
    return UploadSessionContext(
      captureName: json['captureName'] as String?,
      captureType: UploadCaptureType.fromWireValue(
        json['captureType'] as String?,
      ),
      sceneName: (json['sceneName'] as String? ?? '').trim(),
      seqName: (json['seqName'] as String? ?? '').trim(),
      cam: UploadCam.fromWireValue(json['cam'] as String?),
      pairGroupId: (json['pairGroupId'] as String?)?.trim(),
      audioTrackPresent: json['audioTrackPresent'] == true,
      confirmedAt:
          DateTime.tryParse(json['confirmedAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}
