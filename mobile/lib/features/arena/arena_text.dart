/// What the Arena says about a tournament, as pure functions of the card and the time.
library;

import 'package:design_system/design_system.dart';

import '../../core/auth/user.dart';
import '../../core/utils/time_text.dart';
import 'data/tournament_models.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Physics", "Chemistry", or "All subjects".
String subjectName(String? subject) => switch (subject) {
  null || '' || 'all' => 'All subjects',
  final s => '${s[0].toUpperCase()}${s.substring(1)}',
};

/// The card's pastel tone; unknown names fall back to the subject's colour.
PastelTone tournamentTone(Tournament t) {
  final named = PastelTone.values.where((tone) => tone.name == t.tone).firstOrNull;
  if (named != null) return named;
  return switch (t.subject) {
    'physics' => PastelTone.sky,
    'chemistry' => PastelTone.lavender,
    'biology' => PastelTone.mint,
    'maths' => PastelTone.peach,
    _ => PastelTone.lemon,
  };
}

/// "in 12 min", "in 2 h 5 min".
String inDuration(Duration d) {
  if (d.inSeconds < 60) return 'in under a minute';
  if (d.inMinutes < 60) return 'in ${d.inMinutes} min';
  final minutes = d.inMinutes % 60;
  return minutes == 0 ? 'in ${d.inHours} h' : 'in ${d.inHours} h $minutes min';
}

/// "0:48", "12:05".
String mmss(Duration d) {
  final seconds = d.inSeconds.clamp(0, 99 * 60 + 59);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// "Today, 18:30", "Tomorrow, 07:00", "Sat 3 Oct, 19:00".
String startDay(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = day.difference(today).inDays;
  final time = clockTime(local);
  return switch (days) {
    0 => 'Today, $time',
    1 => 'Tomorrow, $time',
    -1 => 'Yesterday, $time',
    _ => '${_weekdays[local.weekday - 1]} ${shortDate(local, now: now)}, $time',
  };
}

/// When the tournament starts, as the card puts it: "Starts in 12 min" within the hour, else
/// the day and time; "Started 18:30" once live, "Ended 3 Oct" when over.
String startLine(Tournament t, DateTime now) {
  final until = t.startsAt.difference(now);
  if (t.status.isLive) return 'Started ${clockTime(t.startsAt)}';
  if (t.status == TournamentStatus.cancelled) return 'Was ${startDay(t.startsAt, now)}';
  if (t.status.isOver) return 'Ended ${shortDate(t.endsAtEstimate ?? t.startsAt, now: now)}';
  if (!until.isNegative && until < const Duration(hours: 1)) return 'Starts ${inDuration(until)}';
  if (until.isNegative) return 'Starting now';
  return startDay(t.startsAt, now);
}

/// "5 of 8 needed", while the field is still too small to go ahead.
String? neededLine(Tournament t) {
  if (t.status.isLive || t.status.isOver || t.needed == 0) return null;
  return '${t.players} of ${t.minPlayers} needed';
}

/// "Prize now 625 of 2,500 · grows with players" while the pool is still growing.
String? prizeLine(Tournament t) {
  if (!t.poolGrows || t.status.isOver) return null;
  return 'Prize now ${formatCount(t.poolNow)} of ${formatCount(t.prizePool)} · grows with players';
}

/// The status badge: its label and icon.
({String label, HugeIconData icon})? statusBadge(Tournament t, DateTime now) => switch (t.status) {
  TournamentStatus.scheduled => (
    label: t.regOpensAt == null ? 'Coming up' : 'Opens ${startDay(t.regOpensAt!, now)}',
    icon: AppIcons.calendar,
  ),
  TournamentStatus.regOpen => (label: 'Registration', icon: AppIcons.clock),
  TournamentStatus.checkIn => (label: 'Check-in open', icon: AppIcons.checkCircle),
  TournamentStatus.locked => (label: 'Locked', icon: AppIcons.lock),
  // The LIVE badge says it.
  TournamentStatus.running || TournamentStatus.finalizing => null,
  TournamentStatus.finished => (label: 'Finished', icon: AppIcons.award),
  TournamentStatus.cancelled => (label: 'Cancelled', icon: AppIcons.close),
};

/// What the card's button does.
enum CardAction {
  register('Register'),
  registered('Registered'),
  checkIn('Check in'),
  checkedIn('Checked in'),
  full('Full'),
  otherExam('Not your exam'),
  locked('Locked'),
  open('Open'),
  watch('Watch'),
  results('Results'),
  view('View');

  const CardAction(this.label);

  final String label;

  /// Filled (ink) rather than outlined.
  bool get primary => this == register || this == checkIn || this == open;

  /// Pressable at all (Full, Locked and the other exam are shown disabled).
  bool get enabled => this != full && this != otherExam && this != locked;
}

/// The button a card shows for [t] at [now], for a player preparing for [goal].
CardAction cardAction(Tournament t, DateTime now, {Goal? goal}) {
  final status = t.status;
  if (status.isLive) return t.entered ? CardAction.open : CardAction.watch;
  if (status.isOver) return t.entered ? CardAction.results : CardAction.view;
  if (t.entered) {
    if (t.checkedIn) return CardAction.checkedIn;
    return t.checkInOpen(now) ? CardAction.checkIn : CardAction.registered;
  }
  if (status == TournamentStatus.locked) return CardAction.locked;
  if (!status.takesEntries) return CardAction.view;
  if (!t.goal.admits(goal)) return CardAction.otherExam;
  if (t.isFull) return CardAction.full;
  return CardAction.register;
}

/// "Free" or "25 coins".
String feeLabel(int fee) => fee == 0 ? 'Free' : '${formatCount(fee)} coins';

/// "Physics · NEET", "All subjects · NEET & JEE".
String subjectExamLine(Tournament t) => '${subjectName(t.subject)} · ${t.goal.label}';
