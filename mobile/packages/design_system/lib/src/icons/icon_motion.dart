import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A value animated through keyframes over normalized time `[0, 1]`.
///
/// Mirrors Framer Motion keyframes (as used by AnimateIcons): [curve] eases
/// each segment between two keyframes, and [times] places the keyframes.
@immutable
class Keyframes {
  /// [times], when given, must have one entry per value, ascending in `[0, 1]`.
  const Keyframes(this.values, {this.times, this.curve = Curves.easeInOut});

  final List<double> values;
  final List<double>? times;
  final Curve curve;

  double at(double t) {
    assert(values.isNotEmpty && (times == null || times!.length == values.length));
    if (values.length == 1) return values.first;
    final last = values.length - 1;
    double timeAt(int i) => times?[i] ?? i / last;
    if (t <= timeAt(0)) return values.first;
    if (t >= timeAt(last)) return values.last;
    for (var i = 0; i < last; i++) {
      final start = timeAt(i);
      final end = timeAt(i + 1);
      if (t <= end) {
        final span = end - start;
        final local = span <= 0 ? 1.0 : (t - start) / span;
        return lerpDouble(values[i], values[i + 1], curve.transform(local))!;
      }
    }
    return values.last;
  }
}

/// Transform of one shape (or the whole icon) at an instant.
@immutable
class ShapeTransform {
  const ShapeTransform({
    this.rotateDegrees = 0,
    this.dx = 0,
    this.dy = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.opacity = 1,
    this.draw = 1,
    this.origin = const Offset(12, 12),
  });

  final double rotateDegrees;
  final double dx;
  final double dy;
  final double scaleX;
  final double scaleY;
  final double opacity;

  /// Fraction of the stroke drawn (1 = complete).
  final double draw;
  final Offset origin;

  bool get isIdentity => rotateDegrees == 0 && dx == 0 && dy == 0 && scaleX == 1 && scaleY == 1;

  void applyTo(Canvas canvas) {
    if (isIdentity) return;
    canvas
      ..translate(origin.dx + dx, origin.dy + dy)
      ..rotate(rotateDegrees * math.pi / 180)
      ..scale(scaleX, scaleY)
      ..translate(-origin.dx, -origin.dy);
  }
}

/// Keyframed motion for a shape. [begin]/[end] restrict it to part of the
/// icon's overall timeline, which is how delays are expressed.
@immutable
class ShapeMotion {
  const ShapeMotion({
    this.rotate,
    this.dx,
    this.dy,
    this.scale,
    this.scaleX,
    this.scaleY,
    this.opacity,
    this.draw,
    this.origin = const Offset(12, 12),
    this.begin = 0,
    this.end = 1,
  });

  /// Degrees.
  final Keyframes? rotate;

  /// Offsets in icon units (the icon grid is 24×24).
  final Keyframes? dx;
  final Keyframes? dy;
  final Keyframes? scale;
  final Keyframes? scaleX;
  final Keyframes? scaleY;
  final Keyframes? opacity;
  final Keyframes? draw;

  /// Pivot for rotation and scaling, in icon units.
  final Offset origin;
  final double begin;
  final double end;

  ShapeTransform at(double t) {
    final local = end <= begin ? 1.0 : ((t - begin) / (end - begin)).clamp(0.0, 1.0);
    final uniform = scale?.at(local) ?? 1;
    return ShapeTransform(
      rotateDegrees: rotate?.at(local) ?? 0,
      dx: dx?.at(local) ?? 0,
      dy: dy?.at(local) ?? 0,
      scaleX: uniform * (scaleX?.at(local) ?? 1),
      scaleY: uniform * (scaleY?.at(local) ?? 1),
      opacity: (opacity?.at(local) ?? 1).clamp(0.0, 1.0),
      draw: (draw?.at(local) ?? 1).clamp(0.0, 1.0),
      origin: origin,
    );
  }
}

/// A complete icon animation: an optional whole-icon motion plus motions for
/// individual shapes, keyed by the shape's index in the icon data.
@immutable
class IconMotion {
  const IconMotion({
    required this.duration,
    this.icon,
    this.shapes = const {},
    this.repeat = false,
  });

  final Duration duration;
  final ShapeMotion? icon;
  final Map<int, ShapeMotion> shapes;
  final bool repeat;
}

/// Motions ported from AnimateIcons (MIT, https://animateicons.in), adapted to
/// Hugeicons stroke-rounded shapes. Values match the originals; shapes that
/// only exist in the Lucide versions animate as a whole icon instead.
abstract final class IconMotions {
  /// Notification01: the bell swings from its top while the clapper lags.
  static const bell = IconMotion(
    duration: Duration(milliseconds: 1300),
    icon: ShapeMotion(
      origin: Offset(12, 2.9),
      rotate: Keyframes([0, 7, -18, 14, -9, 5, -2, 0], times: [0, .09, .26, .45, .62, .78, .9, 1]),
    ),
    shapes: {
      0: ShapeMotion(
        begin: 0.06,
        dx: Keyframes(
          [0, 1.5, -5, 4, -2.5, 1.5, -1, 0],
          times: [0, .09, .26, .45, .62, .78, .9, 1],
        ),
      ),
    },
  );

  static const bookmark = IconMotion(
    duration: Duration(milliseconds: 450),
    icon: ShapeMotion(
      dy: Keyframes([0, -4, 0], curve: Curves.easeOut),
      scaleY: Keyframes([1, 1.1, .95, 1], curve: Curves.easeOut),
      scaleX: Keyframes([1, .97, 1.02, 1], curve: Curves.easeOut),
    ),
  );

