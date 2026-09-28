import 'dart:math' as math;

import 'package:design_system/design_system.dart';
import 'package:flutter/widgets.dart';

/// Vector artwork for the welcome screen's arena, drawn straight onto the
/// canvas from the design tokens: no image assets to bundle, decode or keep in
/// sync with the palette. Each painter draws one object into its own box and
/// never animates itself; motion is applied from outside with transforms, so
/// every picture is recorded once and reused by its repaint boundary.
///
/// Depth ("2.5D") comes from three cheap tricks: an extruded copy of each
/// shape drawn a few pixels lower in a darker shade, top-lit gradients, and
/// ellipses for anything that lies on the arena floor.

/// A darker shade of [color] for extruded sides.
Color _shade(Color color, double amount) => Color.lerp(color, const Color(0xFF000000), amount)!;

/// A lighter tint of [color] for highlights.
Color _tint(Color color, double amount) => Color.lerp(color, const Color(0xFFFFFFFF), amount)!;

abstract class _ArenaPainter extends CustomPainter {
  const _ArenaPainter(this.colors);

  final AppColors colors;

  @override
  bool shouldRepaint(covariant _ArenaPainter oldDelegate) =>
      oldDelegate.colors != colors || oldDelegate.runtimeType != runtimeType;
}

/// Background layer: the lime glow behind the arena and two rings of
/// "stadium lights" around its floor, brighter at the front for depth.
class ArenaBackdropPainter extends _ArenaPainter {
  const ArenaBackdropPainter(super.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final glowCenter = Offset(w * 0.5, h * 0.52);
    final glowRadius = w * 0.5;
    canvas.drawCircle(
      glowCenter,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            colors.accent.withValues(alpha: 0.16),
            colors.accent.withValues(alpha: 0.05),
            colors.accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: glowCenter, radius: glowRadius)),
    );

    final floor = Offset(w * 0.5, h * 0.76);
    final dot = Paint();
    for (final (rx, ry, count, radius) in [
      (w * 0.47, h * 0.15, 28, w * 0.006),
      (w * 0.56, h * 0.2, 36, w * 0.0045),
    ]) {
      for (var i = 0; i < count; i++) {
        final angle = 2 * math.pi * i / count;
        // sin > 0 is the half nearer the viewer: brighter and larger.
        final nearness = (math.sin(angle) + 1) / 2;
        dot.color = colors.ink.withValues(alpha: 0.06 + 0.22 * nearness);
        canvas.drawCircle(
          floor + Offset(rx * math.cos(angle), ry * math.sin(angle)),
          radius * (0.7 + 0.6 * nearness),
          dot,
        );
      }
    }
  }
}

/// A soft rounded cloud; the colour is kept low-contrast on purpose.
class CloudPainter extends _ArenaPainter {
  const CloudPainter(super.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..addRRect(RRect.fromLTRBR(0, h * 0.45, w, h, Radius.circular(h * 0.3)))
      ..addOval(Rect.fromCircle(center: Offset(w * 0.32, h * 0.5), radius: h * 0.34))
      ..addOval(Rect.fromCircle(center: Offset(w * 0.6, h * 0.4), radius: h * 0.4));
    canvas.drawPath(path, Paint()..color = colors.surfaceSunken.withValues(alpha: 0.75));
  }
}

/// Foreground: a two-tier round arena floor with a soft contact shadow, a
/// lime rim and a row of lights along its front edge.
class ArenaPlatformPainter extends _ArenaPainter {
  const ArenaPlatformPainter(super.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Contact shadow under the whole platform.
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.8), width: w * 0.96, height: h * 0.3),
      Paint()
        ..color = colors.shadow.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // Lower tier.
    _cylinder(
      canvas,
      top: Rect.fromCenter(center: Offset(w * 0.5, h * 0.5), width: w, height: h * 0.5),
      depth: h * 0.16,
      side: _shade(colors.surfaceSunken, 0.35),
      face: colors.surfaceMuted,
    );
    // Upper tier, the stage itself.
    final stage = Rect.fromCenter(
      center: Offset(w * 0.5, h * 0.36),
      width: w * 0.76,
      height: h * 0.36,
    );
    _cylinder(
      canvas,
      top: stage,
      depth: h * 0.13,
      side: _shade(colors.surfaceSunken, 0.1),
      face: colors.surface,
    );
    canvas
      ..drawOval(
        stage,
        Paint()
          ..shader = RadialGradient(
            colors: [colors.accent.withValues(alpha: 0.24), colors.accent.withValues(alpha: 0)],
          ).createShader(stage),
      )
      ..drawOval(
        stage.deflate(w * 0.09),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = colors.accent.withValues(alpha: 0.28),
      )
      ..drawOval(
        stage,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.accent.withValues(alpha: 0.85),
      );

    // Lights along the front of the stage's side band.
    final lights = Paint()..color = colors.accent;
    final bandCenterY = stage.center.dy + h * 0.065;
    for (var i = 1; i < 8; i++) {
      final angle = math.pi * i / 8;
      final x = stage.center.dx - stage.width / 2 * math.cos(angle);
      final y = bandCenterY + stage.height / 2 * math.sin(angle);
      lights.color = colors.accent.withValues(alpha: 0.45 + 0.5 * math.sin(angle));
      canvas.drawCircle(Offset(x, y), w * 0.008, lights);
    }
  }

  /// An upright cylinder seen from above: the side band, then the top face.
  void _cylinder(
    Canvas canvas, {
    required Rect top,
    required double depth,
    required Color side,
    required Color face,
  }) {
    final bottom = top.shift(Offset(0, depth));
    final band = Path()
      ..addOval(bottom)
      ..addRect(Rect.fromLTRB(top.left, top.center.dy, top.right, bottom.center.dy));
    canvas
      ..drawPath(
        band,
        Paint()
          ..shader = LinearGradient(colors: [_shade(side, 0.3), side, _shade(side, 0.3)])
              .createShader(bottom),
      )
      ..drawOval(
        top,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_tint(face, 0.05), face],
          ).createShader(top),
      );
  }
}

