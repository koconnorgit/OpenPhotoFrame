import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'photo_slide.dart';
import '../../domain/models/photo_entry.dart';

/// The available photo-to-photo transition animations.
enum PhotoTransition { fade, slide, wipe, zoom, flip }

/// A concrete transition to play: a [type] plus a [variant] that selects a
/// direction / sub-style (e.g. which edge a slide enters from).
class TransitionSpec {
  const TransitionSpec(this.type, [this.variant = 0]);

  final PhotoTransition type;
  final int variant;
}

/// Number of distinct variants a transition type supports.
int transitionVariantCount(PhotoTransition type) {
  switch (type) {
    case PhotoTransition.fade:
      return 1;
    case PhotoTransition.slide:
      return 4; // right, left, top, bottom
    case PhotoTransition.wipe:
      return 5; // L->R, R->L, T->B, B->T, iris
    case PhotoTransition.zoom:
      return 2; // in, out
    case PhotoTransition.flip:
      return 2; // Y axis, X axis
  }
}

/// Parses a stored config value into a [PhotoTransition], or null for "random"
/// / unknown values.
PhotoTransition? photoTransitionFromKey(String key) {
  for (final t in PhotoTransition.values) {
    if (t.name == key) return t;
  }
  return null;
}

/// Config key constant for the random/cycling mode.
const String kRandomTransitionKey = 'random';

/// Types eligible for the random cycle (every style except plain fade, so
/// "random" always feels lively; fade is still available on its own).
const List<PhotoTransition> _randomTypes = [
  PhotoTransition.fade,
  PhotoTransition.slide,
  PhotoTransition.wipe,
  PhotoTransition.zoom,
  PhotoTransition.flip,
];

/// Resolves the configured [transitionKey] into a concrete spec to play for the
/// next photo. For a fixed type a random *variant* is chosen so e.g. slides
/// come from varying edges; for "random" both type and variant are random.
TransitionSpec resolveTransitionSpec(String transitionKey, Random random) {
  final fixed = photoTransitionFromKey(transitionKey);
  if (fixed != null) {
    return TransitionSpec(fixed, random.nextInt(transitionVariantCount(fixed)));
  }
  final type = _randomTypes[random.nextInt(_randomTypes.length)];
  return TransitionSpec(type, random.nextInt(transitionVariantCount(type)));
}

/// Wraps [child] (the incoming photo) in the animation described by [spec],
/// driven by [animation] (0 -> 1). At value 1 every transition renders the
/// child normally, so settled slides beneath the incoming one stay fully
/// visible.
///
/// The flip transition is rendered separately via [FlipTransition] (it needs
/// the photo entries to turn the blur borders off while rotating), so it falls
/// back to a fade here if it ever reaches this generic builder.
Widget buildPhotoTransition(
  TransitionSpec spec,
  Animation<double> animation,
  Widget child,
) {
  switch (spec.type) {
    case PhotoTransition.fade:
      return FadeTransition(opacity: animation, child: child);

    case PhotoTransition.slide:
      const offsets = [
        Offset(1, 0), // from right
        Offset(-1, 0), // from left
        Offset(0, -1), // from top
        Offset(0, 1), // from bottom
      ];
      final begin = offsets[spec.variant % offsets.length];
      return SlideTransition(
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      );

    case PhotoTransition.wipe:
      return _WipeTransition(animation: animation, variant: spec.variant, child: child);

    case PhotoTransition.zoom:
      // variant 0 = zoom in (grow), variant 1 = zoom out (settle from larger).
      final begin = spec.variant == 1 ? 1.18 : 0.82;
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: begin, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOut),
          ),
          child: child,
        ),
      );

    case PhotoTransition.flip:
      // Rendered via FlipTransition directly; fall back to fade if reached.
      return FadeTransition(opacity: animation, child: child);
  }
}

/// Reveals [child] over what is beneath it, either wiping from an edge
/// (variants 0-3) or opening a circular "iris" from the centre (variant 4).
class _WipeTransition extends StatelessWidget {
  const _WipeTransition({
    required this.animation,
    required this.variant,
    required this.child,
  });

  final Animation<double> animation;
  final int variant;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    return AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (context, child) {
        return ClipPath(
          clipper: _WipeClipper(curved.value, variant),
          child: child,
        );
      },
    );
  }
}

class _WipeClipper extends CustomClipper<Path> {
  _WipeClipper(this.progress, this.variant);

  final double progress;
  final int variant;

