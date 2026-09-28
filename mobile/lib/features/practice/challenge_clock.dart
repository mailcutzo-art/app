import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/practice_models.dart';

/// The wall clock the practice screen reads for a challenge's deadline.
/// Tests swap in a clock they control.
final practiceNowProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// The one time limit of a Self Challenge, counted down from the server's
/// clock: the session ends at `created_at + time_limit`, whether or not the
/// app was open, so time spent in the background or away counts too. The
/// server keeps a minute of grace for slow networks and rejects later
/// answers as `time_up`; the app doesn't show the grace.
@immutable
class ChallengeClock {
  const ChallengeClock({required this.deadline, required this.limit});

  /// Null for sessions without a total time limit.
  static ChallengeClock? of(PracticeSession session) {
    final createdAt = session.createdAt;
    final limitMs = session.timeLimitMs;
    if (createdAt == null || limitMs == null || limitMs <= 0) return null;
    final limit = Duration(milliseconds: limitMs);
    return ChallengeClock(deadline: createdAt.add(limit), limit: limit);
  }

  /// Below this, the countdown turns to warning colours.
  static const lowAfter = Duration(minutes: 1);

  final DateTime deadline;
  final Duration limit;

  /// Time left at [now]: never negative, never more than the limit (a phone
  /// clock behind the server's doesn't add time).
  Duration remaining(DateTime now) {
    final left = deadline.difference(now);
    if (left <= Duration.zero) return Duration.zero;
    return left > limit ? limit : left;
  }

  bool isOver(DateTime now) => remaining(now) == Duration.zero;

  bool isLow(DateTime now) => remaining(now) <= lowAfter;

  /// 1 at the start, 0 when time is up.
  double fraction(DateTime now) => remaining(now).inMilliseconds / limit.inMilliseconds;
}

/// "9:41" or "1:02:05". Whole seconds are rounded up, so "0:00" only shows
/// once time is really up.
String formatCountdown(Duration left) {
  final total = (left.inMilliseconds / 1000).ceil();
  final hours = total ~/ 3600;
  final minutes = total ~/ 60 % 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  return '$minutes:$seconds';
}

/// "9 minutes 41 seconds left", for screen readers.
String countdownSemantics(Duration left) {
  final total = (left.inMilliseconds / 1000).ceil();
  final minutes = total ~/ 60;
  final seconds = total % 60;
  String unit(int n, String name) => n == 1 ? '1 $name' : '$n ${name}s';
  if (minutes == 0) return '${unit(seconds, 'second')} left';
  if (seconds == 0) return '${unit(minutes, 'minute')} left';
  return '${unit(minutes, 'minute')} ${unit(seconds, 'second')} left';
}
