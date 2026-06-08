import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'photo_slide.dart';
import '../../domain/models/photo_entry.dart';

/// Photo display modes (stored in config as these strings):
/// - `fit`    : whole photo, scaled to fit (BoxFit.contain), letterboxed.
/// - `fill`   : photo zoomed to fill the frame (BoxFit.cover), cropping overflow.
/// - `pan`    : fills the frame and slowly drifts/zooms across it (Ken Burns).
/// - `random` : picks one of the above per photo.
const String kDisplayModeFit = 'fit';
const String kDisplayModeFill = 'fill';
const String kDisplayModePan = 'pan';
const String kDisplayModeRandom = 'random';

const List<String> _randomModes = [
  kDisplayModeFit,
  kDisplayModeFill,
  kDisplayModePan,
];

/// Resolves [mode] to a concrete display mode. For `random`, the choice is
/// derived from the photo path so a given photo always shows the same way
/// (stable across rebuilds and between its old/new faces in a transition).
String resolveDisplayMode(String mode, PhotoEntry photo) {
  if (mode != kDisplayModeRandom) return mode;
  return _randomModes[photo.file.path.hashCode.abs() % _randomModes.length];
}

/// The photo image itself, rendered for the given display [mode] (no border
/// treatment - the caller adds the blurred/black backing for `fit`).
Widget photoImage(PhotoEntry photo, Size screenSize, String mode) {
  final provider = PhotoSlide.createOptimizedProvider(photo.file, screenSize);
  switch (resolveDisplayMode(mode, photo)) {
    case kDisplayModeFill:
      return SizedBox.expand(
        child: Image(image: provider, fit: BoxFit.cover, gaplessPlayback: true),
      );
    case kDisplayModePan:
      return PanningPhoto(
        key: ValueKey('pan_${photo.file.path}'),
        provider: provider,
        seed: photo.file.path.hashCode,
      );
    case kDisplayModeFit:
    default:
      return Center(
        child: Image(image: provider, fit: BoxFit.contain, gaplessPlayback: true),
      );
  }
}

/// The blurred, darkened full-bleed background shown behind a `fit` photo's
/// letterbox. Uses ImageFiltered (forward blur of a static image) in a
/// RepaintBoundary so the raster cache keeps it as a texture.
Widget blurredBorder(PhotoEntry photo, Size screenSize) {
  final provider = PhotoSlide.createOptimizedProvider(photo.file, screenSize);
  return RepaintBoundary(
    child: Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Image(image: provider, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        Container(color: Colors.black.withOpacity(0.4)),
      ],
    ),
  );
}

/// A "Ken Burns" photo: fills the frame (BoxFit.cover) and slowly pans + zooms
/// back and forth, revealing different parts of the photo over time.
///
/// The pan position is a pure function of the absolute frame time and the
/// per-photo [seed] - not a per-widget animation that starts at creation. So
/// any PanningPhoto for the same photo (e.g. the same photo rendered both as a
/// transition's incoming face and, a moment later, its settled face) computes
/// the same position and the pan never jumps back to the origin. A ticker only
/// drives repaints; the image is a cached texture and only a Transform changes.
class PanningPhoto extends StatefulWidget {
  const PanningPhoto({
    super.key,
    required this.provider,
    required this.seed,
  });

  final ImageProvider provider;

  /// Stable per-photo value selecting the pan direction and phase offset.
  final int seed;

  @override
  State<PanningPhoto> createState() => _PanningPhotoState();
}

class _PanningPhotoState extends State<PanningPhoto>
    with SingleTickerProviderStateMixin {
  // Microseconds for one slow sweep; the motion then reverses (ping-pong).
  static const double _sweepMicros = 16 * 1000 * 1000;

  // Pan paths: start -> end focal alignment.
  static const _paths = <List<Alignment>>[
    [Alignment.topLeft, Alignment.bottomRight],
    [Alignment.topRight, Alignment.bottomLeft],
    [Alignment.centerLeft, Alignment.centerRight],
    [Alignment.topCenter, Alignment.bottomCenter],
    [Alignment.bottomLeft, Alignment.topRight],
    [Alignment.bottomRight, Alignment.topLeft],
  ];

  late final Ticker _ticker;
  late final Alignment _begin;
  late final Alignment _end;
  late final double _phaseOffset; // 0..2, so photos aren't all in lock-step
  late final Widget _image = SizedBox.expand(
    child: Image(image: widget.provider, fit: BoxFit.cover, gaplessPlayback: true),
  );

  @override
  void initState() {
    super.initState();
    final s = widget.seed.abs();
    final path = _paths[s % _paths.length];
    _begin = path[0];
    _end = path[1];
    _phaseOffset = (s % 1000) / 1000.0 * 2.0;
    // The ticker only forces a repaint each frame; the value comes from the
    // global frame clock below.
    _ticker = createTicker((_) => setState(() {}))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final micros =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    final phase = (micros / _sweepMicros + _phaseOffset) % 2.0;
    final tri = phase <= 1.0 ? phase : 2.0 - phase; // ping-pong 0..1..0
    final t = Curves.easeInOut.transform(tri);
    final scale = 1.15 + 0.13 * t; // gentle zoom while panning
    final align = Alignment.lerp(_begin, _end, t)!;
    // Scaling (>1) about a moving alignment point pans the visible region across
    // the photo while keeping the frame fully covered.
    return ClipRect(
      child: Transform.scale(scale: scale, alignment: align, child: _image),
    );
  }
}
