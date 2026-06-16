import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:logging/logging.dart';

/// Converts image files that Flutter's built-in decoder cannot render (notably
/// HEIC/HEIF from Apple devices) into a widely supported format.
///
/// Lives behind an interface so the sync services can be unit-tested without
/// pulling in platform channels.
abstract class ImageConverter {
  /// Converts [sourceFile] to a JPEG written at [targetPath].
  ///
  /// Returns `true` on success. Implementations must not throw; failures are
  /// reported as `false` so callers can skip the offending file.
  Future<bool> convertToJpeg(File sourceFile, String targetPath);
}

/// Real [ImageConverter] backed by `flutter_image_compress`, which decodes via
/// the host platform's image stack. On Android, HEIF decoding requires API 28
/// (Android 9) or newer.
class FlutterImageConverter implements ImageConverter {
  const FlutterImageConverter();

  static final _log = Logger('FlutterImageConverter');

  @override
  Future<bool> convertToJpeg(File sourceFile, String targetPath) async {
    try {
      final result = await FlutterImageCompress.compressAndGetFile(
        sourceFile.path,
        targetPath,
        format: CompressFormat.jpeg,
        quality: 90,
        // Large enough to leave typical phone photos at full resolution; the
        // slideshow downsizes to the screen at display time anyway.
        minWidth: 4096,
        minHeight: 4096,
      );
      return result != null;
    } catch (e) {
      _log.warning('Failed to convert ${sourceFile.path} to JPEG: $e');
      return false;
    }
  }
}