  static const check = IconMotion(
    duration: Duration(milliseconds: 600),
    icon: ShapeMotion(
      draw: Keyframes([0, 1]),
      scale: Keyframes([1, 1.15, 1]),
      opacity: Keyframes([.5, 1]),
    ),
  );

  static const search = IconMotion(
    duration: Duration(milliseconds: 1200),
    icon: ShapeMotion(
      dx: Keyframes([0, 2, -2, 1, 0]),
      dy: Keyframes([0, -1, 2, -1, 0]),
      rotate: Keyframes([0, 6, -6, 4, 0]),
    ),
  );

  static const settings = IconMotion(
    duration: Duration(milliseconds: 600),
    icon: ShapeMotion(rotate: Keyframes([0, 60]), scale: Keyframes([1, 1.05, 1])),
  );

  static const heart = IconMotion(
    duration: Duration(milliseconds: 1100),
    icon: ShapeMotion(begin: .82, scale: Keyframes([1, 1.06, 1])),
    shapes: {
      0: ShapeMotion(end: .73, draw: Keyframes([0, 1])),
    },
  );

  static const spin = IconMotion(
    duration: Duration(milliseconds: 1000),
    repeat: true,
    icon: ShapeMotion(rotate: Keyframes([0, 360], curve: Curves.linear)),
  );

  static const trophy = IconMotion(
    duration: Duration(milliseconds: 800),
    icon: ShapeMotion(
      origin: Offset(12, 21),
      dy: Keyframes([0, -2, 0, -1, 0]),
      rotate: Keyframes([0, -8, 6, -3, 0]),
    ),
  );

  static const swords = IconMotion(
    duration: Duration(milliseconds: 900),
    icon: ShapeMotion(rotate: Keyframes([0, -5, 5, -3, 3, 0]), scale: Keyframes([1, 1.05, .95, 1])),
  );

  static const timer = IconMotion(
    duration: Duration(milliseconds: 650),
    icon: ShapeMotion(
      draw: Keyframes([0, 1], curve: Cubic(.16, 1, .3, 1)),
      opacity: Keyframes([0, 1], curve: Cubic(.16, 1, .3, 1)),
    ),
  );

  static const flame = IconMotion(
    duration: Duration(milliseconds: 1000),
    icon: ShapeMotion(
      origin: Offset(12, 22),
      scale: Keyframes([1, 1.05, 1.02, 1]),
      dy: Keyframes([0, -2, -1, 0]),
      rotate: Keyframes([0, -2, 1, 0]),
    ),
  );

  static const home = IconMotion(
    duration: Duration(milliseconds: 550),
    icon: ShapeMotion(
      origin: Offset(12, 21),
      scale: Keyframes([.7, 1.06, .98, 1], times: [0, .55, .8, 1], curve: Curves.easeOut),
    ),
  );

  static const users = IconMotion(
    duration: Duration(milliseconds: 600),
    icon: ShapeMotion(
      scale: Keyframes([.85, 1.08, 1], curve: Curves.easeOut),
      opacity: Keyframes([.4, 1, 1], curve: Curves.easeOut),
    ),
  );

  static const gamepad = IconMotion(
    duration: Duration(milliseconds: 450),
    icon: ShapeMotion(scale: Keyframes([1, .88, 1]), rotate: Keyframes([0, 10, -10, 0])),
  );

  static const book = IconMotion(
    duration: Duration(milliseconds: 900),
    icon: ShapeMotion(scale: Keyframes([1, 1.05, .97, 1]), rotate: Keyframes([0, -2, 2, 0])),
  );

  static const flash = IconMotion(
    duration: Duration(milliseconds: 600),
    icon: ShapeMotion(
      draw: Keyframes([0, 1], times: [0, .75], curve: Curves.easeOut),
      scale: Keyframes([.92, 1.08, 1], curve: Curves.easeOut),
      rotate: Keyframes([0, -4, 2, 0], curve: Curves.easeOut),
    ),
  );

  static const crown = IconMotion(
    duration: Duration(milliseconds: 600),
    icon: ShapeMotion(
      dy: Keyframes([-5, .8, 0], times: [0, .65, 1], curve: Curves.easeOut),
      rotate: Keyframes([-10, 4, 0], times: [0, .65, 1], curve: Curves.easeOut),
      opacity: Keyframes([0, 1, 1], times: [0, .65, 1], curve: Curves.easeOut),
    ),
  );

  static const medal = IconMotion(
    duration: Duration(milliseconds: 1000),
    icon: ShapeMotion(origin: Offset(12, 2), rotate: Keyframes([0, 16, -12, 7, -3, 0])),
  );

  static const coins = IconMotion(
    duration: Duration(milliseconds: 600),
    icon: ShapeMotion(
      dy: Keyframes([0, -3, 0], curve: Curves.easeOut),
      rotate: Keyframes([0, -10, 8, 0]),
    ),
  );

  static const pop = IconMotion(
    duration: Duration(milliseconds: 450),
    icon: ShapeMotion(scale: Keyframes([1, 1.18, .96, 1], curve: Curves.easeOut)),
  );

  static const sparkle = IconMotion(
    duration: Duration(milliseconds: 700),
    icon: ShapeMotion(
      scale: Keyframes([1, 1.2, 1], curve: Curves.easeOut),
      rotate: Keyframes([0, 15, 0], curve: Curves.easeOut),
    ),
  );
}
