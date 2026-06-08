import 'dart:io';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Snapshot of how much space the synced photos occupy versus what the device
/// filesystem has available.
class StorageInfo {
  const StorageInfo({
    required this.photosBytes,
    this.freeBytes,
    this.totalBytes,
  });

  /// Total size of the locally stored photos.
  final int photosBytes;

  /// Free bytes on the filesystem holding the photos (null if unavailable).
  final int? freeBytes;

  /// Total capacity of that filesystem (null if unavailable).
  final int? totalBytes;

  /// True when device-level free/total figures are available.
  bool get hasDeviceStats => freeBytes != null && totalBytes != null;
}

/// Computes [StorageInfo]: photo-folder size from Dart, and device free/total
/// space from a small native channel (Android). On platforms without the
/// channel the device stats are simply omitted.
class StorageInfoService {
  static const _channel =
      MethodChannel('io.github.micw.openphotoframe/storage_info');
  final _log = Logger('StorageInfoService');

  Future<StorageInfo> load(Directory photoDir) async {
    final photosBytes = await _directorySize(photoDir);

    int? freeBytes;
    int? totalBytes;
    if (Platform.isAndroid) {
      try {
        final stats = await _channel.invokeMapMethod<String, dynamic>(
          'getStorageStats',
          {'path': photoDir.path},
        );
        if (stats != null) {
          freeBytes = (stats['freeBytes'] as num?)?.toInt();
          totalBytes = (stats['totalBytes'] as num?)?.toInt();
        }
      } catch (e) {
        _log.warning('Could not read device storage stats: $e');
      }
    }

    return StorageInfo(
      photosBytes: photosBytes,
      freeBytes: freeBytes,
      totalBytes: totalBytes,
    );
  }

  Future<int> _directorySize(Directory dir) async {
    if (!await dir.exists()) {
      return 0;
    }
    var total = 0;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // Skip files that vanish mid-walk (e.g. a sync deleting orphans).
          }
        }
      }
    } catch (e) {
      _log.warning('Could not measure photo folder size: $e');
    }
    return total;
  }
}
