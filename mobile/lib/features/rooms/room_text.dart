import 'package:realtime_client/realtime_client.dart';

import '../../core/network/app_failure.dart';

/// What the room screens and the live layer say.
abstract final class RoomText {
  /// Why the user is out of the room.
  static String closed(String? reason) => switch (reason) {
    'host_ended' => 'The host closed the room',
    'idle' => 'The room closed after 15 minutes without activity',
    'host_left' => 'The lobby closed because the host left',
    'empty' => 'Everyone left, so the room closed',
    'away' => 'Your room closed while you were away',
    _ => 'The room closed',
  };

  static const kicked = 'The host removed you from the room';

  /// "Physics", from a slug when that's all there is.
  static String subject(String? slug) {
    if (slug == null || slug.isEmpty) return 'Any subject';
    final words = slug.replaceAll('-', ' ').replaceAll('_', ' ');
    return words[0].toUpperCase() + words.substring(1);
  }

  /// `mixed`, `easy`, … as shown.
  static String difficulty(String? wire) => switch (wire) {
    'easy' => 'Easy',
    'medium' => 'Medium',
    'hard' => 'Hard',
    _ => 'Mixed',
  };

  /// What went wrong with a `room.*` request.
  static String error(RealtimeError error) => switch (error.code) {
    RealtimeErrorCode.notFound => 'That room isn\'t open any more.',
    RealtimeErrorCode.notAllowed => 'You can\'t do that in this room.',
    RealtimeErrorCode.busy => 'You\'re busy with another game right now.',
    RealtimeErrorCode.rateLimited => 'Too many tries. Wait a moment and try again.',
    RealtimeErrorCode.unavailable => 'Rooms are paused for a moment. Please try again soon.',
    RealtimeErrorCode.badRequest => 'Those settings can\'t be used. Try different ones.',
    _ => 'Couldn\'t reach the game server. Check your connection and try again.',
  };

  /// Why `room.join` failed, for the join screen.
  static String joinError(RealtimeError error) => switch (error.code) {
    RealtimeErrorCode.notFound => codeNotActive,
    RealtimeErrorCode.notAllowed => 'You can\'t join this room.',
    _ => RoomText.error(error),
  };

  /// Why a REST call about rooms or invites failed.
  static String failure(AppFailure failure) => switch (failure) {
    NotFoundFailure(code: 'INVITE_EXPIRED') => 'That invite expired.',
    NotFoundFailure() => codeNotActive,
    RateLimitedFailure() => 'Too many wrong codes. Wait a minute and try again.',
    _ => failure.message,
  };

  static const codeNotActive = 'That code isn\'t active. Ask for a new one.';

  /// "1st", "2nd", "3rd", "4th", …, "11th", "12th", "21st".
  static String ordinal(int n) {
    final teen = n % 100 >= 11 && n % 100 <= 13;
    final suffix = teen
        ? 'th'
        : switch (n % 10) {
            1 => 'st',
            2 => 'nd',
            3 => 'rd',
            _ => 'th',
          };
    return '$n$suffix';
  }
}
