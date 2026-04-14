import 'package:flutter_test/flutter_test.dart';
import 'package:spatial_data_recorder/core/upload/models/upload_group_share.dart';
import 'package:spatial_data_recorder/core/upload/models/upload_session_context.dart';

void main() {
  test('share code round trip preserves grouping fields', () {
    const share = UploadGroupShare(
      captureType: UploadCaptureType.humanInScene,
      sceneName: 'scene_20260414_183835',
      seqName: 'seq0',
      pairGroupId: 'group_20260414_183835',
      captureName: 'ios_capture',
    );

    final shareCode = share.toShareCode();
    final decoded = UploadGroupShare.tryParse(shareCode);

    expect(decoded, isNotNull);
    expect(decoded!.captureType, UploadCaptureType.humanInScene);
    expect(decoded.captureName, 'ios_capture');
    expect(decoded.sceneName, 'scene_20260414_183835');
    expect(decoded.seqName, 'seq0');
    expect(decoded.pairGroupId, 'group_20260414_183835');
  });

  test('invalid share code returns null', () {
    expect(UploadGroupShare.tryParse('group_only'), isNull);
    expect(UploadGroupShare.tryParse('sdrgrp1_invalid_payload'), isNull);
  });
}
