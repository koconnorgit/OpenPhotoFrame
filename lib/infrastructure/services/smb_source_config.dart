enum SmbFolderSyncMode {
  all,
  selectedFolders,
}

/// Configuration for an SMB/CIFS network share photo source.
///
/// Mirrors [NextcloudSourceConfig]: the folder include/normalize rules are
/// identical, only the connection fields differ (host/share/path/credentials
/// instead of a public share URL).
class SmbSourceConfig {
  const SmbSourceConfig({
    this.host = '',
    this.share = '',
    this.path = '',
    this.domain = '',
    this.username = '',
    this.password = '',
    this.folderSyncMode = SmbFolderSyncMode.all,
    this.selectedFolders = const <String>[],
  });

  /// Server host or IP, e.g. "192.168.1.10" or "nas.local".
  final String host;

  /// Share name (first path component on the server), e.g. "photos".
  final String share;

  /// Optional sub-path inside the share, e.g. "albums/2024".
  final String path;

  /// Optional Windows/AD domain. Empty for most home setups.
  final String domain;

  /// Username. Empty enables guest/anonymous access.
  final String username;

  /// Password. Empty for guest or passwordless shares.
  final String password;

  final SmbFolderSyncMode folderSyncMode;
  final List<String> selectedFolders;

  factory SmbSourceConfig.fromMap(Map<String, dynamic> config) {
    final rawFolders = config['selected_folders'];

    return SmbSourceConfig(
      host: (config['host'] as String? ?? '').trim(),
      share: (config['share'] as String? ?? '').trim(),
      path: normalizeFolderPath(config['path'] as String? ?? ''),
      domain: (config['domain'] as String? ?? '').trim(),
      username: (config['username'] as String? ?? '').trim(),
      password: config['password'] as String? ?? '',
      folderSyncMode: (config['folder_sync_mode'] as String?) == 'selected'
          ? SmbFolderSyncMode.selectedFolders
          : SmbFolderSyncMode.all,
      selectedFolders: switch (rawFolders) {
        List<dynamic>() => rawFolders.map((entry) => '$entry').toList(),
        _ => const <String>[],
      },
    );
  }

  bool get syncAllFolders => folderSyncMode == SmbFolderSyncMode.all;

  /// True when enough is configured to attempt a connection.
  bool get isConfigured => host.isNotEmpty && share.isNotEmpty;

  Set<String> get normalizedSelectedFolders {
    final normalizedFolders = selectedFolders
        .map(normalizeFolderPath)
        .toSet();
    final includesRoot = selectedFolders.any(
      (folder) => normalizeFolderPath(folder).isEmpty,
    );
    if (!includesRoot) {
      normalizedFolders.remove('');
    }
    return normalizedFolders;
  }

  bool includesDirectory(String directoryPath) {
    if (syncAllFolders) {
      return true;
    }

    return normalizedSelectedFolders.contains(normalizeFolderPath(directoryPath));
  }

  bool includesRelativeFile(String relativePath) {
    return includesDirectory(parentDirectoryOf(relativePath));
  }

  SmbSourceConfig copyWith({
    String? host,
    String? share,
    String? path,
    String? domain,
    String? username,
    String? password,
    SmbFolderSyncMode? folderSyncMode,
    List<String>? selectedFolders,
  }) {
    return SmbSourceConfig(
      host: host ?? this.host,
      share: share ?? this.share,
      path: path ?? this.path,
      domain: domain ?? this.domain,
      username: username ?? this.username,
      password: password ?? this.password,
      folderSyncMode: folderSyncMode ?? this.folderSyncMode,
      selectedFolders: selectedFolders ?? this.selectedFolders,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'host': host,
      'share': share,
      'path': path,
      'domain': domain,
      'username': username,
      'password': password,
      'folder_sync_mode': switch (folderSyncMode) {
        SmbFolderSyncMode.all => 'all',
        SmbFolderSyncMode.selectedFolders => 'selected',
      },
      'selected_folders': normalizedSelectedFolders.toList()..sort(),
    };
  }

  static String normalizeFolderPath(String path) {
    var normalized = path.trim().replaceAll('\\', '/');
    if (normalized.isEmpty || normalized == '/') {
      return '';
    }

    while (normalized.contains('//')) {
      normalized = normalized.replaceAll('//', '/');
    }

    if (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String parentDirectoryOf(String relativePath) {
    final normalized = normalizeFolderPath(relativePath);
    final separatorIndex = normalized.lastIndexOf('/');
    if (separatorIndex == -1) {
      return '';
    }
    return normalized.substring(0, separatorIndex);
  }
}
