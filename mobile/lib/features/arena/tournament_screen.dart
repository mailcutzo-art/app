import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../../core/network/paging.dart';
import '../../core/utils/time_text.dart';
import '../learn/widgets/learn_widgets.dart' show CardSkeleton, RowsSkeleton, failureMessage;
import 'arena_providers.dart';
import 'arena_text.dart';
import 'data/tournament_models.dart';
import 'tournament_actions_ui.dart';
import 'tournament_live.dart';
import 'widgets/arena_widgets.dart';
import 'widgets/tournament_sections.dart';

/// The tabs of a tournament.
enum TournamentTab {
  overview('Overview'),
  standings('Standings'),
  games('My games');

  const TournamentTab(this.label);

  final String label;

  static TournamentTab parse(String? value) => switch (value) {
    'standings' => standings,
    'games' || 'me' => games,
    _ => overview,
  };
}

/// One tournament (`/arena/:id`, also `/t/<id>`): its header (the card's shared element), what
/// to do now (register, check in, the live lobby, the result), and the Overview, Standings and
/// My games tabs. `?tab=standings` or `?tab=games` opens a tab.
class TournamentScreen extends ConsumerStatefulWidget {
  const TournamentScreen({super.key, required this.id, this.initial, this.tab});

  final String id;

  /// The card the user tapped, drawn at once while the detail loads.
  final Tournament? initial;
  final String? tab;

  @override
  ConsumerState<TournamentScreen> createState() => _TournamentScreenState();
}

class _TournamentScreenState extends ConsumerState<TournamentScreen> {
  late TournamentTab _tab = TournamentTab.parse(widget.tab);