/// The focal emblem: an extruded lime battle shield holding a trophy.
class BattleShieldPainter extends _ArenaPainter {
  const BattleShieldPainter(super.colors);

  static Path _shield(Size size) {
    final w = size.width;
    final h = size.height;
    return Path()
      ..moveTo(w * 0.5, 0)
      ..cubicTo(w * 0.66, h * 0.07, w * 0.84, h * 0.1, w * 0.98, h * 0.1)
      ..lineTo(w * 0.98, h * 0.46)
      ..cubicTo(w * 0.98, h * 0.72, w * 0.78, h * 0.88, w * 0.5, h)
      ..cubicTo(w * 0.22, h * 0.88, w * 0.02, h * 0.72, w * 0.02, h * 0.46)
      ..lineTo(w * 0.02, h * 0.1)
      ..cubicTo(w * 0.16, h * 0.1, w * 0.34, h * 0.07, w * 0.5, 0)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final depth = size.height * 0.045;
    final faceSize = Size(w, size.height - depth);
    final shield = _shield(faceSize);

    // Extrusion, then the face lit from the top.
    canvas
      ..drawPath(shield.shift(Offset(0, depth)), Paint()..color = _shade(colors.accent, 0.5))
      ..drawPath(
        shield,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_tint(colors.accent, 0.12), colors.accentPressed],
          ).createShader(Offset.zero & faceSize),
      );

    // Dark inset panel.
    final inner = _shield(faceSize).transform(
      (Matrix4.identity()
            ..translateByDouble(w * 0.5, faceSize.height * 0.47, 0, 1)
            ..scaleByDouble(0.76, 0.76, 1, 1)
            ..translateByDouble(-w * 0.5, -faceSize.height * 0.47, 0, 1))
          .storage,
    );
    canvas
      ..drawPath(inner, Paint()..color = colors.paper)
      ..drawPath(
        inner,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = colors.accent.withValues(alpha: 0.35),
      );

    _trophy(canvas, faceSize);
  }

  void _trophy(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.5;
    final l = cx - w * 0.19;
    final r = cx + w * 0.19;
    final gold = colors.accent;

    final handles = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.035
      ..strokeCap = StrokeCap.round
      ..color = _shade(gold, 0.18);
    canvas
      ..drawArc(
        Rect.fromLTWH(l - w * 0.08, h * 0.28, w * 0.14, h * 0.15),
        math.pi * 0.5,
        math.pi,
        false,
        handles,
      )
      ..drawArc(
        Rect.fromLTWH(r - w * 0.06, h * 0.28, w * 0.14, h * 0.15),
        -math.pi * 0.5,
        math.pi,
        false,
        handles,
      );

    final cup = Path()
      ..moveTo(l, h * 0.25)
      ..lineTo(r, h * 0.25)
      ..lineTo(r - w * 0.01, h * 0.4)
      ..cubicTo(r - w * 0.02, h * 0.51, cx + w * 0.08, h * 0.57, cx, h * 0.57)
      ..cubicTo(cx - w * 0.08, h * 0.57, l + w * 0.02, h * 0.51, l + w * 0.01, h * 0.4)
      ..close();
    canvas
      ..drawPath(
        cup,
        Paint()
          ..shader = LinearGradient(
            colors: [_tint(gold, 0.25), gold, _shade(gold, 0.2)],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromLTRB(l, h * 0.25, r, h * 0.57)),
      )
      ..drawRect(
        Rect.fromLTRB(cx - w * 0.028, h * 0.565, cx + w * 0.028, h * 0.64),
        Paint()..color = _shade(gold, 0.15),
      )
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(cx - w * 0.13, h * 0.635, cx + w * 0.13, h * 0.7),
          Radius.circular(w * 0.02),
        ),
        Paint()..color = gold,
      );

    // A star stamped on the cup.
    canvas.drawPath(
      _star(Offset(cx, h * 0.385), w * 0.07, w * 0.03),
      Paint()..color = colors.paper,
    );
  }

  static Path _star(Offset center, double outer, double inner) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? outer : inner;
      final angle = -math.pi / 2 + math.pi * i / 5;
      final point = center + Offset(radius * math.cos(angle), radius * math.sin(angle));
      i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }
}

