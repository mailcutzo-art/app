import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart' hide AnswerOption;

import '../../../core/auth/session.dart';
import '../../../core/realtime/live_match.dart';
import '../../rooms/room_text.dart';
import 'match_widgets.dart';

/// "Riya", "You", or "A player" for [uid] in [view].
String playerName(MatchView view, String uid) {
  if (uid == view.me) return 'You';
  final card = view.state.players[uid]?.card;
  return card?.displayName ?? card?.handle ?? 'A player';
}

/// Why a group battle ended, when it wasn't played to the end.
String? groupEndReason(MatchOutcome outcome) => switch (outcome.reason) {
  MatchEndReason.endedByHost => 'The host ended the game early',
  MatchEndReason.forfeit ||
  MatchEndReason.left when outcome.result == MatchResult.loss => 'You left the game',
  MatchEndReason.disconnected => 'Too few players stayed connected',
  MatchEndReason.aborted => 'The game didn\'t start',
  MatchEndReason.voided => 'This game didn\'t count',
  _ => null,
};

/// One row of a group battle's final ranking.
@immutable
class RankedPlayer {
  const RankedPlayer({
    required this.uid,
    required this.place,
    required this.points,
    required this.correct,
  });

  final String uid;

  /// 1 for the winner; players who tie share a place.
  final int place;
  final int points;
  final int correct;
}

/// The final order: `match.end.ranking` when there is one, otherwise the totals (points, then
/// correct answers). Players missing from the ranking come last.
List<RankedPlayer> finalRanking(MatchView view) {
  final totals = view.outcome?.totals.isNotEmpty ?? false
      ? view.outcome!.totals
      : view.state.totals;
  final uids = {...view.state.players.keys, ...totals.keys};
  final ranking = view.outcome?.ranking ?? const [];
  final rows = <RankedPlayer>[];
  final placed = <String>{};
  var place = 1;
  for (final group in ranking) {
    for (final uid in group) {
      final t = totals[uid] ?? PlayerTotals.zero;
      rows.add(RankedPlayer(uid: uid, place: place, points: t.points, correct: t.correct));
      placed.add(uid);
    }
    place += group.length;
  }
  final rest = [
    for (final uid in uids)
      if (!placed.contains(uid)) uid,
  ];
  rest.sort((a, b) {
    final ta = totals[a] ?? PlayerTotals.zero;
    final tb = totals[b] ?? PlayerTotals.zero;
    final byPoints = tb.points.compareTo(ta.points);
    return byPoints != 0 ? byPoints : tb.correct.compareTo(ta.correct);
  });
  for (final uid in rest) {
    final t = totals[uid] ?? PlayerTotals.zero;
    final ahead = rows.where(
      (r) => r.points > t.points || (r.points == t.points && r.correct > t.correct),
    );
    rows.add(RankedPlayer(uid: uid, place: ahead.length + 1, points: t.points, correct: t.correct));
  }
  return rows;
}

/// The group battle's header while questions run: the question, my points and place, and who
/// has answered (never what).
class GroupHeader extends ConsumerWidget {
  const GroupHeader({super.key, required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.text;
    final state = view.state;
    final me = ref.watch(meProvider);
    final open = state.phase == MatchPhase.qOpen;
    final players = state.players.values.toList();
    final answered = players.where((p) => state.answered.contains(p.uid)).length;
    final place = view.isSpectator ? null : state.placeOf(view.me);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!view.isSpectator) ...[
                AppAvatar(data: me.avatar.toData(), size: 40),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      NumberTicker(value: view.myTotals.points, style: text.numericMedium),
                      Text('${RoomText.ordinal(place!)} of ${players.length}', style: text.caption),
                    ],
                  ),
                ),
              ] else
                Expanded(child: Text('Watching', style: text.titleMedium)),
              OverlineBadge(label: 'Q ${state.q < 1 ? 1 : state.q} / ${state.total}', solid: true),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            label: open ? '$answered of ${players.length} answered' : null,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final player in players) ...[
                    _Seat(
                      avatar: avatarOf(player.card),
                      answered: open && state.answered.contains(player.uid),
                      away: player.presence != Presence.connected,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  if (open) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Text('$answered/${players.length} answered', style: text.caption),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Seat extends StatelessWidget {
  const _Seat({required this.avatar, required this.answered, required this.away});

  final AvatarData avatar;
  final bool answered;
  final bool away;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Opacity(
      opacity: away ? 0.4 : 1,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppAvatar(data: avatar, size: 30),
          if (answered)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: colors.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.surface, width: 1.5),
                ),
                alignment: Alignment.center,
                child: HugeIcon(AppIcons.check, size: 10, color: colors.surface),
              ),
            ),
        ],
      ),
    );
  }
}

