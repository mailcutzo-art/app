import 'package:design_system/design_system.dart';

/// Sample people and subjects used by the catalog's mock screens.
abstract final class Mock {
  static const me = AvatarData(tone: PastelTone.lime, symbol: AppIcons.rocket);
  static const riya = AvatarData(tone: PastelTone.lavender, symbol: AppIcons.leaf);
  static const kabir = AvatarData(tone: PastelTone.sky, symbol: AppIcons.cube);
  static const zara = AvatarData(tone: PastelTone.peach, symbol: AppIcons.star);
  static const dev = AvatarData(tone: PastelTone.mint, initials: 'DS');
  static const bot = AvatarData(tone: PastelTone.neutral, symbol: AppIcons.robot);

  static const subjects = [
    MockSubject('Physics', AppIcons.physics, PastelTone.sky, 96, 5),
    MockSubject('Chemistry', AppIcons.chemistry, PastelTone.lavender, 88, 5),
    MockSubject('Biology', AppIcons.biology, PastelTone.mint, 92, 5),
    MockSubject('Maths', AppIcons.maths, PastelTone.peach, 84, 4),
  ];

  static const physicsChapters = [
    MockChapter('Units and Measurement', 20, 0.82),
    MockChapter('Kinematics', 20, 0.64),
    MockChapter('Laws of Motion', 20, 0.48),
    MockChapter('Work, Energy and Power', 18, null),
    MockChapter('Gravitation', 18, null),
  ];

  static const weeklyActivity = <double>[
    12,
    18,
    9,
    22,
    30,
    26,
    14,
    20,
    34,
    40,
    28,
    16,
    24,
    48,
    36,
    22,
    18,
    30,
    44,
    38,
    26,
    20,
    32,
    42,
  ];
}

class MockSubject {
  const MockSubject(this.name, this.icon, this.tone, this.questions, this.chapters);

  final String name;
  final HugeIconData icon;
  final PastelTone tone;
  final int questions;
  final int chapters;
}

class MockChapter {
  const MockChapter(this.name, this.questions, this.accuracy);

  final String name;
  final int questions;
  final double? accuracy;
}
