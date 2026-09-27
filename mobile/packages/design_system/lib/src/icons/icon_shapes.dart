import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/painting.dart';
import 'package:path_parsing/path_parsing.dart';

/// Icon data in the Hugeicons JSON-like format: a list of
/// `[elementName, attributes]` pairs drawn on a 24×24 grid.
typedef HugeIconData = List<List<dynamic>>;

/// One drawable element of an icon, in icon space (24×24).
class IconShape {
  IconShape({
    required this.path,
    required this.stroked,
    required this.filled,
    required this.strokeWidth,
    required this.opacity,
  });

  final Path path;
  final bool stroked;
  final bool filled;
  final double strokeWidth;
  final double opacity;

  List<PathMetric>? _metrics;

  /// Cached metrics for partial ("draw-on") rendering.
  List<PathMetric> get metrics => _metrics ??= path.computeMetrics().toList(growable: false);
}

/// Converts icon data to [Path]s once and caches the result by identity
/// (icon constants are canonicalized, so identity is a cheap, exact key).
abstract final class IconShapes {
  static const double gridSize = 24;
  static final Map<HugeIconData, List<IconShape>> _cache = HashMap.identity();

  static List<IconShape> of(HugeIconData data) => _cache.putIfAbsent(data, () => _parse(data));

  static List<IconShape> _parse(HugeIconData data) {
    final shapes = <IconShape>[];
    for (final element in data) {
      if (element.length < 2) continue;
      final name = element[0];
      final attrs = element[1];
      if (name is! String || attrs is! Map) continue;
      final a = attrs.cast<String, Object?>();
      final path = _pathFor(name, a);
      if (path == null) continue;
      final stroke = a['stroke'];
      final fill = a['fill'];
      shapes.add(
        IconShape(
          path: path,
          stroked: stroke != null && stroke != 'none',
          filled: fill != null && fill != 'none',
          strokeWidth: _num(a['strokeWidth'], fallback: 1.5),
          opacity: _num(a['opacity'], fallback: 1),
        ),
      );
    }
    return List.unmodifiable(shapes);
  }

  static Path? _pathFor(String name, Map<String, Object?> a) {
    switch (name) {
      case 'path':
        final d = a['d'];
        if (d is! String || d.isEmpty) return null;
        final path = Path();
        writeSvgPathDataToPath(d, _PathProxy(path));
        return path;
      case 'circle':
        return Path()..addOval(
          Rect.fromCircle(center: Offset(_num(a['cx']), _num(a['cy'])), radius: _num(a['r'])),
        );
      case 'ellipse':
        return Path()..addOval(
          Rect.fromCenter(
            center: Offset(_num(a['cx']), _num(a['cy'])),
            width: _num(a['rx']) * 2,
            height: _num(a['ry']) * 2,
          ),
        );
      case 'rect':
        final rect = Rect.fromLTWH(_num(a['x']), _num(a['y']), _num(a['width']), _num(a['height']));
        final rx = _num(a['rx'], fallback: _num(a['ry']));
        final ry = _num(a['ry'], fallback: rx);
        return Path()..addRRect(RRect.fromRectXY(rect, rx, ry));
      case 'line':
        return Path()
          ..moveTo(_num(a['x1']), _num(a['y1']))
          ..lineTo(_num(a['x2']), _num(a['y2']));
      case 'polyline':
      case 'polygon':
        final points = _points(a['points']);
        if (points.isEmpty) return null;
        final path = Path()..addPolygon(points, name == 'polygon');
        return path;
      default:
        return null;
    }
  }

  static List<Offset> _points(Object? raw) {
    if (raw is! String) return const [];
    final numbers = raw
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .map(double.tryParse)
        .whereType<double>()
        .toList();
    return [for (var i = 0; i + 1 < numbers.length; i += 2) Offset(numbers[i], numbers[i + 1])];
  }

  static double _num(Object? value, {double fallback = 0}) => switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s) ?? fallback,
    _ => fallback,
  };

  /// Portion of [shape] from its start up to [fraction] of its total length.
  static Path partial(IconShape shape, double fraction) {
    final f = fraction.clamp(0.0, 1.0);
    if (f >= 1) return shape.path;
    final result = Path();
    for (final metric in shape.metrics) {
      final end = metric.length * f;
      result.addPath(metric.extractPath(0, math.max(0, end)), Offset.zero);
    }
    return result;
  }
}

class _PathProxy extends PathProxy {
  _PathProxy(this.path);

  final Path path;

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) =>
      path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void close() => path.close();
}
