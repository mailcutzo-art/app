import 'dart:ui';

import 'package:design_system/design_system.dart';
import 'package:design_system/src/icons/icon_shapes.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IconShapes', () {
    const icons = <String, HugeIconData>{
      'home': AppIcons.home,
      'learn': AppIcons.learn,
      'battle': AppIcons.battle,
      'arena': AppIcons.arena,
      'social': AppIcons.social,
      'physics': AppIcons.physics,
      'chemistry': AppIcons.chemistry,
      'biology': AppIcons.biology,
      'maths': AppIcons.maths,
      'notification': AppIcons.notification,
      'coins': AppIcons.coins,
      'timer': AppIcons.timer,
      'check': AppIcons.check,
      'robot': AppIcons.robot,
    };

    for (final MapEntry(key: name, value: data) in icons.entries) {
      test('$name parses into drawable shapes inside the 24×24 grid', () {
        final shapes = IconShapes.of(data);
        expect(shapes, isNotEmpty);
        for (final shape in shapes) {
          expect(shape.stroked || shape.filled, isTrue);
          final bounds = shape.path.getBounds();
          expect(bounds.left, greaterThanOrEqualTo(-0.5));
          expect(bounds.top, greaterThanOrEqualTo(-0.5));
          expect(bounds.right, lessThanOrEqualTo(24.5));
          expect(bounds.bottom, lessThanOrEqualTo(24.5));
        }
      });
    }

    test('results are cached by identity', () {
      expect(identical(IconShapes.of(AppIcons.home), IconShapes.of(AppIcons.home)), isTrue);
    });

    test('ellipse, circle, rect, line and polyline elements are supported', () {
      const data = <List<dynamic>>[
        [
          'ellipse',
          {'cx': '12', 'cy': '12', 'rx': '4', 'ry': '2', 'stroke': 'currentColor'},
        ],
        [
          'circle',
          {'cx': 12, 'cy': 12, 'r': 3, 'fill': 'currentColor'},
        ],
        [
          'rect',
          {'x': '2', 'y': '2', 'width': '20', 'height': '20', 'rx': '4', 'stroke': 'currentColor'},
        ],
        [
          'line',
          {'x1': '0', 'y1': '0', 'x2': '24', 'y2': '24', 'stroke': 'currentColor'},
        ],
        [
          'polyline',
          {'points': '1,1 5,5 9,1', 'stroke': 'currentColor'},
        ],
        [
          'unknown',
          {'stroke': 'currentColor'},
        ],
      ];
      final shapes = IconShapes.of(data);
      expect(shapes, hasLength(5));
      expect(shapes[1].filled, isTrue);
      expect(shapes[1].stroked, isFalse);
      expect(shapes[0].path.getBounds(), const Rect.fromLTRB(8, 10, 16, 14));
    });

    test('partial paths grow with the fraction', () {
      final shape = IconShapes.of(AppIcons.check).first;
      final full = shape.metrics.fold<double>(0, (sum, m) => sum + m.length);
      double length(Path p) => p.computeMetrics().fold<double>(0, (sum, m) => sum + m.length);
      expect(length(IconShapes.partial(shape, 0.5)), closeTo(full / 2, 0.01));
      expect(identical(IconShapes.partial(shape, 1), shape.path), isTrue);
    });
  });

  group('Keyframes', () {
    test('interpolates between evenly spaced keyframes', () {
      const k = Keyframes([0, 10, 0], curve: Curves.linear);
      expect(k.at(0), 0);
      expect(k.at(0.25), 5);
      expect(k.at(0.5), 10);
      expect(k.at(1), 0);
      expect(k.at(-1), 0);
      expect(k.at(2), 0);
    });

    test('honors explicit times', () {
      const k = Keyframes([0, 100], times: [0.5, 1], curve: Curves.linear);
      expect(k.at(0.25), 0);
      expect(k.at(0.75), 50);
    });

    test('shape motion windows express delays', () {
      const m = ShapeMotion(begin: 0.5, dx: Keyframes([0, 10], curve: Curves.linear));
      expect(m.at(0.25).dx, 0);
      expect(m.at(0.75).dx, 5);
      expect(m.at(1).dx, 10);
    });
  });

  test('one-shot motions end at rest so the icon never snaps', () {
    const motions = {
      'bell': IconMotions.bell,
      'bookmark': IconMotions.bookmark,
      'check': IconMotions.check,
      'search': IconMotions.search,
      'heart': IconMotions.heart,
      'trophy': IconMotions.trophy,
      'swords': IconMotions.swords,
      'timer': IconMotions.timer,
      'flame': IconMotions.flame,
      'home': IconMotions.home,
      'users': IconMotions.users,
      'gamepad': IconMotions.gamepad,
      'book': IconMotions.book,
      'flash': IconMotions.flash,
      'crown': IconMotions.crown,
      'medal': IconMotions.medal,
      'coins': IconMotions.coins,
      'pop': IconMotions.pop,
      'sparkle': IconMotions.sparkle,
    };
    for (final MapEntry(key: name, value: motion) in motions.entries) {
      final transforms = [motion.icon?.at(1), ...motion.shapes.values.map((s) => s.at(1))];
      for (final t in transforms.whereType<ShapeTransform>()) {
        expect(t.isIdentity, isTrue, reason: '$name should end untransformed');
        expect(t.opacity, 1, reason: name);
        expect(t.draw, 1, reason: name);
      }
    }
  });
}
