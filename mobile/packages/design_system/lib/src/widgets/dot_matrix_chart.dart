import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';

/// Dot-matrix column chart with a highlighted column and tooltip
/// (reference 1). Tap or drag to move the highlight.
class DotMatrixChart extends StatefulWidget {
  const DotMatrixChart({
    super.key,
    required this.values,
    this.height = 150,
    this.initialIndex,
    this.tooltipBuilder,
    this.onSelected,
    this.semanticLabel,
  });

  final List<double> values;
  final double height;

  /// Highlighted column at start (defaults to the last one).
  final int? initialIndex;
  final String Function(int index, double value)? tooltipBuilder;
  final ValueChanged<int>? onSelected;
  final String? semanticLabel;

  @override
  State<DotMatrixChart> createState() => _DotMatrixChartState();
}

class _DotMatrixChartState extends State<DotMatrixChart> {
  late int _selected = widget.initialIndex ?? widget.values.length - 1;

  void _select(double dx, double width) {
    if (widget.values.isEmpty) return;
    final index = (dx / width * widget.values.length).floor().clamp(0, widget.values.length - 1);
    if (index != _selected) {
      setState(() => _selected = index);
      widget.onSelected?.call(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final values = widget.values;
    final selected = values.isEmpty ? -1 : _selected.clamp(0, values.length - 1);
    final label = selected >= 0 ? widget.tooltipBuilder?.call(selected, values[selected]) : null;

    return Semantics(
      label: widget.semanticLabel,
      value: label,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columnWidth = values.isEmpty ? 0.0 : width / values.length;
          final tooltipX = columnWidth * (selected + 0.5);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _select(d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _select(d.localPosition.dx, width),
            child: SizedBox(
              height: widget.height + (label == null ? 0 : 40),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: widget.height,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _DotMatrixPainter(
                          values: values,
                          selected: selected,
                          dotColor: colors.inkSubtle.withValues(alpha: 0.55),
                          highlight: colors.accent,
                          highlightStroke: colors.ink,
                        ),
                      ),
                    ),
                  ),
                  if (label != null)
                    Positioned(
                      top: 0,
                      left: math.max(0, math.min(width - 120, tooltipX - 20)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: colors.lemon.container,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: Text(label, style: text.labelMedium),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DotMatrixPainter extends CustomPainter {
  _DotMatrixPainter({
    required this.values,
    required this.selected,
    required this.dotColor,
    required this.highlight,
    required this.highlightStroke,
  });

  final List<double> values;
  final int selected;
  final Color dotColor;
  final Color highlight;
  final Color highlightStroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxValue = values.reduce(math.max);
    final columnWidth = size.width / values.length;
    final dot = math.min(columnWidth * 0.62, 6.0);
    final step = dot + math.max(2.0, dot * 0.5);
    final rows = (size.height / step).floor();
    final paint = Paint()..isAntiAlias = true;

    for (var c = 0; c < values.length; c++) {
      final ratio = maxValue <= 0 ? 0.0 : values[c] / maxValue;
      final filled = math.max(1, (ratio * rows).round());
      final x = columnWidth * (c + 0.5);
      final isSelected = c == selected;
      paint.color = isSelected ? highlight : dotColor;
      for (var r = 0; r < filled; r++) {
        final y = size.height - step * r - dot / 2;
        canvas.drawCircle(Offset(x, y), dot / 2, paint);
      }
      if (isSelected) {
        final topY = size.height - step * (rows - 1) - dot / 2;
        final guide = Paint()..color = highlight.withValues(alpha: 0.5);
        for (var r = filled; r < rows; r++) {
          final y = size.height - step * r - dot / 2;
          canvas.drawCircle(Offset(x, y), dot / 3, guide);
        }
        canvas
          ..drawCircle(Offset(x, topY), dot * 1.2, Paint()..color = highlight)
          ..drawCircle(
            Offset(x, topY),
            dot * 1.2,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = highlightStroke,
          );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotMatrixPainter old) =>
      old.selected != selected ||
      old.dotColor != dotColor ||
      old.highlight != highlight ||
      !identical(old.values, values);
}
