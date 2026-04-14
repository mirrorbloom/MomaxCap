import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/upload/models/upload_group_share.dart';
import '../../core/upload/models/upload_session_context.dart';
import '../../core/upload/services/upload_session_context_service.dart';

Future<UploadSessionContext?> showUploadSessionContextDialog({
  required BuildContext context,
  required String sessionPath,
  required UploadSessionContextService contextService,
}) async {
  final existing = await contextService.readForSession(sessionPath);
  final defaults = await contextService.readDefaults(sessionPath);
  final audioTrackPresent = await contextService.readAudioTrackPresent(
    sessionPath,
  );
  if (!context.mounted) {
    return null;
  }

  return showDialog<UploadSessionContext>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return _UploadSessionContextDialog(
        sessionName: p.basename(sessionPath),
        existing: existing,
        defaults: defaults,
        audioTrackPresent: audioTrackPresent,
        contextService: contextService,
      );
    },
  );
}

class _UploadSessionContextDialog extends StatefulWidget {
  const _UploadSessionContextDialog({
    required this.sessionName,
    required this.existing,
    required this.defaults,
    required this.audioTrackPresent,
    required this.contextService,
  });

  final String sessionName;
  final UploadSessionContext? existing;
  final UploadSessionContext? defaults;
  final bool audioTrackPresent;
  final UploadSessionContextService contextService;

  @override
  State<_UploadSessionContextDialog> createState() =>
      _UploadSessionContextDialogState();
}

