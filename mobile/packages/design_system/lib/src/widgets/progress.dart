import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';

/// Thick rounded progress bar that animates between values.
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.value,
    this.height = 8,
    this.color,
    this.trackColor,
    this.semanticLabel,
  });

  /// 0–1.
  final double value;
  final double height;
  final Color? color;
  final Color? trackColor;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final target = value.clamp(0.0, 1.0);
    return Semantics(
      label: semanticLabel,
      value: '${(target * 100).round()}%',
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: target),
        duration: AppMotion.of(context, AppMotion.slow),
        curve: AppMotion.emphasized,
        builder: (context, v, _) => ClipRRect(
          borderRadius: AppRadii.pillAll,
          child: SizedBox(
            height: height,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: trackColor ?? colors.surfaceSunken)),
                FractionallySizedBox(
                  widthFactor: v,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color ?? colors.ink,
                      borderRadius: AppRadii.pillAll,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Discrete progress in separate segments (e.g. 3 daily missions).
class SegmentedProgress extends StatelessWidget {
  const SegmentedProgress({
    super.key,
    required this.total,
    required this.completed,
    this.height = 6,
    this.gap = 6,
    this.color,
  });

  final int total;
  final int completed;
  final double height;
  final double gap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final duration = AppMotion.of(context, AppMotion.medium);
    return Semantics(
      value: '$completed of $total',
      child: Row(
        children: [
          for (var i = 0; i < total; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(
              child: AnimatedContainer(
                duration: duration,
                curve: AppMotion.standard,
                height: height,
                decoration: BoxDecoration(
                  color: i < completed ? (color ?? colors.ink) : colors.surfaceSunken,
                  borderRadius: AppRadii.pillAll,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Circular countdown. [progress] is the fraction of time remaining; the
/// ring shifts from ink to warning to error as it runs out.
class CountdownRing extends StatelessWidget {
  const CountdownRing({
    super.key,
    required this.progress,
    required this.label,
    this.size = 64,
    this.strokeWidth = 6,
  });

  final double progress;
  final String label;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final p = progress.clamp(0.0, 1.0);
    final color = p > 0.5
        ? colors.ink
        : p > 0.25
        ? colors.warning
        : colors.error;
    return Semantics(
      label: '$label seconds left',
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(
            painter: _RingPainter(
              progress: p,
              color: color,
              track: colors.surfaceSunken,
              strokeWidth: strokeWidth,
            ),
            child: Center(
              child: Text(
                label,
                style: context.text.numericMedium.copyWith(
                  color: p > 0.25 ? colors.ink : colors.error,
                  fontSize: size * 0.3,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final Color track;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    if (progress > 0) {
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, paint..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}
