class UploadManifestEntry {
  const UploadManifestEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.sizeBytes,
  });

  final String absolutePath;
  final String relativePath;
  final int sizeBytes;
}

class SessionUploadManifest {
  const SessionUploadManifest({
    required this.sessionPath,
    required this.sessionName,
    required this.entries,
    required this.totalSizeBytes,
  });

  final String sessionPath;
  final String sessionName;
  final List<UploadManifestEntry> entries;
  final int totalSizeBytes;

  int get fileCount => entries.length;
}
