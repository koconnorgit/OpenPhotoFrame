import 'dart:io';
import 'package:logging/logging.dart';
import '../../domain/interfaces/sync_provider.dart';
import '../../domain/interfaces/storage_provider.dart';
import 'image_converter.dart';
import 'smb_remote_client.dart';
import 'smb_source_config.dart';

/// A folder discovered on an SMB share, used by the settings folder picker.
class SmbFolder {
  const SmbFolder({
    required this.path,
    required this.depth,
  });

  final String path;
  final int depth;

  String get name {
    if (path.isEmpty) {
      return '';
    }
    final separatorIndex = path.lastIndexOf('/');
    if (separatorIndex == -1) {
      return path;
    }
    return path.substring(separatorIndex + 1);
  }
}

/// Syncs images from an SMB/CIFS network share into the local photo directory.
///
/// Mirrors [NextcloudSyncService]: recursively collects remote images, downloads
/// the missing ones (via a `.part` temp file), preserves modification times and
/// optionally prunes orphaned local files. Only the transport differs.
class SmbSyncService implements SyncProvider {
  final String host;
  final String share;
  final String path;
  final String domain;
  final String user;
  final String password;
  final StorageProvider _storageProvider;
  final SmbRemoteClientFactory _clientFactory;
  final SmbSourceConfig _sourceConfig;
  final ImageConverter _imageConverter;
  final _log = Logger('SmbSyncService');

  SmbSyncService({
    required this.host,
    required this.share,
    required StorageProvider storageProvider,
    this.path = '',
    this.domain = '',
    this.user = '',
    this.password = '',
    SmbRemoteClientFactory clientFactory = createSmbConnectRemoteClient,
    SmbSourceConfig sourceConfig = const SmbSourceConfig(),
    ImageConverter imageConverter = const FlutterImageConverter(),
  })  : _storageProvider = storageProvider,
        _clientFactory = clientFactory,
        _sourceConfig = sourceConfig,
        _imageConverter = imageConverter;

  /// Builds a service from a stored [SmbSourceConfig].
  factory SmbSyncService.fromConfig(
    SmbSourceConfig config,
    StorageProvider storageProvider, {
    SmbRemoteClientFactory clientFactory = createSmbConnectRemoteClient,
    ImageConverter imageConverter = const FlutterImageConverter(),
  }) {
    return SmbSyncService(
      host: config.host,
      share: config.share,
      path: config.path,
      domain: config.domain,
      user: config.username,
      password: config.password,
      storageProvider: storageProvider,
      clientFactory: clientFactory,
      sourceConfig: config,
      imageConverter: imageConverter,
    );
  }

  @override
  String get id => 'smb';

  /// Absolute SMB path to the configured base directory, e.g. `/photos/albums`.
  String get _baseRemotePath {
    final segments = <String>[share];
    if (path.isNotEmpty) {
      segments.add(path);
    }
    return '/${segments.join('/')}';
  }

  /// Tests the connection to the SMB share.
  /// Returns null on success, or an error message on failure.
  static Future<String?> testConnection(
    SmbSourceConfig config, {
    SmbRemoteClientFactory clientFactory = createSmbConnectRemoteClient,
  }) async {
    final log = Logger('SmbSyncService');

    if (config.host.isEmpty) {
      return 'Host is empty';
    }
    if (config.share.isEmpty) {
      return 'Share name is empty';
    }

    final service = SmbSyncService.fromConfig(config, _NullStorageProvider(),
        clientFactory: clientFactory);
    final client = clientFactory(
      host: config.host,
      domain: config.domain,
      username: config.username,
      password: config.password,
    );

    try {
      log.info('Testing connection to ${config.host} share "${config.share}"');
      // Reading the base directory validates host, share, auth and path.
      await client.readDir(service._baseRemotePath);
      log.info('Connection test successful');
      return null;
    } catch (e) {
      log.warning('Connection test failed: $e');
      final errorStr = e.toString();
      if (errorStr.contains('STATUS_LOGON_FAILURE') ||
          errorStr.contains('STATUS_ACCESS_DENIED')) {
        return 'Authentication failed (check username/password)';
      } else if (errorStr.contains('STATUS_BAD_NETWORK_NAME') ||
          errorStr.contains('STATUS_OBJECT_NAME_NOT_FOUND') ||
          errorStr.contains('STATUS_OBJECT_PATH_NOT_FOUND')) {
        return 'Share or path not found (check share name/path)';
      } else if (errorStr.contains('SocketException') ||
          errorStr.contains('Connection refused') ||
          errorStr.contains('timed out')) {
        return 'Could not connect (check host/network)';
      }
      return 'Connection failed: $e';
    } finally {
      await client.close();
    }
  }

