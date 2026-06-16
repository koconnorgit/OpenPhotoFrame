/// Resolves hierarchical folder selection shared by the sync source configs.
///
/// A selected folder includes itself **and all of its descendants**, so a
/// subfolder added to a synced folder later is picked up automatically on the
/// next sync. An excluded folder opts a subtree back out.
///
/// Resolution is "nearest explicit ancestor wins": walking from
/// [directoryPath] up to the root, the first folder found in [excludedFolders]
/// excludes it, and the first found in [selectedFolders] includes it. When no
/// listed ancestor is found, [syncAllFolders] is the default — so a deeper
/// selection can re-include a subtree below an exclusion, and vice versa.
///
/// All paths must already be normalized (no leading/trailing slash; '' is the
/// root) — see each config's `normalizeFolderPath`.
bool folderIsIncluded(
  String directoryPath, {
  required Set<String> selectedFolders,
  required Set<String> excludedFolders,
  required bool syncAllFolders,
}) {
  var current = directoryPath;
  while (true) {
    if (excludedFolders.contains(current)) {
      return false;
    }
    if (selectedFolders.contains(current)) {
      return true;
    }
    if (current.isEmpty) {
      break;
    }
    final separatorIndex = current.lastIndexOf('/');
    current = separatorIndex == -1 ? '' : current.substring(0, separatorIndex);
  }
  return syncAllFolders;
}
