import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_photo_frame/domain/interfaces/storage_provider.dart';
import 'package:open_photo_frame/infrastructure/services/image_converter.dart';
import 'package:open_photo_frame/infrastructure/services/smb_remote_client.dart';
import 'package:open_photo_frame/infrastructure/services/smb_source_config.dart';
import 'package:open_photo_frame/infrastructure/services/smb_sync_service.dart';

class FakeStorageProvider implements StorageProvider {
  FakeStorageProvider(this.directory);

  final Directory directory;

  @override
  Future<Directory> getPhotoDirectory() async => directory;

  @override
  bool get isReadOnly => false;

  @override
  Stream<void> get onDirectoryChanged => const Stream.empty();
}

class FakeSmbRemoteClient implements SmbRemoteClient {
  FakeSmbRemoteClient({
    Map<String, List<SmbRemoteEntry>> directories = const {},
    Map<String, List<int>> fileContents = const {},
    this.readDirError,
  })  : _directories = directories,
        _fileContents = fileContents;

  final Map<String, List<SmbRemoteEntry>> _directories;
  final Map<String, List<int>> _fileContents;
  final Object? readDirError;
  final List<String> readDirCalls = [];
  final List<String> downloadedPaths = [];
  bool closed = false;

  @override
  Future<List<SmbRemoteEntry>> readDir(String path) async {
    readDirCalls.add(path);
    if (readDirError != null) {
      throw readDirError!;
    }
    return List<SmbRemoteEntry>.from(_directories[path] ?? const []);
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath) async {
    downloadedPaths.add(remotePath);
    final file = File(localPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      _fileContents[remotePath] ?? utf8.encode('download:$remotePath'),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// Stand-in for the real (platform-channel-backed) converter. Writes a JPEG
/// placeholder so the on-disk result looks like a successful transcode.
class FakeImageConverter implements ImageConverter {
  FakeImageConverter({this.succeed = true});

  final bool succeed;
  final List<String> targets = [];

  @override
  Future<bool> convertToJpeg(File sourceFile, String targetPath) async {
    targets.add(targetPath);
    if (!succeed) {
      return false;
    }
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(utf8.encode('jpeg:${sourceFile.path}'));
    return true;
  }
}

void main() {
  group('SmbSourceConfig', () {
    test('round-trips connection fields and normalizes folders', () {
      final config = SmbSourceConfig.fromMap({
        'host': ' 192.168.1.10 ',
        'share': 'photos',
        'path': '/albums/2024/',
        'username': 'frame',
        'password': 'secret',
        'folder_sync_mode': 'selected',
        'selected_folders': ['/', 'albums//summer/'],
        'excluded_folders': ['albums/summer/private/'],
      });

      expect(config.host, '192.168.1.10');
      expect(config.share, 'photos');
      expect(config.path, 'albums/2024');
      expect(config.username, 'frame');
      expect(config.password, 'secret');
      expect(config.isConfigured, isTrue);
      expect(config.syncAllFolders, isFalse);
      expect(config.normalizedSelectedFolders, {'', 'albums/summer'});
      expect(config.normalizedExcludedFolders, {'albums/summer/private'});
      // Root is selected, so everything syncs except the excluded subtree.
      expect(config.includesRelativeFile('albums/photo.jpg'), isTrue);
      expect(config.includesRelativeFile('albums/summer/private/x.jpg'), isFalse);

      final restored = SmbSourceConfig.fromMap(config.toMap());
      expect(restored.host, config.host);
      expect(restored.path, config.path);
      expect(restored.normalizedSelectedFolders, config.normalizedSelectedFolders);
      expect(restored.normalizedExcludedFolders, config.normalizedExcludedFolders);
    });

    test('selecting a folder includes its subfolders, with opt-out exclusions',
        () {
      const config = SmbSourceConfig(
        host: '192.168.1.10',
        share: 'photos',
        folderSyncMode: SmbFolderSyncMode.selectedFolders,
        selectedFolders: ['albums'],
        excludedFolders: ['albums/2024/private'],
      );

      // A subfolder added under a selected folder is synced automatically.
      expect(config.includesRelativeFile('albums/2024/photo.jpg'), isTrue);
      expect(config.includesRelativeFile('albums/2025/new/photo.jpg'), isTrue);
      // The excluded subtree is skipped...
      expect(config.includesRelativeFile('albums/2024/private/photo.jpg'), isFalse);
      // ...while its siblings still sync.
      expect(config.includesRelativeFile('albums/2024/public/photo.jpg'), isTrue);
      // Folders outside the selection are not synced.
      expect(config.includesRelativeFile('other/photo.jpg'), isFalse);
    });

    test('a deeper selection re-includes below an exclusion', () {
      const config = SmbSourceConfig(
        host: '192.168.1.10',
        share: 'photos',
        folderSyncMode: SmbFolderSyncMode.selectedFolders,
        selectedFolders: ['albums', 'albums/2024/private/public'],
        excludedFolders: ['albums/2024/private'],
      );

      expect(config.includesRelativeFile('albums/2024/private/x.jpg'), isFalse);
      expect(
        config.includesRelativeFile('albums/2024/private/public/x.jpg'),
        isTrue,
      );
    });

    test('is not configured without host and share', () {
      expect(const SmbSourceConfig(host: '10.0.0.1').isConfigured, isFalse);
      expect(const SmbSourceConfig(share: 'photos').isConfigured, isFalse);
    });
  });

  group('SmbSyncService', () {
    late Directory tempDir;
    late FakeStorageProvider storageProvider;

    SmbRemoteClientFactory factoryFor(FakeSmbRemoteClient client) {
      return ({
        required String host,
        required String domain,
        required String username,
        required String password,
      }) =>
          client;
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('smb_sync_test_');
      storageProvider = FakeStorageProvider(tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('testConnection reads the base path and closes the client', () async {
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/folder',
              name: 'folder',
              isDirectory: true,
            ),
          ],
        },
      );

      final error = await SmbSyncService.testConnection(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        clientFactory: factoryFor(client),
      );

      expect(error, isNull);
      expect(client.readDirCalls, ['/photos']);
      expect(client.closed, isTrue);
    });

    test('listAvailableFolders returns root and nested folders', () async {
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/albums',
              name: 'albums',
              isDirectory: true,
            ),
            SmbRemoteEntry(
              path: '/photos/cover.jpg',
              name: 'cover.jpg',
              isDirectory: false,
            ),
          ],
          '/photos/albums': const [
            SmbRemoteEntry(
              path: '/photos/albums/summer',
              name: 'summer',
              isDirectory: true,
            ),
          ],
          '/photos/albums/summer': const [],
        },
      );

      final folders = await SmbSyncService.listAvailableFolders(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        clientFactory: factoryFor(client),
      );

      expect(folders.map((folder) => folder.path), ['', 'albums', 'albums/summer']);
      expect(folders.map((folder) => folder.depth), [0, 1, 2]);
    });

    test('sync downloads root and nested images with relative paths', () async {
      final modifiedAt = DateTime(2026, 5, 18, 12, 0);
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': [
            SmbRemoteEntry(
              path: '/photos/root.jpg',
              name: 'root.jpg',
              isDirectory: false,
              modifiedAt: modifiedAt,
            ),
            const SmbRemoteEntry(
              path: '/photos/albums',
              name: 'albums',
              isDirectory: true,
            ),
          ],
          '/photos/albums': const [
            SmbRemoteEntry(
              path: '/photos/albums/nested.png',
              name: 'nested.png',
              isDirectory: false,
            ),
            SmbRemoteEntry(
              path: '/photos/albums/notes.txt',
              name: 'notes.txt',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        storageProvider,
        clientFactory: factoryFor(client),
      );

      await service.sync();

      final rootFile = File('${tempDir.path}/root.jpg');
      final nestedFile = File('${tempDir.path}/albums/nested.png');
      expect(await rootFile.exists(), isTrue);
      expect(await nestedFile.exists(), isTrue);
      expect(File('${tempDir.path}/albums/notes.txt').existsSync(), isFalse);
      expect(
        client.downloadedPaths,
        unorderedEquals(['/photos/root.jpg', '/photos/albums/nested.png']),
      );
      expect(await rootFile.lastModified(), modifiedAt);
      expect(client.closed, isTrue);
    });

    test('sync only downloads images that are missing locally', () async {
      final existingFile = File('${tempDir.path}/already-here.jpg');
      await existingFile.writeAsString('existing');

      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/already-here.jpg',
              name: 'already-here.jpg',
              isDirectory: false,
            ),
            SmbRemoteEntry(
              path: '/photos/first.jpg',
              name: 'first.jpg',
              isDirectory: false,
            ),
            SmbRemoteEntry(
              path: '/photos/second.jpg',
              name: 'second.jpg',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        storageProvider,
        clientFactory: factoryFor(client),
      );

      await service.sync();

      expect(client.downloadedPaths, ['/photos/first.jpg', '/photos/second.jpg']);
    });

    test('sync respects selected-folder filtering', () async {
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/root.jpg',
              name: 'root.jpg',
              isDirectory: false,
            ),
            SmbRemoteEntry(
              path: '/photos/albums',
              name: 'albums',
              isDirectory: true,
            ),
          ],
          '/photos/albums': const [
            SmbRemoteEntry(
              path: '/photos/albums/keep.jpg',
              name: 'keep.jpg',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        SmbSourceConfig.fromMap(const {
          'host': '192.168.1.10',
          'share': 'photos',
          'folder_sync_mode': 'selected',
          'selected_folders': ['albums'],
        }),
        storageProvider,
        clientFactory: factoryFor(client),
      );

      await service.sync();

      expect(client.downloadedPaths, ['/photos/albums/keep.jpg']);
      expect(File('${tempDir.path}/root.jpg').existsSync(), isFalse);
    });

    test('sync pulls a new subfolder under a selected folder', () async {
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/albums',
              name: 'albums',
              isDirectory: true,
            ),
            SmbRemoteEntry(
              path: '/photos/other',
              name: 'other',
              isDirectory: true,
            ),
          ],
          // A subfolder that did not exist when 'albums' was first selected.
          '/photos/albums': const [
            SmbRemoteEntry(
              path: '/photos/albums/2025',
              name: '2025',
              isDirectory: true,
            ),
          ],
          '/photos/albums/2025': const [
            SmbRemoteEntry(
              path: '/photos/albums/2025/new.jpg',
              name: 'new.jpg',
              isDirectory: false,
            ),
          ],
          '/photos/other': const [
            SmbRemoteEntry(
              path: '/photos/other/skip.jpg',
              name: 'skip.jpg',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        SmbSourceConfig.fromMap(const {
          'host': '192.168.1.10',
          'share': 'photos',
          'folder_sync_mode': 'selected',
          'selected_folders': ['albums'],
        }),
        storageProvider,
        clientFactory: factoryFor(client),
      );

      await service.sync();

      expect(client.downloadedPaths, ['/photos/albums/2025/new.jpg']);
      expect(File('${tempDir.path}/albums/2025/new.jpg').existsSync(), isTrue);
      expect(File('${tempDir.path}/other/skip.jpg').existsSync(), isFalse);
    });

    test('sync deletes orphaned local files when requested', () async {
      final orphan = File('${tempDir.path}/orphan.jpg');
      await orphan.writeAsString('old');

      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/keep.jpg',
              name: 'keep.jpg',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        storageProvider,
        clientFactory: factoryFor(client),
      );

      await service.sync(deleteOrphanedFiles: true);

      expect(File('${tempDir.path}/keep.jpg').existsSync(), isTrue);
      expect(orphan.existsSync(), isFalse);
    });

    test('sync uses the configured sub-path as the base directory', () async {
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos/albums/2024': const [
            SmbRemoteEntry(
              path: '/photos/albums/2024/pic.jpg',
              name: 'pic.jpg',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        const SmbSourceConfig(
          host: '192.168.1.10',
          share: 'photos',
          path: 'albums/2024',
        ),
        storageProvider,
        clientFactory: factoryFor(client),
      );

      await service.sync();

      expect(client.readDirCalls, ['/photos/albums/2024']);
      expect(client.downloadedPaths, ['/photos/albums/2024/pic.jpg']);
      expect(File('${tempDir.path}/pic.jpg').existsSync(), isTrue);
    });

    test('sync converts HEIC images to JPEG and re-uses them next run', () async {
      final modifiedAt = DateTime(2026, 5, 18, 12, 0);
      final converter = FakeImageConverter();
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': [
            SmbRemoteEntry(
              path: '/photos/apple.heic',
              name: 'apple.heic',
              isDirectory: false,
              modifiedAt: modifiedAt,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        storageProvider,
        clientFactory: factoryFor(client),
        imageConverter: converter,
      );

      await service.sync();

      final jpegFile = File('${tempDir.path}/apple.jpg');
      expect(await jpegFile.exists(), isTrue);
      expect(File('${tempDir.path}/apple.heic').existsSync(), isFalse);
      expect(File('${tempDir.path}/apple.jpg.part').existsSync(), isFalse);
      expect(converter.targets, [jpegFile.path]);
      expect(client.downloadedPaths, ['/photos/apple.heic']);
      expect(await jpegFile.lastModified(), modifiedAt);

      // The converted JPEG already satisfies the remote file, so a second sync
      // must neither re-download nor re-convert it.
      await service.sync();
      expect(client.downloadedPaths, ['/photos/apple.heic']);
      expect(converter.targets, [jpegFile.path]);
    });

    test('sync does not prune converted JPEGs as orphans', () async {
      final converter = FakeImageConverter();
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/apple.heic',
              name: 'apple.heic',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        storageProvider,
        clientFactory: factoryFor(client),
        imageConverter: converter,
      );

      await service.sync(deleteOrphanedFiles: true);

      expect(File('${tempDir.path}/apple.jpg').existsSync(), isTrue);
    });

    test('sync skips HEIC files whose conversion fails', () async {
      final converter = FakeImageConverter(succeed: false);
      final client = FakeSmbRemoteClient(
        directories: {
          '/photos': const [
            SmbRemoteEntry(
              path: '/photos/apple.heic',
              name: 'apple.heic',
              isDirectory: false,
            ),
          ],
        },
      );

      final service = SmbSyncService.fromConfig(
        const SmbSourceConfig(host: '192.168.1.10', share: 'photos'),
        storageProvider,
        clientFactory: factoryFor(client),
        imageConverter: converter,
      );

      await service.sync();

      expect(File('${tempDir.path}/apple.jpg').existsSync(), isFalse);
      expect(File('${tempDir.path}/apple.jpg.part').existsSync(), isFalse);
      expect(client.downloadedPaths, ['/photos/apple.heic']);
    });
  });
}