/// An open book in three-quarter view, in the muted sky tone.
class FloatingBookPainter extends _ArenaPainter {
  const FloatingBookPainter(super.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cover = colors.sky.onContainer;

    Path page(double outerX, double spineX) => Path()
      ..moveTo(spineX, h * 0.2)
      ..quadraticBezierTo((outerX + spineX) / 2, h * 0.04, outerX, h * 0.1)
      ..lineTo(outerX, h * 0.78)
      ..quadraticBezierTo((outerX + spineX) / 2, h * 0.72, spineX, h * 0.88)
      ..close();

    // Cover peeking out below the pages, then the pages.
    final coverPath = Path()
      ..moveTo(w * 0.5, h * 0.3)
      ..lineTo(w * 0.02, h * 0.2)
      ..lineTo(w * 0.02, h * 0.9)
      ..lineTo(w * 0.5, h)
      ..lineTo(w * 0.98, h * 0.9)
      ..lineTo(w * 0.98, h * 0.2)
      ..close();
    canvas.drawPath(coverPath, Paint()..color = _shade(cover, 0.35));

    final leftPage = page(w * 0.06, w * 0.5);
    final rightPage = page(w * 0.94, w * 0.5);
    canvas
      ..drawPath(leftPage, Paint()..color = _shade(colors.ink, 0.1))
      ..drawPath(rightPage, Paint()..color = colors.ink)
      ..drawLine(
        Offset(w * 0.5, h * 0.2),
        Offset(w * 0.5, h * 0.88),
        Paint()
          ..color = _shade(cover, 0.2)
          ..strokeWidth = 1.5,
      );

    final lines = Paint()
      ..color = cover
      ..strokeWidth = h * 0.05
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final y = h * (0.34 + 0.14 * i);
      canvas
        ..drawLine(Offset(w * 0.16, y), Offset(w * (i == 2 ? 0.3 : 0.4), y + h * 0.02), lines)
        ..drawLine(Offset(w * 0.6, y + h * 0.02), Offset(w * (i == 1 ? 0.74 : 0.84), y), lines);
    }
  }
}

/// A quiz card in the muted lemon tone; the "?" on it is a child widget so it
/// uses the app font without a hand-managed text painter.
class QuestionCardPainter extends _ArenaPainter {
  const QuestionCardPainter(super.colors);

  /// Height of the extruded edge, as a fraction of the card's height.
  static const depthFactor = 0.06;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final depth = h * depthFactor;
    final face = RRect.fromLTRBR(0, 0, w, h - depth, Radius.circular(w * 0.18));
    final card = colors.lemon.onContainer;
    canvas
      ..drawRRect(face.shift(Offset(0, depth)), Paint()..color = _shade(card, 0.45))
      ..drawRRect(
        face,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_tint(card, 0.15), card],
          ).createShader(face.outerRect),
      );
  }
}

/// A small extruded lightning bolt: speed, live battles.
class LightningPainter extends _ArenaPainter {
  const LightningPainter(super.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height * 0.94;
    final bolt = Path()
      ..moveTo(w * 0.62, 0)
      ..lineTo(w * 0.08, h * 0.56)
      ..lineTo(w * 0.46, h * 0.56)
      ..lineTo(w * 0.32, h)
      ..lineTo(w * 0.92, h * 0.4)
      ..lineTo(w * 0.54, h * 0.4)
      ..close();
    canvas
      ..drawPath(
        bolt.shift(Offset(0, size.height * 0.06)),
        Paint()..color = _shade(colors.accent, 0.5),
      )
      ..drawPath(bolt, Paint()..color = colors.accent);
  }
}

/// A four-point sparkle.
class SparklePainter extends CustomPainter {
  const SparklePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final rx = size.width / 2;
    final ry = size.height / 2;
    final path = Path()
      ..moveTo(c.dx, c.dy - ry)
      ..quadraticBezierTo(c.dx, c.dy, c.dx + rx, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + ry)
      ..quadraticBezierTo(c.dx, c.dy, c.dx - rx, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - ry)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant SparklePainter oldDelegate) => oldDelegate.color != color;
}
