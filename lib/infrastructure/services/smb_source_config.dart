import 'folder_selection.dart';

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
    this.excludedFolders = const <String>[],
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

  /// Folders to sync. Each selected folder includes itself and all of its
  /// descendants, so subfolders added later sync automatically.
  final List<String> selectedFolders;

  /// Folders explicitly opted out of an otherwise-selected subtree.
  final List<String> excludedFolders;

  factory SmbSourceConfig.fromMap(Map<String, dynamic> config) {
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
      selectedFolders: _stringList(config['selected_folders']),
      excludedFolders: _stringList(config['excluded_folders']),
    );
  }

  static List<String> _stringList(Object? raw) {
    return switch (raw) {
      List<dynamic>() => raw.map((entry) => '$entry').toList(),
      _ => const <String>[],
    };
  }

  bool get syncAllFolders => folderSyncMode == SmbFolderSyncMode.all;

  /// True when enough is configured to attempt a connection.
  bool get isConfigured => host.isNotEmpty && share.isNotEmpty;

  Set<String> get normalizedSelectedFolders =>
      _normalizeFolderSet(selectedFolders);

  Set<String> get normalizedExcludedFolders =>
      _normalizeFolderSet(excludedFolders);

  static Set<String> _normalizeFolderSet(List<String> folders) {
    final normalized = folders.map(normalizeFolderPath).toSet();
    final includesRoot = folders.any(
      (folder) => normalizeFolderPath(folder).isEmpty,
    );
    if (!includesRoot) {
      normalized.remove('');
    }
    return normalized;
  }

  bool includesDirectory(String directoryPath) {
    return folderIsIncluded(
      normalizeFolderPath(directoryPath),
      selectedFolders: normalizedSelectedFolders,
      excludedFolders: normalizedExcludedFolders,
      syncAllFolders: syncAllFolders,
    );
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
    List<String>? excludedFolders,
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
      excludedFolders: excludedFolders ?? this.excludedFolders,
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
      'excluded_folders': normalizedExcludedFolders.toList()..sort(),
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
