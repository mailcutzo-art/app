import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/auth/session.dart';
import '../../../core/auth/user.dart';
import '../../../core/network/paging.dart';
import '../../../core/utils/time_text.dart';
import '../../common/paged_list.dart';
import '../../learn/widgets/learn_widgets.dart' show RowsSkeleton, failureMessage;
import '../arena_providers.dart';
import '../arena_text.dart';
import '../data/tournament_models.dart';
import '../tournament_live.dart';
import 'arena_widgets.dart';

/// One standings line as the screen draws it, from REST or the live feed.
@immutable
class StandingLine {
  const StandingLine({
    required this.rank,
    required this.userId,
    required this.name,
    required this.avatar,
    required this.points,
    this.record,
    this.withdrawn = false,
    this.handle,
  });

  factory StandingLine.fromRow(StandingRow row) => StandingLine(
    rank: row.position,
    userId: row.user.id,
    name: row.user.displayName,
    handle: row.user.handle,
    avatar: row.user.avatar,
    points: row.points,
    record: row.record,
    withdrawn: row.withdrawn,
  );

  factory StandingLine.fromLive(LiveStandingRow row) => StandingLine(
    rank: row.rank,
    userId: row.uid,
    name: row.name,
    avatar: row.avatar,
    points: row.points,
    record: row.record,
  );

  final int rank;
  final String userId;
  final String name;
  final String? handle;
  final Avatar avatar;
  final num points;
  final TournamentRecord? record;
  final bool withdrawn;
}

/// A standings line.
class StandingTile extends StatelessWidget {
  const StandingTile({super.key, required this.line, this.me = false});

  final StandingLine line;
  final bool me;

  @override
  Widget build(BuildContext context) {
    final record = line.record;
    final handle = line.handle;
    return LeaderboardRow(
      rank: line.rank,
      name: line.name,
      avatar: line.avatar.toData(),
      score: '${formatPoints(line.points)} pts',
      subtitle: line.withdrawn ? 'Withdrew' : record?.display,
      highlight: me,
      onTap: me || handle == null
          ? null
          : () => unawaited(context.push(Routes.userProfile(handle))),
    );
  }
}

/// The standings on screen: the live feed while it's there, otherwise the REST pages.
({List<StandingLine> lines, StandingLine? me, bool live}) standingsFor(
  WidgetRef ref,
  String id, {
  required bool live,
}) {
  final feed = live ? ref.watch(liveStandingsProvider(id)) : null;
  if (feed != null) {
    return (
      lines: [for (final row in feed.rows) StandingLine.fromLive(row)],
      me: feed.me == null ? null : StandingLine.fromLive(feed.me!),
      live: true,
    );
  }
  final rest = ref.watch(standingsProvider(id)).value;
  return (
    lines: [for (final row in rest?.rows ?? const <StandingRow>[]) StandingLine.fromRow(row)],
    me: rest?.me == null ? null : StandingLine.fromRow(rest!.me!),
    live: false,
  );
}

/// The Standings tab.
class StandingsSection extends ConsumerWidget {
  const StandingsSection({super.key, required this.detail});

  final TournamentDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = detail.id;
    final t = detail.tournament;
    final started = t.status.isLive || t.status.isOver;
    if (!started) {
      return SurfaceCard(
        child: EmptyState(
          icon: AppIcons.chart,
          tone: tournamentTone(t),
          title: 'Standings start with round 1',
          message: '${t.players} of ${t.capacity} registered so far.',
        ),
      );
    }
    final myId = ref.watch(currentUserIdProvider);
    final shown = standingsFor(ref, id, live: t.status.isLive);
    if (shown.live) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in shown.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: StandingTile(line: line, me: line.userId == myId),
            ),
        ],
      );
    }
    final rest = ref.watch(standingsProvider(id));
    return switch (rest) {
      AsyncValue(:final value?) when value.rows.isEmpty => SurfaceCard(
        child: EmptyState(
          icon: AppIcons.chart,
          tone: tournamentTone(t),
          title: 'No standings yet',
          message: 'They fill in as round 1 finishes.',
        ),
      ),
      AsyncValue(:final value?) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in value.rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: StandingTile(line: StandingLine.fromRow(row), me: row.user.id == myId),
            ),
          _StandingsFooter(id: id, view: value),
        ],
      ),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load the standings',
        message: failureMessage(error),
        retrying: rest.isLoading,
        onRetry: () => ref.invalidate(standingsProvider(id)),
      ),
      _ => const RowsSkeleton(rows: 5),
    };
  }
}