class _UploadSessionContextDialogState
    extends State<_UploadSessionContextDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _sceneController;
  late final TextEditingController _seqController;
  late final TextEditingController _groupController;
  late final TextEditingController _shareCodeController;

  late UploadCaptureType _captureType;
  late bool _reuseRecentScene;
  late bool _reuseRecentSeq;
  late bool _groupEnabled;
  late bool _reuseRecentGroup;
  late _GroupJoinMode _groupJoinMode;
  UploadGroupShare? _sharedJoinConfig;

  UploadSessionContext? get _defaults => widget.defaults;
  bool get _hasRecentScene =>
      _defaults != null && _defaults!.sceneName.isNotEmpty;
  bool get _hasRecentSeq => _defaults != null && _defaults!.seqName.isNotEmpty;
  bool get _hasRecentGroup =>
      _defaults != null &&
      _defaults!.pairGroupId != null &&
      _defaults!.pairGroupId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final seed = widget.existing ?? widget.defaults;
    _captureType = seed?.captureType ?? UploadCaptureType.sceneOnly;
    _sceneController = TextEditingController(
      text: widget.existing?.sceneName ?? '',
    );
    _seqController = TextEditingController(
      text: widget.existing?.seqName ?? '',
    );
    _groupController = TextEditingController(
      text: widget.existing?.pairGroupId ?? '',
    );
    _shareCodeController = TextEditingController();
    _reuseRecentScene = false;
    _reuseRecentSeq = false;
    _groupEnabled = widget.existing?.isGrouped ?? false;
    _reuseRecentGroup = false;
    _groupJoinMode = _GroupJoinMode.manualGroupId;
  }

  @override
  void dispose() {
    _sceneController.dispose();
    _seqController.dispose();
    _groupController.dispose();
    _shareCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('上传设置'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.sessionName,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<UploadCaptureType>(
                  value: _captureType,
                  decoration: const InputDecoration(
                    labelText: '场景类型',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: UploadCaptureType.sceneOnly,
                      child: Text('纯场景'),
                    ),
                    DropdownMenuItem(
                      value: UploadCaptureType.humanInScene,
                      child: Text('带人'),
                    ),
                  ],
                  onChanged: _sharedJoinConfig != null
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _captureType = value;
                          });
                        },
                ),
                const SizedBox(height: 12),
                if (_hasRecentScene)
                  SwitchListTile(
                    value: _reuseRecentScene,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('沿用最近 Scene'),
                    subtitle: Text(_defaults!.sceneName),
                    onChanged: (value) {
                      setState(() {
                        _reuseRecentScene = value;
                        if (value) {
                          _sharedJoinConfig = null;
                        }
                      });
                    },
                  ),
                TextFormField(
                  controller: _sceneController,
                  enabled: !_reuseRecentScene && _sharedJoinConfig == null,
                  decoration: InputDecoration(
                    labelText: 'Scene 名称',
                    hintText: widget.contextService.generateSceneName(
                      widget.sessionName,
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (_reuseRecentScene || _sharedJoinConfig != null) {
                      return null;
                    }
                    final trimmed = value?.trim() ?? '';
                    if (trimmed.isEmpty) {
                      return null;
                    }
                    if (!widget.contextService.isValidSegment(trimmed)) {
                      return '仅支持字母、数字、点、下划线、短横线';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                if (_hasRecentSeq)
                  SwitchListTile(
                    value: _reuseRecentSeq,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('沿用最近 Seq'),
                    subtitle: Text(_defaults!.seqName),
                    onChanged: (value) {
                      setState(() {
                        _reuseRecentSeq = value;
                        if (value) {
                          _sharedJoinConfig = null;
                        }
                      });
                    },
                  ),
                TextFormField(
                  controller: _seqController,
                  enabled: !_reuseRecentSeq && _sharedJoinConfig == null,
                  decoration: InputDecoration(
                    labelText: 'Seq 名称',
                    hintText: widget.contextService.generateSeqName(
                      widget.sessionName,
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (_reuseRecentSeq || _sharedJoinConfig != null) {
                      return null;
                    }
                    final trimmed = value?.trim() ?? '';
                    if (trimmed.isEmpty) {
                      return null;
                    }
                    if (!widget.contextService.isValidSegment(trimmed)) {
                      return '仅支持字母、数字、点、下划线、短横线';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _groupEnabled,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('标记为同组拍摄'),
                  subtitle: const Text('同组视频会共享同一个 groupId'),
                  onChanged: (value) {
                    setState(() {
                      _groupEnabled = value;
                      if (!value) {
                        _reuseRecentGroup = false;
                        _sharedJoinConfig = null;
                      }
                    });
                  },
                ),
                if (_groupEnabled)
                  DropdownButtonFormField<_GroupJoinMode>(
                    value: _groupJoinMode,
                    decoration: const InputDecoration(
                      labelText: '加入方式',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: _GroupJoinMode.manualGroupId,
                        child: Text('手动输入组号'),
                      ),
                      DropdownMenuItem(
                        value: _GroupJoinMode.shareCode,
                        child: Text('输入共享码或扫码'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _groupJoinMode = value;
                        _reuseRecentGroup = false;
                        _sharedJoinConfig = null;
                        _shareCodeController.clear();
                      });
                    },
                  ),
                if (_groupEnabled) const SizedBox(height: 12),
                if (_groupEnabled && _hasRecentGroup)
                  SwitchListTile(
                    value: _reuseRecentGroup,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('沿用最近 Group'),
                    subtitle: Text(_defaults!.pairGroupId!),
                    onChanged: (value) {
                      setState(() {
                        _reuseRecentGroup = value;
                        if (value) {
                          _sharedJoinConfig = null;
                          _shareCodeController.clear();
                        }
                      });
                    },
                  ),
                if (_groupEnabled &&
                    !_reuseRecentGroup &&
                    _groupJoinMode == _GroupJoinMode.manualGroupId)
                  TextFormField(
                    controller: _groupController,
                    enabled: true,
                    decoration: InputDecoration(
                      labelText: 'Group ID',
                      hintText: widget.contextService.generatePairGroupId(
                        widget.sessionName,
                      ),
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (!_groupEnabled ||
                          _reuseRecentGroup ||
                          _groupJoinMode != _GroupJoinMode.manualGroupId) {
                        return null;
                      }
                      final trimmed = value?.trim() ?? '';
                      if (trimmed.isEmpty) {
                        return null;
                      }
                      if (!widget.contextService.isValidSegment(trimmed)) {
                        return '仅支持字母、数字、点、下划线、短横线';
                      }
                      return null;
                    },
                  ),
                if (_groupEnabled &&
                    !_reuseRecentGroup &&
                    _groupJoinMode == _GroupJoinMode.shareCode)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _shareCodeController,
                        decoration: const InputDecoration(
                          labelText: '共享码',
                          hintText: '输入共享码，或点击扫码导入',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (!_groupEnabled ||
                              _reuseRecentGroup ||
                              _groupJoinMode != _GroupJoinMode.shareCode) {
                            return null;
                          }
                          final trimmed = value?.trim() ?? '';
                          if (_sharedJoinConfig != null) {
                            return null;
                          }
                          if (trimmed.isEmpty) {
                            return '请输入共享码或使用扫码';
                          }
                          if (UploadGroupShare.tryParse(trimmed) == null) {
                            return '共享码格式无效';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: _applyShareCodeFromInput,
                            icon: const Icon(Icons.login),
                            label: const Text('导入共享码'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _scanShareCode,
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('扫码导入'),
                          ),
                        ],
                      ),
                    ],
                  ),
                if (_sharedJoinConfig != null) ...[
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blueGrey.shade200),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('已导入共享配置'),
                          const SizedBox(height: 6),
                          Text('Scene: ${_sharedJoinConfig!.sceneName}'),
                          Text('Seq: ${_sharedJoinConfig!.seqName}'),
                          Text('Group: ${_sharedJoinConfig!.pairGroupId}'),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _sharedJoinConfig = null;
                                _shareCodeController.clear();
                              });
                            },
                            child: const Text('清除共享配置'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_groupEnabled) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _showShareQrCode,
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('显示共享二维码'),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('音频状态'),
                  subtitle: Text(
                    widget.audioTrackPresent ? '本次录制已包含音频' : '本次录制无音频，但允许继续上传',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('仅保存'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确认并上传')),
      ],
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    UploadGroupShare? shareConfig = _sharedJoinConfig;
    if (_groupEnabled &&
        !_reuseRecentGroup &&
        _groupJoinMode == _GroupJoinMode.shareCode &&
        shareConfig == null) {
      shareConfig = UploadGroupShare.tryParse(_shareCodeController.text);
    }

    final sceneName =
        shareConfig?.sceneName ??
        (_reuseRecentScene && _hasRecentScene
            ? _defaults!.sceneName
            : _resolveOrGenerate(
                _sceneController.text,
                widget.contextService.generateSceneName(widget.sessionName),
              ));
    final seqName =
        shareConfig?.seqName ??
        (_reuseRecentSeq && _hasRecentSeq
            ? _defaults!.seqName
            : _resolveOrGenerate(
                _seqController.text,
                widget.contextService.generateSeqName(widget.sessionName),
              ));
    final pairGroupId = !_groupEnabled
        ? null
        : (shareConfig?.pairGroupId ??
              (_reuseRecentGroup && _hasRecentGroup
                  ? _defaults!.pairGroupId
                  : _resolveOrGenerate(
                      _groupController.text,
                      widget.contextService.generatePairGroupId(
                        widget.sessionName,
                      ),
                    )));

    final sessionContext = UploadSessionContext(
      captureName: shareConfig?.captureName,
      captureType: shareConfig?.captureType ?? _captureType,
      sceneName: sceneName,
      seqName: seqName,
      pairGroupId: pairGroupId,
      audioTrackPresent: widget.audioTrackPresent,
      confirmedAt: DateTime.now().toUtc(),
    );
    Navigator.of(context).pop(sessionContext);
  }

  String _resolveOrGenerate(String rawValue, String generatedFallback) {
    final normalized = widget.contextService.normalizeSegment(rawValue);
    if (normalized.isNotEmpty) {
      return normalized;
    }
    return generatedFallback;
  }

  void _applyShareCodeFromInput() {
    final share = UploadGroupShare.tryParse(_shareCodeController.text);
    if (share == null) {
      _showMessage('共享码格式无效。');
      return;
    }
    _applySharedJoinConfig(share, rawCode: _shareCodeController.text.trim());
  }

  Future<void> _scanShareCode() async {
    final rawCode = await showDialog<String>(
      context: context,
      builder: (_) => const _GroupShareScannerDialog(),
    );
    if (!mounted || rawCode == null || rawCode.trim().isEmpty) {
      return;
    }
    final share = UploadGroupShare.tryParse(rawCode);
    if (share == null) {
      _showMessage('扫码内容不是有效的共享码。');
      return;
    }
    _applySharedJoinConfig(share, rawCode: rawCode);
  }

  void _applySharedJoinConfig(
    UploadGroupShare share, {
    required String rawCode,
  }) {
    setState(() {
      _sharedJoinConfig = share;
      _captureType = share.captureType;
      _sceneController.text = share.sceneName;
      _seqController.text = share.seqName;
      _groupController.text = share.pairGroupId;
      _shareCodeController.text = rawCode.trim();
      _reuseRecentGroup = false;
      _reuseRecentScene = false;
      _reuseRecentSeq = false;
      _groupEnabled = true;
      _groupJoinMode = _GroupJoinMode.shareCode;
    });
  }

  Future<void> _showShareQrCode() async {
    final share = _buildCurrentShare();
    if (share == null) {
      _showMessage('当前分组信息无效，无法生成共享二维码。');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _GroupShareQrDialog(share: share),
    );
  }

  UploadGroupShare? _buildCurrentShare() {
    if (!_groupEnabled) {
      return null;
    }
    final sceneName =
        _sharedJoinConfig?.sceneName ??
        (_reuseRecentScene && _hasRecentScene
            ? _defaults!.sceneName
            : _resolveOrGenerate(
                _sceneController.text,
                widget.contextService.generateSceneName(widget.sessionName),
              ));
    final seqName =
        _sharedJoinConfig?.seqName ??
        (_reuseRecentSeq && _hasRecentSeq
            ? _defaults!.seqName
            : _resolveOrGenerate(
                _seqController.text,
                widget.contextService.generateSeqName(widget.sessionName),
              ));
    final pairGroupId =
        _sharedJoinConfig?.pairGroupId ??
        (_reuseRecentGroup && _hasRecentGroup
            ? _defaults!.pairGroupId
            : _resolveOrGenerate(
                _groupController.text,
                widget.contextService.generatePairGroupId(widget.sessionName),
              ));

    if (!widget.contextService.isValidSegment(sceneName) ||
        !widget.contextService.isValidSegment(seqName) ||
        pairGroupId == null ||
        !widget.contextService.isValidSegment(pairGroupId)) {
      return null;
    }
    return UploadGroupShare(
      captureType: _sharedJoinConfig?.captureType ?? _captureType,
      sceneName: sceneName,
      seqName: seqName,
      pairGroupId: pairGroupId,
    );
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _GroupJoinMode { manualGroupId, shareCode }

class _GroupShareQrDialog extends StatelessWidget {
  const _GroupShareQrDialog({required this.share});

  final UploadGroupShare share;

  @override
  Widget build(BuildContext context) {
    final shareCode = share.toShareCode();
    return AlertDialog(
      title: const Text('共享二维码'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: QrImageView(data: shareCode, size: 220)),
            const SizedBox(height: 12),
            Text('Scene: ${share.sceneName}'),
            Text('Seq: ${share.seqName}'),
            Text('Group: ${share.pairGroupId}'),
            const SizedBox(height: 12),
            SelectableText(
              shareCode,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: shareCode));
            if (!context.mounted) return;
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(const SnackBar(content: Text('共享码已复制。')));
          },
          child: const Text('复制共享码'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _GroupShareScannerDialog extends StatefulWidget {
  const _GroupShareScannerDialog();

  @override
  State<_GroupShareScannerDialog> createState() =>
      _GroupShareScannerDialogState();
}

class _GroupShareScannerDialogState extends State<_GroupShareScannerDialog> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('扫码加入同步组'),
      content: SizedBox(
        width: 320,
        height: 320,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: MobileScanner(
            onDetect: (capture) {
              if (_handled) {
                return;
              }
              final value = capture.barcodes
                  .map((code) => code.rawValue)
                  .whereType<String>()
                  .firstWhere((raw) => raw.trim().isNotEmpty, orElse: () => '');
              if (value.isEmpty) {
                return;
              }
              _handled = true;
              Navigator.of(context).pop(value);
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
