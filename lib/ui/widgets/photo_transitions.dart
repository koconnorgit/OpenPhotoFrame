import 'dart:math';
import 'package:flutter/material.dart';

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
/// [previousChild] is the outgoing photo, used by the flip transition to turn
/// the old photo out before turning the new one in. Other transitions ignore
/// it (they animate the incoming photo over the still-visible old slide).
Widget buildPhotoTransition(
  TransitionSpec spec,
  Animation<double> animation,
  Widget child, {
  Widget? previousChild,
}) {
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
      return _FlipTransition(
        animation: animation,
        variant: spec.variant,
        previousChild: previousChild,
        child: child,
      );
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
/// photo ([previousChild]) rotates out to edge-on, then in the second half the
/// incoming photo rotates in from edge-on to flat. Rotates about the Y axis
/// (variant 0) or X axis (variant 1).
///
/// A black backing fills the screen so the static slide beneath is hidden while
/// the card turns (revealing black at the edges, as a real flip would). If
/// there is no outgoing photo (the very first slide), it just flips the
/// incoming photo in.
class _FlipTransition extends StatelessWidget {
  const _FlipTransition({
    required this.animation,
    required this.variant,
    required this.previousChild,
    required this.child,
  });

  final Animation<double> animation;
  final int variant;
  final Widget? previousChild;
  final Widget child;

  /// Rotates [face] about the configured axis by [angle] radians with
  /// perspective. The face is wrapped in a RepaintBoundary so its expensive
  /// blurred border is rasterized once and only the cached texture is
  /// transformed each frame.
  Widget _rotatedFace(Widget face, double angle) {
    final transform = Matrix4.identity()..setEntry(3, 2, 0.0012); // perspective
    if (variant == 1) {
      transform.rotateX(angle);
    } else {
      transform.rotateY(angle);
    }
    return Transform(
      alignment: Alignment.center,
      transform: transform,
      child: RepaintBoundary(child: face),
    );
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    final hasPrevious = previousChild != null;

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = curved.value;

        // Outgoing: flat (0) -> edge-on (+90deg) over the first half, then
        // stays edge-on (hidden) for the second half.
        final outAngle = (t.clamp(0.0, 0.5) / 0.5) * (pi / 2);
        // Incoming: edge-on (-90deg) until the midpoint, then -90 -> 0 (flat).
        // With no outgoing photo (first slide) it flips in across the whole run.
        final inProgress = hasPrevious ? (t - 0.5).clamp(0.0, 0.5) / 0.5 : t;
        final inAngle = (inProgress - 1) * (pi / 2);

        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          // Both faces are painted for the whole transition (each cached via a
          // RepaintBoundary), so the incoming photo's blur is rasterized before
          // the midpoint swap instead of hitching right after it. The face that
          // is past edge-on has zero width, so it costs only a transformed quad.
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasPrevious) _rotatedFace(previousChild!, outAngle),
              _rotatedFace(child, inAngle),
            ],
          ),
        );
      },
    );
  }
}