class _StandingsFooter extends ConsumerWidget {
  const _StandingsFooter({required this.id, required this.view});

  final String id;
  final StandingsView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PagedFooter(
    paged: Paged<StandingRow>(
      items: view.rows,
      nextCursor: view.nextCursor,
      loadingMore: view.loadingMore,
      moreError: view.moreError,
    ),
    manual: true,
    onLoadMore: () => unawaited(ref.read(standingsProvider(id).notifier).loadMore()),
  );
}

/// The viewer's own line, pinned under the Standings tab when it isn't among the rows shown.
class StickyMeRow extends ConsumerWidget {
  const StickyMeRow({super.key, required this.detail});

  final TournamentDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = detail.tournament;
    if (!(t.status.isLive || t.status.isOver)) return const SizedBox.shrink();
    final shown = standingsFor(ref, detail.id, live: t.status.isLive);
    final me = shown.me;
    if (me == null || shown.lines.any((line) => line.userId == me.userId)) {
      return const SizedBox.shrink();
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.paper,
        boxShadow: AppShadows.floating(context.colors),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: StandingTile(line: me, me: true),
        ),
      ),
    );
  }
}

/// The Overview tab: what it is, the rules, the rounds, and the prizes for the current field.
class OverviewSection extends StatelessWidget {
  const OverviewSection({super.key, required this.detail});

  final TournamentDetail detail;

  @override
  Widget build(BuildContext context) {
    final t = detail.tournament;
    final rules = detail.rules;
    final text = context.text;
    final colors = context.colors;
    final now = DateTime.now();
    Widget line(HugeIconData icon, String label) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HugeIcon(icon, size: 18, color: colors.inkMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(label, style: text.bodyMedium)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (detail.description case final description?) ...[
          Text(description, style: text.bodyLarge),
          const SizedBox(height: AppSpacing.lg),
        ],
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Rules', style: text.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              line(
                AppIcons.quiz,
                '${rules.questions} questions × ${rules.secondsPerQuestion} s per game'
                '${rules.rated ? ', rated (overall and subject)' : ''}',
              ),
              line(
                AppIcons.checklist,
                'Swiss format: ${detail.totalRounds} rounds, paired by score. No rematches.',
              ),
              line(
                AppIcons.timer,
                'Join within ${rules.readySeconds} s of your round starting, or it\'s a forfeit.',
              ),
              line(
                AppIcons.star,
                'Win 1 point, draw ${formatPoints(rules.drawPoints)}, bye '
                '${formatPoints(rules.byePoints)}.',
              ),
              line(AppIcons.checkCircle, 'Check in 15 to 2 minutes before the start.'),
              line(
                AppIcons.coins,
                t.isFree
                    ? 'Free entry.'
                    : '${feeLabel(t.entryFee)} entry, held until the start. Full refund if you '
                          'withdraw before it.',
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Details', style: text.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              line(AppIcons.graduation, 'For ${t.goal.label} · ${subjectName(t.subject)}'),
              line(AppIcons.calendar, 'Starts ${startDay(t.startsAt, now)}'),
              line(
                AppIcons.social,
                '${t.players} of ${t.capacity} players · needs ${t.minPlayers} to start',
              ),
            ],
          ),
        ),
        if (detail.schedule.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Schedule', style: text.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                for (final round in detail.schedule)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(
                      children: [
                        Expanded(child: Text('Round ${round.round}', style: text.bodyMedium)),
                        Text(switch (round.status) {
                          RoundStatus.done => 'Done',
                          RoundStatus.live => 'Live now',
                          RoundStatus.pairing => 'Pairing',
                          RoundStatus.upcoming => switch (round.startsAt) {
                            final at? => 'About ${clockTime(at)}',
                            null => 'Later',
                          },
                        }, style: text.labelMedium),
                      ],
                    ),
                  ),
                Text(
                  'Times after round 1 are estimates: each round starts 90 s after the last '
                  'game ends.',
                  style: text.caption,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        _Prizes(detail: detail),
      ],
    );
  }
}

class _Prizes extends StatelessWidget {
  const _Prizes({required this.detail});

  final TournamentDetail detail;