/// Between questions, when the room has the leaderboard on: the top 3, my place if I'm not
/// among them, and the change since the last question.
class MiniLeaderboard extends StatelessWidget {
  const MiniLeaderboard({super.key, required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context) {
    final standings = view.state.standings;
    if (standings.isEmpty) return const SizedBox.shrink();
    final top = standings.take(3).toList();
    final mine = standings.where((s) => s.uid == view.me).firstOrNull;
    final rows = [...top, if (mine != null && !top.any((s) => s.uid == view.me)) mine];
    return Semantics(
      container: true,
      label: 'Leaderboard',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final standing in rows) ...[
            _StandingRow(view: view, standing: standing),
            const SizedBox(height: AppSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _StandingRow extends StatelessWidget {
  const _StandingRow({required this.view, required this.standing});

  final MatchView view;
  final GroupStanding standing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final isMe = standing.uid == view.me;
    final change = standing.change;
    final changeText = change > 0 ? '↑$change' : (change < 0 ? '↓${-change}' : '–');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
      decoration: BoxDecoration(
        color: isMe ? colors.accentSoft : colors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${standing.place}', style: text.numericMedium.copyWith(fontSize: 14)),
          ),
          AppAvatar(data: avatarOf(view.state.players[standing.uid]?.card), size: 26),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              playerName(view, standing.uid),
              style: text.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text('${standing.points}', style: text.numericMedium.copyWith(fontSize: 14)),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 28,
            child: Text(
              changeText,
              textAlign: TextAlign.end,
              style: text.caption.copyWith(
                color: change > 0 ? colors.success : (change < 0 ? colors.error : null),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "You're watching": a late joiner after halfway sees the questions but can't answer.
class SpectatorBanner extends StatelessWidget {
  const SpectatorBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.sky.container,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            HugeIcon(AppIcons.view, size: 18, color: colors.sky.onContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'You joined after halfway, so you\'re watching this game. You\'ll play the next one.',
                style: context.text.labelMedium.copyWith(color: colors.sky.onContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The players of a group battle before it starts, instead of a 1v1 VS.
class GroupLineup extends StatelessWidget {
  const GroupLineup({super.key, required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final players = view.state.players.values.toList();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: AppSpacing.lg,
      runSpacing: AppSpacing.lg,
      children: [
        for (final player in players)
          SizedBox(
            width: 76,
            child: Column(
              children: [
                AppAvatar(data: avatarOf(player.card), size: 60, ring: player.uid == view.me),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  playerName(view, player.uid),
                  style: text.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The end of a group battle: "You finished 4th of 7", the podium, and the full ranking with
/// points and correct answers.
class GroupStandingsView extends StatelessWidget {
  const GroupStandingsView({super.key, required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final ranking = finalRanking(view);
    final mine = ranking.where((r) => r.uid == view.me).firstOrNull;
    final outcome = view.outcome;
    final reason = outcome == null ? null : groupEndReason(outcome);
    final String title;
    if (mine == null) {
      title = 'Game over';
    } else if (mine.place == 1) {
      title = ranking.where((r) => r.place == 1).length > 1 ? 'Shared first place!' : 'You won!';
    } else {
      title = 'You finished ${RoomText.ordinal(mine.place)} of ${ranking.length}';
    }
    final pair = mine?.place == 1 ? colors.mint : colors.sky;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            color: pair.container,
            borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
          ),
          child: Column(
            children: [
              Semantics(
                header: true,
                child: Text(title, style: text.headlineLarge, textAlign: TextAlign.center),
              ),
              if (reason != null)
                Text(
                  reason,
                  style: text.labelMedium.copyWith(color: pair.onContainer),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: AppSpacing.xl),
              Podium(
                entries: [
                  for (final row in ranking.take(3))
                    PodiumEntry(
                      name: playerName(view, row.uid),
                      score: '${row.points} pts',
                      avatar: avatarOf(view.state.players[row.uid]?.card),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Final ranking', style: text.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        for (final row in ranking) ...[
          LeaderboardRow(
            rank: row.place,
            name: row.uid == view.me
                ? (view.myCard?.displayName ?? 'You')
                : playerName(view, row.uid),
            score: '${row.points}',
            subtitle: row.correct == 1 ? '1 correct' : '${row.correct} correct',
            avatar: avatarOf(view.state.players[row.uid]?.card),
            highlight: row.uid == view.me,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}
