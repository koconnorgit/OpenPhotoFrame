import 'folder_selection.dart';

enum NextcloudFolderSyncMode {
  all,
  selectedFolders,
}

class NextcloudSourceConfig {
  const NextcloudSourceConfig({
    this.url = '',
    this.folderSyncMode = NextcloudFolderSyncMode.all,
    this.selectedFolders = const <String>[],
    this.excludedFolders = const <String>[],
  });

  final String url;
  final NextcloudFolderSyncMode folderSyncMode;

  /// Folders to sync. Each selected folder includes itself and all of its
  /// descendants, so subfolders added later sync automatically.
  final List<String> selectedFolders;

  /// Folders explicitly opted out of an otherwise-selected subtree.
  final List<String> excludedFolders;

  factory NextcloudSourceConfig.fromMap(Map<String, dynamic> config) {
    return NextcloudSourceConfig(
      url: (config['url'] as String? ?? '').trim(),
      folderSyncMode: (config['folder_sync_mode'] as String?) == 'selected'
          ? NextcloudFolderSyncMode.selectedFolders
          : NextcloudFolderSyncMode.all,
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

  bool get syncAllFolders => folderSyncMode == NextcloudFolderSyncMode.all;

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

  NextcloudSourceConfig copyWith({
    String? url,
    NextcloudFolderSyncMode? folderSyncMode,
    List<String>? selectedFolders,
    List<String>? excludedFolders,
  }) {
    return NextcloudSourceConfig(
      url: url ?? this.url,
      folderSyncMode: folderSyncMode ?? this.folderSyncMode,
      selectedFolders: selectedFolders ?? this.selectedFolders,
      excludedFolders: excludedFolders ?? this.excludedFolders,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'folder_sync_mode': switch (folderSyncMode) {
        NextcloudFolderSyncMode.all => 'all',
        NextcloudFolderSyncMode.selectedFolders => 'selected',
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