  Future<void> _refresh() async {
    final actions = ref.read(tournamentActionsProvider)..refresh(widget.id);
    await settle(ref.read(tournamentDetailProvider(widget.id).future));
    if (ref.read(liveStandingsProvider(widget.id)) != null) {
      await ref.read(liveStandingsProvider(widget.id).notifier).subscribe();
    }
    if (mounted && ref.read(tournamentDetailProvider(widget.id)).hasError) {
      showAppToast(context, 'Couldn\'t refresh. Try again in a moment.');
    }
    actions.refreshLists();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    final detail = ref.watch(tournamentDetailProvider(id));
    // The live layer's pill and alerts need to know the tournament.
    ref.listen(tournamentDetailProvider(id), (_, next) {
      final value = next.value;
      if (value == null) return;
      final t = value.tournament;
      final playing = t.status.isLive && t.entered;
      ref.read(tournamentLiveProvider.notifier)
        ..remember(t.id, t.title)
        ..markRunning(t.id, running: playing);
    });
    final card = detail.value?.tournament ?? widget.initial;
    return Scaffold(
      appBar: AppTopBar(title: card?.title ?? 'Tournament'),
      bottomNavigationBar: switch (detail.value) {
        final value? when _tab == TournamentTab.standings => StickyMeRow(detail: value),
        _ => null,
      },
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.xxxl,
          ),
          children: [
            if (card != null) ...[
              _Header(tournament: card),
              const SizedBox(height: AppSpacing.lg),
            ] else if (!detail.hasError) ...[
              const CardSkeleton(height: 190),
              const SizedBox(height: AppSpacing.lg),
            ],
            ...switch (detail) {
              AsyncValue(:final value?) => _content(value),
              AsyncValue(:final error?) => [
                ErrorState(
                  title: error is NotFoundFailure
                      ? 'This tournament isn\'t available'
                      : 'Couldn\'t load this tournament',
                  message: failureMessage(error),
                  retrying: detail.isLoading,
                  onRetry: () => ref.invalidate(tournamentDetailProvider(id)),
                ),
              ],
              _ => [
                const CardSkeleton(height: 120),
                const SizedBox(height: AppSpacing.lg),
                const RowsSkeleton(rows: 3),
              ],
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _content(TournamentDetail detail) {
    final t = detail.tournament;
    final entry = t.me;
    final playing = t.status.isLive && t.entered;
    final result = detail.me?.result ?? ref.watch(tournamentLiveProvider)[t.id]?.result;
    return [
      if (playing) ...[
        LiveLobby(
          detail: detail,
          onSeeStandings: () => setState(() => _tab = TournamentTab.standings),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
      if (result != null && (entry?.registered ?? false)) ...[
        ResultSummary(tournament: t, result: result),
        const SizedBox(height: AppSpacing.lg),
      ],
      _Actions(tournament: t),
      const SizedBox(height: AppSpacing.xl),
      AppSegmentedControl<TournamentTab>(
        segments: [
          for (final tab in TournamentTab.values) AppSegment(value: tab, label: tab.label),
        ],
        selected: _tab,
        onChanged: (tab) => setState(() => _tab = tab),
      ),
      const SizedBox(height: AppSpacing.lg),
      switch (_tab) {
        TournamentTab.overview => OverviewSection(detail: detail),
        TournamentTab.standings => StandingsSection(detail: detail),
        TournamentTab.games => MyGamesSection(detail: detail),
      },
    ];
  }
}

/// The pastel header: badges, title, subject and exam, when, and the numbers.
class _Header extends StatelessWidget {
  const _Header({required this.tournament});

  final Tournament tournament;

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final tone = tournamentTone(t);
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(tone);
    return Hero(
      tag: tournamentHeroTag(t.id),
      flightShuttleBuilder: (_, _, _, _, _) => tournamentHeroShuttle(tone),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            borderRadius: AppRadii.tile,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [pair.container, Color.lerp(pair.container, colors.surface, 0.55)!],
            ),
          ),
          child: NowBuilder(
            every: const Duration(seconds: 15),
            builder: (context, now) {
              final badge = statusBadge(t, now);
              final notes = [?neededLine(t), ?prizeLine(t)];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      if (t.status.isLive) const LiveBadge(),
                      if (badge != null)
                        OverlineBadge(label: badge.label, icon: badge.icon, solid: true),
                      OverlineBadge(label: subjectName(t.subject), tone: tone),
                      OverlineBadge(label: t.goal.label, tone: tone),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Semantics(header: true, child: Text(t.title, style: text.headlineMedium)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(startLine(t, now), style: text.labelLarge.copyWith(color: pair.onContainer)),
                  const SizedBox(height: AppSpacing.lg),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      InfoChip(icon: AppIcons.checklist, label: '${t.rounds} rounds'),
                      InfoChip(
                        icon: AppIcons.coins,
                        iconColor: colors.coin,
                        label: t.isFree ? 'Free entry' : '${formatCount(t.entryFee)} entry',
                      ),
                      InfoChip(
                        icon: AppIcons.award,
                        label: t.poolGrows
                            ? '${formatCount(t.poolNow)} of ${formatCount(t.prizePool)}'
                            : formatCount(t.poolNow),
                      ),
                      InfoChip(icon: AppIcons.social, label: '${t.players} / ${t.capacity}'),
                    ],
                  ),
                  if (notes.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    for (final note in notes)
                      Text(note, style: text.caption.copyWith(color: pair.onContainer)),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// What the viewer can do now: register, check in or say they can't make it, withdraw, add to
/// the calendar, or leave a running tournament.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.tournament});

  final Tournament tournament;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _checkingIn = false;

  Tournament get _t => widget.tournament;

  Future<void> _checkIn() async {
    setState(() => _checkingIn = true);
    await checkInNow(context, ref, _t);
    if (mounted) setState(() => _checkingIn = false);
  }

  @override
  Widget build(BuildContext context) {
    final goal = ref.watch(meProvider.select((me) => me.goal));
    return NowBuilder(
      builder: (context, now) {
        final t = _t;
        final action = cardAction(t, now, goal: goal);
        final text = context.text;
        final entry = t.me;
        Widget note(String message, {HugeIconData icon = AppIcons.info}) => ListRowCard(
          title: message,
          leading: HugeIcon(icon, size: 22, color: context.colors.inkMuted),
        );
        if (t.status == TournamentStatus.cancelled) {
          return note(
            t.entered || (entry?.registered ?? false)
                ? 'Cancelled: not enough players. Your entry fee was returned.'
                : 'This tournament was cancelled.',
          );
        }
        if (t.status.isOver) return const SizedBox.shrink();
        if (t.status.isLive) {
          if (entry?.withdrawn ?? false) {
            return note('You left this tournament. You stay in the standings without a prize.');
          }
          if (!t.entered) {
            return note('Round in progress. Follow the standings live.', icon: AppIcons.view);
          }
          return AppButton(
            label: 'Leave tournament',
            variant: AppButtonVariant.ghost,
            onPressed: () => unawaited(confirmWithdraw(context, t)),
          );
        }
        if (t.entered) {
          final checkInOpen = t.checkInOpen(now);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (t.checkedIn)
                note(
                  'You\'re checked in. Round 1 starts ${inDuration(t.startsAt.difference(now))}.',
                  icon: AppIcons.checkCircle,
                )
              else if (checkInOpen) ...[
                Text(
                  'Check in by ${clockTime(t.checkInClosesAt)} '
                  '(${mmss(t.checkInClosesAt.difference(now))} left) or your place is refunded.',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Check in',
                  leadingIcon: AppIcons.checkCircle,
                  loading: _checkingIn,
                  onPressed: _checkIn,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: 'Can\'t make it',
                  variant: AppButtonVariant.secondary,
                  onPressed: () => unawaited(confirmWithdraw(context, t, cantMakeIt: true)),
                ),
              ] else
                note(
                  now.isBefore(t.checkInOpensAt)
                      ? 'You\'re registered. Check in from ${clockTime(t.checkInOpensAt)} '
                            '(${startDay(t.checkInOpensAt, now)}).'
                      : 'Check-in has closed.',
                  icon: AppIcons.checkCircle,
                ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Add to calendar',
                      variant: AppButtonVariant.secondary,
                      size: AppButtonSize.medium,
                      leadingIcon: AppIcons.calendar,
                      onPressed: () => unawaited(addToCalendar(context, ref, t)),
                    ),
                  ),
                  if (!checkInOpen || t.checkedIn) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: AppButton(
                        label: 'Withdraw',
                        variant: AppButtonVariant.ghost,
                        size: AppButtonSize.medium,
                        onPressed: () => unawaited(confirmWithdraw(context, t)),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        }
        return switch (action) {
          CardAction.register => AppButton(
            label: t.isFree ? 'Register · free' : 'Register · ${feeLabel(t.entryFee)}',
            onPressed: () => unawaited(showRegisterSheet(context, t)),
          ),
          CardAction.full => const AppButton(label: 'Full', onPressed: null),
          CardAction.otherExam => note(
            'This tournament is for ${t.goal.label} players.',
            icon: AppIcons.lock,
          ),
          CardAction.locked => note('Registration has closed.', icon: AppIcons.lock),
          _ when t.status == TournamentStatus.scheduled => note(
            t.regOpensAt == null
                ? 'Registration opens soon.'
                : 'Registration opens ${startDay(t.regOpensAt!, now)}.',
            icon: AppIcons.calendar,
          ),
          _ => const SizedBox.shrink(),
        };
      },
    );
  }
}