  @override
  Widget build(BuildContext context) {
    final t = detail.tournament;
    final text = context.text;
    final prizes = detail.prizes;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Prizes', style: text.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            prizes.isEmpty
                ? 'Prizes are paid once at least 4 players take part.'
                : 'For ${t.players} players. ${prizeLine(t) ?? 'Credited automatically.'}',
            style: text.caption,
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final prize in prizes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Row(
                children: [
                  Expanded(child: Text(prize.places, style: text.bodyMedium)),
                  CoinAmount(amount: prize.coins),
                  if (prize.to > prize.from) Text(' each', style: text.caption),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.xs),
          Text('Everyone earns 10 XP for each round played.', style: text.caption),
        ],
      ),
    );
  }
}

/// The My games tab: each round's opponent, result and points, with the game's review, and the
/// current pairing.
class MyGamesSection extends ConsumerWidget {
  const MyGamesSection({super.key, required this.detail});

  final TournamentDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = detail.tournament;
    if (!(t.me?.registered ?? false)) {
      return SurfaceCard(
        child: EmptyState(
          icon: AppIcons.battle,
          tone: tournamentTone(t),
          title: 'You\'re not playing in this one',
          message: t.status.takesEntries
              ? 'Register to play every round here.'
              : 'Your games show up here in tournaments you enter.',
        ),
      );
    }
    final games = ref.watch(myGamesProvider(detail.id));
    return switch (games) {
      AsyncValue(:final value?) when value.rounds.isEmpty && value.current == null => SurfaceCard(
        child: EmptyState(
          icon: AppIcons.battle,
          tone: tournamentTone(t),
          title: 'No games yet',
          message: 'Round 1 is paired at the start. Each game appears here.',
        ),
      ),
      AsyncValue(:final value?) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final game in value.rounds.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: RoundGameRow(game: game, current: value.current),
            ),
        ],
      ),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load your games',
        message: failureMessage(error),
        retrying: games.isLoading,
        onRetry: () => ref.invalidate(myGamesProvider(detail.id)),
      ),
      _ => const RowsSkeleton(rows: 3),
    };
  }
}

/// One round in My games.
class RoundGameRow extends StatelessWidget {
  const RoundGameRow({super.key, required this.game, this.current});

  final RoundGame game;
  final Pairing? current;

  @override
  Widget build(BuildContext context) {
    final matchId = game.matchId;
    final playing = game.result == null && !game.bye && matchId != null;
    final points = game.points;
    final title = game.bye
        ? 'Round ${game.round} · bye'
        : 'Round ${game.round} · vs ${game.opponent?.displayName ?? 'your opponent'}';
    final subtitle = switch (game) {
      RoundGame(bye: true) => 'You had a bye · +${formatPoints(points ?? 1)} point',
      RoundGame(result: null) when playing => 'Your game is on',
      RoundGame(result: null) => 'Waiting to start',
      RoundGame(:final result?) => [
        switch (result) {
          GameResult.win => game.noShow ? 'Win (no-show)' : 'Win',
          GameResult.draw => 'Draw',
          GameResult.loss => game.noShow ? 'Loss (didn\'t join)' : 'Loss',
        },
        '+${formatPoints(points ?? 0)} ${points == 1 ? 'point' : 'points'}',
      ].join(' · '),
    };
    final (icon, tone) = switch (game.result) {
      _ when game.bye => (AppIcons.hourglass, PastelTone.lemon),
      GameResult.win => (AppIcons.crown, PastelTone.mint),
      GameResult.draw => (AppIcons.thumbsUp, PastelTone.lemon),
      GameResult.loss => (AppIcons.sad, PastelTone.rose),
      null => (AppIcons.battle, PastelTone.sky),
    };
    final String? route = switch (matchId) {
      final id? when playing => Routes.battleMatch(id),
      final id? when game.result != null && !game.noShow => Routes.battleReview(id),
      _ => null,
    };
    return ListRowCard(
      title: title,
      subtitle: subtitle,
      leading: RowIcon(icon: icon, tone: tone),
      trailing: playing
          ? const OverlineBadge(label: 'Join', tone: PastelTone.lime)
          : route == null
          ? null
          : HugeIcon(AppIcons.chevronRight, size: 18, color: context.colors.inkMuted),
      onTap: route == null ? null : () => unawaited(context.push(route)),
    );
  }
}

/// The lobby between rounds: "Round 2 of 5", the viewer's record, points and rank, the pairing
/// countdown (or the game to join, or the bye), and the top of the standings.
class LiveLobby extends ConsumerWidget {
  const LiveLobby({super.key, required this.detail, required this.onSeeStandings});