  /// Lists folders available under the configured base path, for the picker.
  static Future<List<SmbFolder>> listAvailableFolders(
    SmbSourceConfig config, {
    SmbRemoteClientFactory clientFactory = createSmbConnectRemoteClient,
  }) async {
    final service = SmbSyncService.fromConfig(config, _NullStorageProvider(),
        clientFactory: clientFactory);
    final client = clientFactory(
      host: config.host,
      domain: config.domain,
      username: config.username,
      password: config.password,
    );

    try {
      final folders = <SmbFolder>[const SmbFolder(path: '', depth: 0)];
      folders.addAll(
        await _collectRemoteFolders(
          client,
          remoteDirectoryPath: service._baseRemotePath,
          relativeDirectoryPath: '',
        ),
      );
      folders.sort((left, right) => left.path.compareTo(right.path));
      return folders;
    } finally {
      await client.close();
    }
  }

  @override
  Future<void> sync({bool deleteOrphanedFiles = false}) async {
    _log.info(
        "Starting Sync from //$host/$share${path.isEmpty ? '' : '/$path'} (deleteOrphaned: $deleteOrphanedFiles)");

    final client = _clientFactory(
      host: host,
      domain: domain,
      username: user,
      password: password,
    );

    try {
      final localDir = await _storageProvider.getPhotoDirectory();
      _log.info("Syncing to local directory: ${localDir.path}");

      _log.info("Listing remote files...");
      final remoteFiles = await _collectRemoteImages(
        client,
        remoteDirectoryPath: _baseRemotePath,
        relativeDirectoryPath: '',
      );
      remoteFiles.sort((left, right) => left.relativePath.compareTo(right.relativePath));

      final pendingDownloads = <_RemoteImage>[];
      for (final remoteFile in remoteFiles) {
        final localFile = File('${localDir.path}/${remoteFile.localRelativePath}');
        if (!await localFile.exists()) {
          pendingDownloads.add(remoteFile);
        }
      }

      // Orphan pruning compares against the *local* paths, which differ from the
      // remote name for HEIC files that are converted to JPEG on download.
      final remoteRelativePaths = remoteFiles
          .map((remoteFile) => remoteFile.localRelativePath)
          .toSet();

      for (var index = 0; index < pendingDownloads.length; index++) {
        final remoteFile = pendingDownloads[index];
        final localFile = File('${localDir.path}/${remoteFile.localRelativePath}');

        _log.info(
          'Downloading ${index + 1}/${pendingDownloads.length}...',
        );

        await localFile.parent.create(recursive: true);
        final partFile = File('${localFile.path}.part');
        await partFile.parent.create(recursive: true);
        await client.downloadFile(remoteFile.remotePath, partFile.path);

        if (remoteFile.needsConversion) {
          final converted = await _imageConverter.convertToJpeg(
            partFile,
            localFile.path,
          );
          try {
            await partFile.delete();
          } catch (e) {
            _log.warning('Could not remove temp file ${partFile.path}: $e');
          }
          if (!converted) {
            _log.warning(
              'Skipping ${remoteFile.relativePath}: HEIC conversion failed',
            );
            continue;
          }
          if (remoteFile.modifiedAt != null) {
            try {
              await localFile.setLastModified(remoteFile.modifiedAt!);
            } catch (e) {
              _log.warning(
                'Could not set modification time for ${remoteFile.localRelativePath}: $e',
              );
            }
          }
          continue;
        }

        if (remoteFile.modifiedAt != null) {
          try {
            await partFile.setLastModified(remoteFile.modifiedAt!);
          } catch (e) {
            _log.warning(
              'Could not set modification time for ${remoteFile.relativePath}: $e',
            );
          }
        }

        await partFile.rename(localFile.path);
      }

      if (deleteOrphanedFiles) {
        await _deleteOrphanedLocalFiles(
          localDirectory: localDir,
          remoteRelativePaths: remoteRelativePaths,
        );
      }

      _log.info("Sync completed.");

    } catch (e) {
      _log.severe("Sync failed", e);
      rethrow;
    } finally {
      await client.close();
    }
  }

  bool _isImage(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
           lower.endsWith('.jpeg') ||
           lower.endsWith('.png') ||
           lower.endsWith('.webp') ||
           _isHeic(name);
  }

  /// HEIC/HEIF files cannot be decoded by Flutter's image stack, so they are
  /// transcoded to JPEG on download.
  static bool _isHeic(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.heic') || lower.endsWith('.heif');
  }

  /// Local path a remote image lands at. HEIC/HEIF sources get a `.jpg`
  /// extension because they are converted during download.
  static String _localRelativePathFor(String remoteRelativePath) {
    if (!_isHeic(remoteRelativePath)) {
      return remoteRelativePath;
    }
    final dotIndex = remoteRelativePath.lastIndexOf('.');
    return '${remoteRelativePath.substring(0, dotIndex)}.jpg';
  }