  @override
  Path getClip(Size size) {
    final path = Path();
    final t = progress.clamp(0.0, 1.0);
    switch (variant) {
      case 1: // right -> left
        path.addRect(Rect.fromLTRB(size.width * (1 - t), 0, size.width, size.height));
        break;
      case 2: // top -> bottom
        path.addRect(Rect.fromLTRB(0, 0, size.width, size.height * t));
        break;
      case 3: // bottom -> top
        path.addRect(Rect.fromLTRB(0, size.height * (1 - t), size.width, size.height));
        break;
      case 4: // iris (circular reveal from centre)
        final maxRadius =
            sqrt(size.width * size.width + size.height * size.height) / 2;
        path.addOval(Rect.fromCircle(
          center: Offset(size.width / 2, size.height / 2),
          radius: maxRadius * t,
        ));
        break;
      case 0: // left -> right
      default:
        path.addRect(Rect.fromLTRB(0, 0, size.width * t, size.height));
    }
    return path;
  }

  @override
  bool shouldReclip(_WipeClipper oldClipper) =>
      oldClipper.progress != progress || oldClipper.variant != variant;
}

/// A perspective 3D flip like a turning card: in the first half the outgoing
/// photo rotates out to edge-on, then in the second half the incoming photo
/// rotates in from edge-on to flat. Rotates about the Y axis (variant 0) or X
/// axis (variant 1).
///
/// The photo (BoxFit.contain) is always fully opaque; only the blurred border
/// fill behind it fades - in as the incoming photo turns toward flat, out as
/// the outgoing photo turns away - so it never pops. The blur uses ImageFiltered
/// (a forward blur of a static image) wrapped in a RepaintBoundary so Flutter's
/// raster cache keeps it as a texture; the rotation and the fade then only
/// transform/alpha that cached texture, avoiding the per-frame BackdropFilter
/// cost that made earlier versions stutter. A black backing hides the static
/// slide beneath while the card turns.
class FlipTransition extends StatelessWidget {
  const FlipTransition({
    super.key,
    required this.animation,
    required this.variant,
    required this.newPhoto,
    required this.previousPhoto,
    required this.screenSize,
    required this.blurBorders,
  });

  final Animation<double> animation;
  final int variant;
  final PhotoEntry newPhoto;
  final PhotoEntry? previousPhoto;
  final Size screenSize;
  final bool blurBorders;

  /// The photo itself, fit to the screen (no border treatment).
  Widget _containImage(PhotoEntry photo) {
    return Center(
      child: Image(
        image: PhotoSlide.createOptimizedProvider(photo.file, screenSize),
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    );
  }

  /// The blurred, darkened full-bleed background shown in the letterbox borders.
  /// Uses ImageFiltered (a forward blur of a static image) in a RepaintBoundary
  /// so the blur is rasterized once and the raster cache reuses it as a texture.
  Widget _blurredBorder(PhotoEntry photo) {
    final image = PhotoSlide.createOptimizedProvider(photo.file, screenSize);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Image(image: image, fit: BoxFit.cover, gaplessPlayback: true),
          ),
          Container(color: Colors.black.withOpacity(0.4)),
        ],
      ),
    );
  }

  /// One face: black backing, the blurred border at [blurFade] opacity, then the
  /// photo on top. [blur]/[contain] are stable instances so their rasters cache.
  Widget _face(Widget contain, Widget blur, double blurFade) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (blurFade > 0)
            Opacity(opacity: blurFade.clamp(0.0, 1.0), child: blur),
          contain,
        ],
      ),
    );
  }

  /// Rotates [face] about the configured axis by [angle] with perspective.
  Widget _rotated(Widget face, double angle) {
    final transform = Matrix4.identity()..setEntry(3, 2, 0.0012); // perspective
    if (variant == 1) {
      transform.rotateX(angle);
    } else {
      transform.rotateY(angle);
    }
    return Transform(alignment: Alignment.center, transform: transform, child: face);
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    final hasPrevious = previousPhoto != null;

    // Stable, raster-cacheable pieces (built once, not per frame).
    final newContain = _containImage(newPhoto);
    final newBlur = blurBorders ? _blurredBorder(newPhoto) : const SizedBox.shrink();
    final prevContain = hasPrevious ? _containImage(previousPhoto!) : null;
    final prevBlur = (hasPrevious && blurBorders)
        ? _blurredBorder(previousPhoto!)
        : const SizedBox.shrink();

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = curved.value;

        // Settled: photo flat with the blur fully faded in.
        if (t >= 1.0) {
          return _face(newContain, newBlur, blurBorders ? 1.0 : 0.0);
        }

        // Outgoing: flat (0) -> edge-on (+90deg); its blur fades out as it turns.
        final out = t.clamp(0.0, 0.5) / 0.5;
        final outAngle = out * (pi / 2);
        // Incoming: edge-on (-90deg) -> flat (0); its blur fades in as it turns.
        final inP = hasPrevious ? (t - 0.5).clamp(0.0, 0.5) / 0.5 : t;
        final inAngle = (inP - 1) * (pi / 2);

        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (prevContain != null)
                _rotated(
                  _face(prevContain, prevBlur, blurBorders ? (1 - out) : 0.0),
                  outAngle,
                ),
              _rotated(_face(newContain, newBlur, blurBorders ? inP : 0.0), inAngle),
            ],
          ),
        );
      },
    );
  }
}
