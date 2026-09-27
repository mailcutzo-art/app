import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../tokens/app_motion.dart';
import 'icon_motion.dart';
import 'icon_shapes.dart';

/// Draws a Hugeicons icon synchronously with a [CustomPainter] (no SVG
/// decoding, so no first-frame flicker and deterministic goldens).
class HugeIcon extends StatelessWidget {
  const HugeIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.strokeWidth,
    this.semanticLabel,
  });

  final HugeIconData icon;
  final double? size;
  final Color? color;

  /// Overrides the icon's stroke width (in icon units; default 1.5).
  final double? strokeWidth;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final effectiveSize = size ?? theme.size ?? 24;
    final effectiveColor = color ?? theme.color ?? const Color(0xFF000000);
    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: effectiveSize,
        child: CustomPaint(
          painter: HugeIconPainter(
            shapes: IconShapes.of(icon),
            color: effectiveColor,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

/// A [HugeIcon] that plays an [IconMotion] when [trigger] changes (and on
/// first build when [autoplay] is set). Honors the OS "reduce motion" setting.
class AnimatedHugeIcon extends StatefulWidget {
  const AnimatedHugeIcon(
    this.icon, {
    super.key,
    required this.motion,
    this.trigger,
    this.autoplay = false,
    this.size,
    this.color,
    this.strokeWidth,
    this.semanticLabel,
  });

  final HugeIconData icon;
  final IconMotion motion;

  /// Any value; the motion plays each time it changes.
  final Object? trigger;
  final bool autoplay;
  final double? size;
  final Color? color;
  final double? strokeWidth;
  final String? semanticLabel;

  @override
  State<AnimatedHugeIcon> createState() => AnimatedHugeIconState();
}

class AnimatedHugeIconState extends State<AnimatedHugeIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.motion.duration,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) play();
      });
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedHugeIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.motion.duration;
    if (widget.trigger != oldWidget.trigger) play();
  }

  /// Plays the motion from the start (no-op when motion is reduced).
  void play() {
    if (AppMotion.reduced(context)) {
      _controller.value = 1;
      return;
    }
    if (widget.motion.repeat) {
      _controller.repeat();
    } else {
      _controller.forward(from: 0);
    }
  }

  void stop() => _controller.value = 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = widget.size ?? theme.size ?? 24;
    final color = widget.color ?? theme.color ?? const Color(0xFF000000);
    final shapes = IconShapes.of(widget.icon);
    return Semantics(
      label: widget.semanticLabel,
      image: widget.semanticLabel != null,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: HugeIconPainter(
                shapes: shapes,
                color: color,
                strokeWidth: widget.strokeWidth,
                motion: widget.motion,
                progress: _controller.value,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints icon shapes scaled from the 24×24 grid to the widget size,
/// optionally applying an [IconMotion] at [progress].
class HugeIconPainter extends CustomPainter {
  HugeIconPainter({
    required this.shapes,
    required this.color,
    this.strokeWidth,
    this.motion,
    this.progress = 1,
  });

  final List<IconShape> shapes;
  final Color color;
  final double? strokeWidth;
  final IconMotion? motion;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (shapes.isEmpty || size.isEmpty) return;
    final scale = size.shortestSide / IconShapes.gridSize;
    final animating = motion != null && progress < 1;
    final whole = animating ? motion!.icon?.at(progress) : null;

    canvas
      ..save()
      ..scale(scale);
    whole?.applyTo(canvas);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    for (var i = 0; i < shapes.length; i++) {
      final shape = shapes[i];
      final own = animating ? motion!.shapes[i]?.at(progress) : null;
      final opacity = shape.opacity * (whole?.opacity ?? 1) * (own?.opacity ?? 1);
      if (opacity <= 0) continue;
      final draw = (whole?.draw ?? 1) * (own?.draw ?? 1);
      if (draw <= 0) continue;

      canvas.save();
      own?.applyTo(canvas);
      final path = draw < 1 ? IconShapes.partial(shape, draw) : shape.path;
      final paintColor = color.withValues(alpha: color.a * opacity);
      if (shape.filled) {
        canvas.drawPath(path, fill..color = paintColor);
      }
      if (shape.stroked) {
        canvas.drawPath(
          path,
          stroke
            ..color = paintColor
            ..strokeWidth = strokeWidth ?? shape.strokeWidth,
        );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant HugeIconPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.motion != motion ||
      !listEquals(old.shapes, shapes);
}
