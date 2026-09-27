import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';

enum Goal {
  neet('NEET', 'Physics, Chemistry, Biology'),
  jee('JEE', 'Physics, Chemistry, Maths');

  const Goal(this.label, this.subjects);

  final String label;
  final String subjects;

  static Goal? parse(Object? value) => switch (value) {
    'neet' => Goal.neet,
    'jee' => Goal.jee,
    _ => null,
  };
}

/// Preset avatar: a pastel tone plus a symbol from a fixed catalog (no photo
/// uploads in v1).
@immutable
class Avatar {
  const Avatar({required this.tone, required this.symbol});

  final String tone;
  final String symbol;

  static const tones = ['lime', 'sky', 'mint', 'lemon', 'lavender', 'peach', 'rose'];

  static const symbols = <String, HugeIconData>{
    'rocket': AppIcons.rocket,
    'atom': AppIcons.physics,
    'flask': AppIcons.chemistry,
    'dna': AppIcons.biology,
    'pi': AppIcons.maths,
    'brain': AppIcons.brain,
    'idea': AppIcons.idea,
    'star': AppIcons.star,
    'crown': AppIcons.crown,
    'medal': AppIcons.medal,
    'fire': AppIcons.fire,
    'flash': AppIcons.flash,
    'leaf': AppIcons.leaf,
    'cube': AppIcons.cube,
    'globe': AppIcons.globe,
    'target': AppIcons.target,
    'sparkles': AppIcons.sparkles,
    'smile': AppIcons.smile,
    'graduation': AppIcons.graduation,
    'book': AppIcons.learn,
    'sun': AppIcons.sun,
    'moon': AppIcons.moon,
    'trophy': AppIcons.arena,
    'robot': AppIcons.robot,
  };

  static const fallback = Avatar(tone: 'lime', symbol: 'rocket');

  static Avatar parse(Object? json) => switch (json) {
    {'tone': final String tone, 'symbol': final String symbol}
        when tones.contains(tone) && symbols.containsKey(symbol) =>
      Avatar(tone: tone, symbol: symbol),
    _ => fallback,
  };

  Map<String, String> toJson() => {'tone': tone, 'symbol': symbol};

  AvatarData toData() => AvatarData(
    tone: PastelTone.values.firstWhere((t) => t.name == tone, orElse: () => PastelTone.lime),
    symbol: symbols[symbol] ?? AppIcons.rocket,
  );

  @override
  bool operator ==(Object other) => other is Avatar && other.tone == tone && other.symbol == symbol;

  @override
  int get hashCode => Object.hash(tone, symbol);
}

/// The signed-in user's own profile (`GET /v1/me`).
@immutable
class Me {
  const Me({
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.onboardingCompleted,
    this.handle,
    this.goal,
    this.birthYear,
    this.isMinor = false,
    this.roles = const [],
  });

  final String id;
  final String? handle;
  final String displayName;
  final Avatar avatar;
  final Goal? goal;
  final int? birthYear;
  final bool isMinor;
  final bool onboardingCompleted;
  final List<String> roles;

  /// Throws [FormatException] on malformed payloads.
  factory Me.fromJson(Object? json) {
    if (json
        case {
              'id': final String id,
              'display_name': final String displayName,
              'onboarding_completed': final bool onboardingCompleted,
            } &&
            final Map<dynamic, dynamic> map) {
      return Me(
        id: id,
        displayName: displayName,
        onboardingCompleted: onboardingCompleted,
        handle: map['handle'] as String?,
        avatar: Avatar.parse(map['avatar']),
        goal: Goal.parse(map['goal']),
        birthYear: (map['birth_year'] as num?)?.toInt(),
        isMinor: map['is_minor'] == true,
        roles: [...?(map['roles'] as List?)?.whereType<String>()],
      );
    }
    throw const FormatException('Invalid user payload');
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'handle': handle,
    'display_name': displayName,
    'avatar': avatar.toJson(),
    'goal': goal?.name,
    'birth_year': birthYear,
    'is_minor': isMinor,
    'onboarding_completed': onboardingCompleted,
    'roles': roles,
  };
}