  Future<List<_RemoteImage>> _collectRemoteImages(
    SmbRemoteClient client, {
    required String remoteDirectoryPath,
    required String relativeDirectoryPath,
  }) async {
    final entries = await client.readDir(remoteDirectoryPath);
    final images = <_RemoteImage>[];

    for (final entry in entries) {
      final entryRelativePath = _joinRelativePath(relativeDirectoryPath, entry.name);
      if (entry.isDirectory) {
        images.addAll(
          await _collectRemoteImages(
            client,
            remoteDirectoryPath: entry.path,
            relativeDirectoryPath: entryRelativePath,
          ),
        );
        continue;
      }

      if (!_isImage(entry.name) || !_sourceConfig.includesRelativeFile(entryRelativePath)) {
        continue;
      }

      images.add(
        _RemoteImage(
          remotePath: entry.path,
          relativePath: entryRelativePath,
          localRelativePath: _localRelativePathFor(entryRelativePath),
          needsConversion: _isHeic(entry.name),
          modifiedAt: entry.modifiedAt,
        ),
      );
    }

    return images;
  }

  Future<void> _deleteOrphanedLocalFiles({
    required Directory localDirectory,
    required Set<String> remoteRelativePaths,
  }) async {
    _log.info('Checking for orphaned local files...');
    final localEntities = await localDirectory.list(recursive: true, followLinks: false).toList();

    for (final entity in localEntities.whereType<File>()) {
      final relativePath = _relativePathFromLocalFile(localDirectory, entity);
      if (!_isImage(relativePath) || relativePath.endsWith('.part')) {
        continue;
      }

      if (remoteRelativePaths.contains(relativePath)) {
        continue;
      }

      _log.info('Deleting orphaned file: $relativePath');
      try {
        await entity.delete();
      } catch (e) {
        _log.warning('Failed to delete orphaned file $relativePath: $e');
      }
    }

    final directories = localEntities.whereType<Directory>().toList()
      ..sort((left, right) => right.path.length.compareTo(left.path.length));
    for (final directory in directories) {
      if (directory.path == localDirectory.path || !await directory.exists()) {
        continue;
      }

      if (await directory.list(followLinks: false).isEmpty) {
        await directory.delete();
      }
    }
  }

  static Future<List<SmbFolder>> _collectRemoteFolders(
    SmbRemoteClient client, {
    required String remoteDirectoryPath,
    required String relativeDirectoryPath,
  }) async {
    final entries = await client.readDir(remoteDirectoryPath);
    final folders = <SmbFolder>[];

    for (final entry in entries) {
      if (!entry.isDirectory) {
        continue;
      }

      final folderPath = _joinRelativePath(relativeDirectoryPath, entry.name);
      folders.add(
        SmbFolder(
          path: folderPath,
          depth: folderPath.isEmpty ? 0 : folderPath.split('/').length,
        ),
      );
      folders.addAll(
        await _collectRemoteFolders(
          client,
          remoteDirectoryPath: entry.path,
          relativeDirectoryPath: folderPath,
        ),
      );
    }

    return folders;
  }

  static String _joinRelativePath(String directoryPath, String name) {
    final normalizedDirectory = SmbSourceConfig.normalizeFolderPath(directoryPath);
    if (normalizedDirectory.isEmpty) {
      return name;
    }
    return '$normalizedDirectory/$name';
  }

  static String _relativePathFromLocalFile(Directory baseDirectory, File file) {
    var relativePath = file.path.substring(baseDirectory.path.length);
    if (relativePath.startsWith(Platform.pathSeparator)) {
      relativePath = relativePath.substring(1);
    }
    return relativePath.replaceAll('\\', '/');
  }
}

class _RemoteImage {
  const _RemoteImage({
    required this.remotePath,
    required this.relativePath,
    required this.localRelativePath,
    required this.needsConversion,
    this.modifiedAt,
  });

  final String remotePath;

  /// Path of the file on the remote share, relative to the base directory.
  final String relativePath;

  /// Path the file is stored at locally; matches [relativePath] except for
  /// HEIC/HEIF sources, which are converted to `.jpg`.
  final String localRelativePath;

  /// Whether the downloaded bytes need transcoding to JPEG before display.
  final bool needsConversion;

  final DateTime? modifiedAt;
}

/// Minimal [StorageProvider] used by the static connection/folder helpers,
/// which never touch local storage.
class _NullStorageProvider implements StorageProvider {
  @override
  Future<Directory> getPhotoDirectory() async => Directory.systemTemp;

  @override
  bool get isReadOnly => true;

  @override
  Stream<void> get onDirectoryChanged => const Stream.empty();
}
