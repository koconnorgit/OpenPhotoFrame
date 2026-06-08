import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'photo_slide.dart';
import '../../domain/models/photo_entry.dart';

/// Photo display modes (stored in config as these strings):
/// - `fit`  : whole photo, scaled to fit (BoxFit.contain), letterboxed.
/// - `fill` : photo zoomed to fill the frame (BoxFit.cover), cropping overflow.
/// - `pan`  : fills the frame and slowly drifts/zooms across it (Ken Burns).
const String kDisplayModeFit = 'fit';
const String kDisplayModeFill = 'fill';
const String kDisplayModePan = 'pan';

/// The photo image itself, rendered for the given display [mode] (no border
/// treatment - the caller adds the blurred/black backing for `fit`).
Widget photoImage(PhotoEntry photo, Size screenSize, String mode) {
  final provider = PhotoSlide.createOptimizedProvider(photo.file, screenSize);
  switch (mode) {
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
/// back and forth, revealing different parts of the photo over time. The image
/// is a cached texture; only a Transform animates, so it stays cheap.
class PanningPhoto extends StatefulWidget {
  const PanningPhoto({
    super.key,
    required this.provider,
    required this.seed,
  });

  final ImageProvider provider;

  /// Stable per-photo value that selects the pan direction.
  final int seed;

  @override
  State<PanningPhoto> createState() => _PanningPhotoState();
}

class _PanningPhotoState extends State<PanningPhoto>
    with SingleTickerProviderStateMixin {
  // One slow sweep takes this long, then reverses (ping-pong) for as long as
  // the photo is shown - independent of the slide duration.
  static const _sweep = Duration(seconds: 16);

  // Pan paths: start -> end focal alignment. The motion reverses, so each is
  // also its own return trip.
  static const _paths = <List<Alignment>>[
    [Alignment.topLeft, Alignment.bottomRight],
    [Alignment.topRight, Alignment.bottomLeft],
    [Alignment.centerLeft, Alignment.centerRight],
    [Alignment.topCenter, Alignment.bottomCenter],
    [Alignment.bottomLeft, Alignment.topRight],
    [Alignment.bottomRight, Alignment.topLeft],
  ];

  late final AnimationController _controller;
  late final Alignment _begin;
  late final Alignment _end;

  @override
  void initState() {
    super.initState();
    final path = _paths[widget.seed.abs() % _paths.length];
    _begin = path[0];
    _end = path[1];
    _controller = AnimationController(vsync: this, duration: _sweep)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        // The image is a stable, cached child; only the transform animates.
        child: SizedBox.expand(
          child: Image(image: widget.provider, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        builder: (context, child) {
          final t = Curves.easeInOut.transform(_controller.value);
          final scale = 1.15 + 0.13 * t; // gentle zoom while panning
          final align = Alignment.lerp(_begin, _end, t)!;
          // Scaling (>1) about a moving alignment point pans the visible region
          // across the photo while keeping the frame fully covered.
          return Transform.scale(scale: scale, alignment: align, child: child);
        },
      ),
    );
  }
}
