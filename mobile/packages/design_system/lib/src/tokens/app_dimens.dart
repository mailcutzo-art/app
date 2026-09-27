import 'package:flutter/widgets.dart';

/// 4dp spacing grid.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;

  /// Horizontal screen gutter.
  static const double gutter = 20;
}

/// Corner radii. Cards use [xl]–[xxl]; controls are pill-shaped.
abstract final class AppRadii {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 28;
  static const double xxxl = 32;
  static const double pill = 999;

  static const BorderRadius card = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius tile = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(xxxl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Component sizes. Buttons and touch targets are deliberately generous.
abstract final class AppSizes {
  static const double buttonLarge = 60;
  static const double buttonMedium = 52;
  static const double buttonSmall = 40;
  static const double iconButton = 52;
  static const double iconButtonSmall = 44;
  static const double answerOptionMin = 68;
  static const double chip = 40;
  static const double navBar = 72;
  static const double navItem = 52;
  static const double minTouch = 48;
  static const double icon = 24;
  static const double iconSmall = 20;
  static const double iconLarge = 28;
  static const double avatar = 44;
}
