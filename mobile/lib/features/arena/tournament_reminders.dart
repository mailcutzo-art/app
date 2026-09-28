import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/live/live_hub.dart' show liveClockProvider;
import '../../app/router.dart';
import '../../core/notifications/local_reminders.dart';
import 'data/tournament_models.dart';

/// The reminders a registration sets on the phone: 1 hour and 15 minutes before the start, and
/// the start itself. They work without push, and a withdraw (or a cancellation) removes them.
class TournamentReminders {
  TournamentReminders(this._scheduler, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final ReminderScheduler _scheduler;
  final DateTime Function() _now;

  /// How long before the start each reminder fires, in slot order.
  static const offsets = [Duration(hours: 1), CheckInWindow.opensBefore, Duration.zero];

  /// A stable notification id for [tournamentId]'s reminder [slot] (FNV-1a, so it is the same
  /// on every run and a withdraw after a restart still finds it).
  static int idFor(String tournamentId, int slot) {
    var hash = 0x811c9dc5;
    for (final unit in '$tournamentId#$slot'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  /// The reminders for [tournament] still ahead of now.
  List<LocalReminder> remindersFor(Tournament tournament) {
    final now = _now();
    final route = Routes.tournament(tournament.id);
    final title = tournament.title;
    return [
      for (final (slot, offset) in offsets.indexed)
        if (tournament.startsAt.subtract(offset).isAfter(now))
          LocalReminder(
            id: idFor(tournament.id, slot),
            at: tournament.startsAt.subtract(offset),
            route: route,
            title: switch (slot) {
              0 => '$title starts in 1 hour',
              1 => 'Check in for $title',
              _ => '$title is starting',
            },
            body: switch (slot) {
              0 => 'Check-in opens 15 minutes before the start.',
              1 => 'Check-in is open until 2 minutes before the start. Tap to check in.',
              _ => 'Round 1 is being paired. Open the app to join your game.',
            },
          ),
    ];
  }

  /// Schedules [tournament]'s reminders, asking for permission first. Returns the answer, so
  /// the screen can say reminders are off.
  Future<ReminderPermission> scheduleFor(Tournament tournament) async {
    final permission = await _scheduler.ensurePermission();
    if (permission != ReminderPermission.granted) return permission;
    for (final reminder in remindersFor(tournament)) {
      await _scheduler.schedule(reminder);
    }
    return permission;
  }

  /// Removes every reminder of [tournamentId] (after a withdraw or a cancellation).
  Future<void> cancelFor(String tournamentId) async {
    for (var slot = 0; slot < offsets.length; slot++) {
      await _scheduler.cancel(idFor(tournamentId, slot));
    }
  }

  /// The calendar entry "Add to calendar" offers: from the start to the estimated end.
  static CalendarEvent calendarEvent(Tournament tournament) => CalendarEvent(
    title: tournament.title,
    start: tournament.startsAt,
    end:
        tournament.endsAtEstimate ??
        tournament.startsAt.add(Duration(minutes: 5 * tournament.rounds + 5)),
    description:
        'Quiz Arena tournament: ${tournament.rounds} rounds of 10 questions. Check in from '
        '15 to 2 minutes before the start. quizarena://open/t/${tournament.id}',
  );
}

/// Opens the screen of a tapped reminder: pushed while the app runs, and as the start
/// destination when a reminder launched the app (the router keeps it through the gates).
final reminderTapsProvider = Provider<void>((ref) {
  final scheduler = ref.watch(reminderSchedulerProvider);
  final router = ref.read(routerProvider);
  final taps = scheduler.taps.listen((route) => unawaited(router.push(route)));
  ref.onDispose(taps.cancel);
  unawaited(
    scheduler.launchRoute().then((route) {
      if (route != null && ref.mounted) router.go(route);
    }),
  );
});

final tournamentRemindersProvider = Provider<TournamentReminders>(
  (ref) =>
      TournamentReminders(ref.watch(reminderSchedulerProvider), now: ref.watch(liveClockProvider)),
);
