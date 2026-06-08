import 'dart:math';
import 'package:flutter/material.dart';
import 'photo_view.dart';
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

/// Builds a complete, opaque photo face filling the screen for the given
/// [displayMode]: the photo (fit/fill/pan) over a black backing, plus a blurred
/// border behind it in `fit` mode when [blurBorders] is on. Wrapped in a
/// RepaintBoundary so static faces are cached as a texture and the transition
/// only transforms/clips/alphas that texture each frame.
Widget buildPhotoFace(
  PhotoEntry photo,
  Size screenSize,
  bool blurBorders,
  String displayMode,
) {
  final mode = resolveDisplayMode(displayMode, photo);
  final content = photoImage(photo, screenSize, mode);
  return RepaintBoundary(
    child: ColoredBox(
      color: Colors.black,
      child: mode == kDisplayModeFit
          ? Stack(
              fit: StackFit.expand,
              children: [
                if (blurBorders) blurredBorder(photo, screenSize),
                content,
              ],
            )
          : content,
    ),
  );
}

/// Plays a fade / slide / wipe / zoom transition that moves BOTH photos: the
/// outgoing photo transitions out while the incoming photo transitions in (a
/// push for slide, a paired scale for zoom, a crossfade for fade, a reveal for
/// wipe), over a black backing that hides the settled slide beneath. The flip
/// is handled by its own [FlipTransition].
class PhotoTransitionView extends StatelessWidget {
  const PhotoTransitionView({
    super.key,
    required this.animation,
    required this.type,
    required this.variant,
    required this.newPhoto,
    required this.previousPhoto,
    required this.screenSize,
    required this.blurBorders,
    required this.displayMode,
  });

  final Animation<double> animation;
  final PhotoTransition type;
  final int variant;
  final PhotoEntry newPhoto;
  final PhotoEntry? previousPhoto;
  final Size screenSize;
  final bool blurBorders;
  final String displayMode;

  Curve get _curve {
    switch (type) {
      case PhotoTransition.slide:
      case PhotoTransition.zoom:
        return Curves.easeOutCubic;
      default:
        return Curves.easeInOut;
    }
  }

  /// Unit direction the incoming photo enters from (and the outgoing exits to,
  /// negated): right / left / top / bottom for slide variants 0-3.
  Offset get _slideDir {
    switch (variant) {
      case 1:
        return const Offset(-1, 0); // from left
      case 2:
        return const Offset(0, -1); // from top
      case 3:
        return const Offset(0, 1); // from bottom
      default:
        return const Offset(1, 0); // from right
    }
  }

  /// How the incoming [face] animates in at progress [t].
  Widget _enter(Widget face, double t) {
    switch (type) {
      case PhotoTransition.fade:
        return Opacity(opacity: t.clamp(0.0, 1.0), child: face);
      case PhotoTransition.slide:
        return FractionalTranslation(translation: _slideDir * (1 - t), child: face);
      case PhotoTransition.zoom:
        final begin = variant == 1 ? 1.15 : 0.85;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(scale: begin + (1 - begin) * t, child: face),
        );
      case PhotoTransition.wipe:
        return ClipPath(clipper: _WipeClipper(t, variant), child: face);
      case PhotoTransition.flip:
        return face;
    }
  }

  /// How the outgoing [face] animates out at progress [t]. It stays fully
  /// opaque (so crossfades don't dip to black); fade/wipe simply leave it in
  /// place to be covered/revealed-over.
  Widget _exit(Widget face, double t) {
    switch (type) {
      case PhotoTransition.slide:
        return FractionalTranslation(translation: _slideDir * -t, child: face);
      case PhotoTransition.zoom:
        final end = variant == 1 ? 0.9 : 1.12;
        return Transform.scale(scale: 1 + (end - 1) * t, child: face);
      case PhotoTransition.fade:
      case PhotoTransition.wipe:
      case PhotoTransition.flip:
        return face;
    }
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: _curve);
    // Built once (stable) so the RepaintBoundary rasters are reused per frame.
    final newFace = buildPhotoFace(newPhoto, screenSize, blurBorders, displayMode);
    final oldFace = previousPhoto != null
        ? buildPhotoFace(previousPhoto!, screenSize, blurBorders, displayMode)
        : null;

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = curved.value;
        // The structure stays identical from t=0 through the settled state
        // (at t=1 the enter animation is the identity), and the two faces are
        // keyed, so a panning photo's State (and its pan progress) survives the
        // transition->settled boundary instead of jumping back to the origin.
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (oldFace != null && t < 1.0)
                KeyedSubtree(key: const ValueKey('old'), child: _exit(oldFace, t)),
              KeyedSubtree(key: const ValueKey('new'), child: _enter(newFace, t)),
            ],
          ),
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
    required this.displayMode,
  });

  final Animation<double> animation;
  final int variant;
  final PhotoEntry newPhoto;
  final PhotoEntry? previousPhoto;
  final Size screenSize;
  final bool blurBorders;
  final String displayMode;

  /// Blurred borders only exist in `fit` mode; `fill`/`pan` fill the frame.
  /// Resolved per photo so `random` can differ between the two faces.
  bool _useBlurFor(PhotoEntry photo) =>
      blurBorders && resolveDisplayMode(displayMode, photo) == kDisplayModeFit;

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

    // Stable, raster-cacheable pieces (built once, not per frame). The contain
    // image follows the display mode (fit/fill/pan); blur exists in fit mode,
    // resolved per photo so `random` can differ between the two faces.
    final useBlurNew = _useBlurFor(newPhoto);
    final useBlurPrev = hasPrevious && _useBlurFor(previousPhoto!);
    final newContain = photoImage(newPhoto, screenSize, displayMode);
    final newBlur = useBlurNew ? blurredBorder(newPhoto, screenSize) : const SizedBox.shrink();
    final prevContain =
        hasPrevious ? photoImage(previousPhoto!, screenSize, displayMode) : null;
    final prevBlur = useBlurPrev
        ? blurredBorder(previousPhoto!, screenSize)
        : const SizedBox.shrink();

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = curved.value;

        // Outgoing: flat (0) -> edge-on (+90deg); its blur fades out as it turns.
        final out = t.clamp(0.0, 0.5) / 0.5;
        final outAngle = out * (pi / 2);
        // Incoming: edge-on (-90deg) -> flat (0); its blur fades in as it turns.
        // At t=1 this is flat with blur fully in (the settled look), so the
        // structure never changes - a panning photo keeps its State.
        final inP = hasPrevious ? (t - 0.5).clamp(0.0, 0.5) / 0.5 : t;
        final inAngle = (inP - 1) * (pi / 2);

        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (prevContain != null && t < 1.0)
                KeyedSubtree(
                  key: const ValueKey('old'),
                  child: _rotated(
                    _face(prevContain, prevBlur, useBlurPrev ? (1 - out) : 0.0),
                    outAngle,
                  ),
                ),
              KeyedSubtree(
                key: const ValueKey('new'),
                child: _rotated(_face(newContain, newBlur, useBlurNew ? inP : 0.0), inAngle),
              ),
            ],
          ),
        );
      },
    );
  }
}