  final TournamentDetail detail;
  final VoidCallback onSeeStandings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = detail.tournament;
    final live = ref.watch(tournamentLiveProvider)[t.id];
    final me = detail.me;
    final round = live?.round;
    final number = round?.round ?? detail.currentRound ?? 1;
    final scheduled = detail.schedule.where((r) => r.round == number).firstOrNull;
    final status = round?.status ?? scheduled?.status ?? RoundStatus.pairing;
    final pairing = switch (live?.pairing) {
      final p? when p.round >= number => p,
      _ => me?.nextPairing,
    };
    final startsAt = round?.startsAt ?? scheduled?.startsAt;
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(tournamentTone(t));
    final shown = standingsFor(ref, t.id, live: true);
    final myId = ref.watch(currentUserIdProvider);
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: pair.container,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Round $number of ${detail.totalRounds}',
                      style: text.headlineMedium,
                    ),
                  ),
                ),
                const LiveBadge(),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            NowBuilder(
              builder: (context, now) => Text(
                _roundLine(status, pairing, number, startsAt, now),
                style: text.labelLarge.copyWith(color: pair.onContainer),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                _Stat(label: 'Record', value: (me?.record ?? TournamentRecord.zero).display),
                _Stat(label: 'Points', value: formatPoints(me?.points ?? 0)),
                _Stat(
                  label: 'Rank',
                  value: me?.rank == null ? '—' : '#${me!.rank} of ${t.players}',
                ),
              ],
            ),
            if (pairing != null && !pairing.bye && pairing.round == number) ...[
              const SizedBox(height: AppSpacing.lg),
              _Opponent(pairing: pairing),
            ],
            if (shown.lines.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Top of the standings', style: text.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              for (final line in shown.lines.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: StandingTile(line: line, me: line.userId == myId),
                ),
              AppButton(
                label: 'See all standings',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: onSeeStandings,
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Leaving the app is fine: the next round calls you back.',
              style: text.caption.copyWith(color: pair.onContainer),
            ),
          ],
        ),
      ),
    );
  }

  static String _roundLine(
    RoundStatus status,
    Pairing? pairing,
    int round,
    DateTime? startsAt,
    DateTime now,
  ) {
    if (pairing != null && pairing.round == round && pairing.bye) {
      return 'You have a bye this round (+1 point)';
    }
    return switch (status) {
      RoundStatus.pairing || RoundStatus.upcoming when startsAt != null && startsAt.isAfter(now) =>
        'Pairing in ${mmss(startsAt.difference(now))}',
      RoundStatus.pairing || RoundStatus.upcoming => 'Pairing now…',
      RoundStatus.live => 'Live',
      RoundStatus.done => 'Round finished · the next pairing is on its way',
    };
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: context.text.numericMedium),
        Text(label, style: context.text.caption),
      ],
    ),
  );
}

class _Opponent extends StatelessWidget {
  const _Opponent({required this.pairing});

  final Pairing pairing;

  @override
  Widget build(BuildContext context) {
    final opponent = pairing.opponent;
    final matchId = pairing.matchId;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          AppAvatar(data: (opponent?.avatar ?? Avatar.fallback).toData()),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Round ${pairing.round} opponent', style: context.text.caption),
                Text(
                  opponent?.displayName ?? 'To be paired',
                  style: context.text.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (matchId != null)
            AppButton(
              label: 'Join',
              size: AppButtonSize.small,
              expand: false,
              onPressed: () => context.go(Routes.battleMatch(matchId)),
            ),
        ],
      ),
    );
  }
}

/// A finished tournament's result for the viewer, on its screen.
class ResultSummary extends StatelessWidget {
  const ResultSummary({super.key, required this.tournament, required this.result});

  final Tournament tournament;
  final TournamentFinal result;

  @override
  Widget build(BuildContext context) => ListRowCard(
    title: 'You finished ${result.placeLine}',
    subtitle: [
      '${formatPoints(result.points)} points',
      if (result.prize > 0) '+${formatCount(result.prize)} coins',
      if (result.xp > 0) '+${result.xp} XP',
    ].join(' · '),
    leading: RowIcon(
      icon: result.rank <= 3 ? AppIcons.medal : AppIcons.award,
      tone: tournamentTone(tournament),
    ),
    trailing: HugeIcon(AppIcons.chevronRight, size: 18, color: context.colors.inkMuted),
    onTap: () => unawaited(context.push(Routes.tournamentResults(tournament.id))),
  );
}
