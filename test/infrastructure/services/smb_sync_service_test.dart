import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_photo_frame/domain/interfaces/storage_provider.dart';
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
      });

      expect(config.host, '192.168.1.10');
      expect(config.share, 'photos');
      expect(config.path, 'albums/2024');
      expect(config.username, 'frame');
      expect(config.password, 'secret');
      expect(config.isConfigured, isTrue);
      expect(config.syncAllFolders, isFalse);
      expect(config.normalizedSelectedFolders, {'', 'albums/summer'});
      expect(config.includesRelativeFile('albums/summer/photo.jpg'), isTrue);
      expect(config.includesRelativeFile('albums/photo.jpg'), isFalse);

      final restored = SmbSourceConfig.fromMap(config.toMap());
      expect(restored.host, config.host);
      expect(restored.path, config.path);
      expect(restored.normalizedSelectedFolders, config.normalizedSelectedFolders);
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
  });
}
