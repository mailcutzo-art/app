import 'package:flutter/widgets.dart';

/// Motion tokens. Keep animations short: they should confirm an action, not
/// delay it.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
  static const Duration page = Duration(milliseconds: 320);

  /// Material 3 "emphasized" curve: quick start, gentle settle.
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;

  /// Slight overshoot for playful confirmations (correct answers, rewards).
  static const Curve bouncy = Cubic(0.34, 1.4, 0.64, 1);

  static const double pressedScale = 0.96;

  /// True when the user asked the OS to reduce motion.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration], or zero when motion is reduced.
  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}
