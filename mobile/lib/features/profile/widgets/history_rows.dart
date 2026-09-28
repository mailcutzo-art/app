import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/time_text.dart';
import '../../battle/match/match_widgets.dart' show avatarOf;
import '../../common/paged_list.dart' show RowIcon;
import '../data/profile_models.dart';

/// "Physics", "Organic chemistry" for a subject slug.
String _subject(String? slug) => slug == null ? 'Battle' : scopeLabel(slug);

/// One battle in the history: who, what, when, the result and the rating change. Games that
/// were played out open their review.
class MatchHistoryRow extends StatelessWidget {
  const MatchHistoryRow({super.key, required this.match, this.onTap});

  final MatchHistoryItem match;
  final VoidCallback? onTap;

  String get _title {
    if (match.kind == 'group' || match.opponents.length > 1) {
      final place = match.place;
      return place == null ? 'Group battle' : 'Group battle · #$place';
    }
    final opponent = match.opponents.firstOrNull;
    final name = opponent == null
        ? null
        : (opponent.isBot ? 'Practice Bot' : opponent.displayName ?? opponent.handle);
    return name == null ? 'Battle' : 'vs $name';
  }

  static (String, PastelTone) _result(String? result) => switch (result) {
    'win' => ('Won', PastelTone.mint),
    'loss' => ('Lost', PastelTone.rose),
    'draw' => ('Draw', PastelTone.sky),
    'aborted' => ('Cancelled', PastelTone.neutral),
    'voided' => ('Voided', PastelTone.neutral),
    _ => ('Played', PastelTone.neutral),
  };

  @override
  Widget build(BuildContext context) {
    final (label, tone) = _result(match.result);
    final score = match.scoreMe == null
        ? null
        : '${match.scoreMe}${match.scoreOther == null ? '' : '–${match.scoreOther}'}';
    return ListRowCard(
      title: _title,
      subtitle: [
        _subject(match.subject),
        ?match.chapters.firstOrNull,
        ?score,
        relativeTime(match.playedAt),
      ].join(' · '),
      leading: AppAvatar(data: avatarOf(match.opponents.firstOrNull)),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          OverlineBadge(label: label, tone: tone),
          if (match.ratingDelta case final delta? when delta != 0) ...[
            const SizedBox(height: 4),
            RatingDelta(delta: delta),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

/// One practice session: its title, how it went, and Continue while it's still open.
class PracticeHistoryRow extends StatelessWidget {
  const PracticeHistoryRow({super.key, required this.session, this.onTap});

  final PracticeHistoryItem session;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final score = switch ((session.score, session.maxScore)) {
      (final score?, final max?) => '$score/$max',
      _ => '${session.correct}/${session.answered}',
    };
    return ListRowCard(
      title: session.title.isEmpty ? 'Practice' : session.title,
      subtitle: [
        '${session.answered} answered · ${session.correct} correct',
        relativeTime(session.finishedAt ?? session.createdAt),
      ].join(' · '),
      leading: const RowIcon(icon: AppIcons.learn, tone: PastelTone.lavender),
      trailing: session.finished
          ? Text(score, style: text.numericMedium)
          : const OverlineBadge(label: 'Continue', tone: PastelTone.lime),
      onTap: onTap,
    );
  }
}

/// Someone played recently, with your record against them; opens their public profile
/// (the `/u/<handle>` link).
class OpponentRow extends StatelessWidget {
  const OpponentRow({super.key, required this.opponent});

  final RecentOpponent opponent;

  @override
  Widget build(BuildContext context) {
    final user = opponent.user;
    final handle = user.handle;
    final name = user.displayName ?? (handle == null ? 'Player' : '@$handle');
    return ListRowCard(
      title: name,
      subtitle: [
        'You ${opponent.h2h.compact}',
        if (opponent.relationship == 'friend') 'Friend',
        if (opponent.lastPlayedAt case final at?) relativeTime(at),
      ].join(' · '),
      leading: AppAvatar(data: avatarOf(user)),
      trailing: handle == null
          ? null
          : HugeIcon(AppIcons.chevronRight, size: 20, color: context.colors.inkMuted),
      onTap: handle == null ? null : () => context.go('/u/${Uri.encodeComponent(handle)}'),
    );
  }
}
