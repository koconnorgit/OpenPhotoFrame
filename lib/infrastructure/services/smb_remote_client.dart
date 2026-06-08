import 'dart:io';

import 'package:smb_connect/smb_connect.dart';

/// A directory entry returned from an SMB share.
///
/// Parallel to `NextcloudRemoteEntry` so the sync logic can be shared in shape.
class SmbRemoteEntry {
  const SmbRemoteEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.modifiedAt,
    this.sizeBytes,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final DateTime? modifiedAt;
  final int? sizeBytes;
}

/// Abstraction over an SMB connection so [SmbSyncService] can be tested with a
/// fake. Mirrors `NextcloudRemoteClient`, with an added [close] because SMB is
/// connection-oriented.
abstract class SmbRemoteClient {
  Future<List<SmbRemoteEntry>> readDir(String path);

  Future<void> downloadFile(String remotePath, String localPath);

  Future<void> close();
}

typedef SmbRemoteClientFactory = SmbRemoteClient Function({
  required String host,
  required String domain,
  required String username,
  required String password,
});

SmbRemoteClient createSmbConnectRemoteClient({
  required String host,
  required String domain,
  required String username,
  required String password,
}) {
  return SmbConnectRemoteClient(
    host: host,
    domain: domain,
    username: username,
    password: password,
  );
}

/// Concrete [SmbRemoteClient] backed by the pure-Dart `smb_connect` package.
///
/// The underlying connection is opened lazily on first use and reused for the
/// lifetime of the client; callers must invoke [close] when finished.
class SmbConnectRemoteClient implements SmbRemoteClient {
  SmbConnectRemoteClient({
    required this.host,
    required this.domain,
    required this.username,
    required this.password,
  });

  final String host;
  final String domain;
  final String username;
  final String password;

  SmbConnect? _connect;

  Future<SmbConnect> _ensureConnected() async {
    return _connect ??= await SmbConnect.connectAuth(
      host: host,
      domain: domain,
      username: username,
      password: password,
    );
  }

  @override
  Future<List<SmbRemoteEntry>> readDir(String path) async {
    final connect = await _ensureConnected();
    final folder = await connect.file(_toSmbPath(path));
    final files = await connect.listFiles(folder);

    return files
        .map(
          (file) => SmbRemoteEntry(
            path: file.path,
            name: file.name,
            isDirectory: file.isDirectory(),
            modifiedAt: _toDateTime(file.lastModified),
            sizeBytes: file.size,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath) async {
    final connect = await _ensureConnected();
    final file = await connect.file(_toSmbPath(remotePath));

    // smb_connect's openRead() streams in ~4 KB chunks with one SMB round-trip
    // per chunk, which is painfully slow over a network (a 3 MB photo needs
    // ~700 round-trips). Reading through the random-access file uses 64 KB SMB
    // reads internally, cutting round-trips ~16x.
    final raf = await connect.open(file, mode: FileMode.read);
    final sink = File(localPath).openWrite();
    try {
      const chunkSize = 1024 * 1024; // 1 MiB per read() call
      final length = file.size;
      var position = 0;
      while (position < length) {
        final remaining = length - position;
        final toRead = remaining < chunkSize ? remaining : chunkSize;
        final chunk = await raf.read(toRead);
        if (chunk.isEmpty) break; // unexpected EOF
        sink.add(chunk);
        position += chunk.length;
      }
    } finally {
      await raf.close();
      await sink.close();
    }
  }

  @override
  Future<void> close() async {
    final connect = _connect;
    _connect = null;
    if (connect != null) {
      await connect.close();
    }
  }

  /// smb_connect expects absolute paths beginning with a slash, e.g.
  /// `/share/folder`. Normalize whatever shape the caller passes.
  static String _toSmbPath(String path) {
    if (path.isEmpty) {
      return '/';
    }
    return path.startsWith('/') ? path : '/$path';
  }

  /// [SmbFile.lastModified] is milliseconds since the Unix epoch (0 = unknown).
  static DateTime? _toDateTime(int lastModifiedMillis) {
    if (lastModifiedMillis <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(lastModifiedMillis);
  }
}
