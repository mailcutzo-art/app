import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/live/live_hub.dart' show liveClockProvider;
import '../../../app/router.dart';
import '../../../core/auth/session.dart';
import '../../../core/utils/time_text.dart';
import '../../common/paged_list.dart' show RowIcon;
import '../../learn/widgets/learn_widgets.dart' show CardSkeleton, failureMessage;
import '../arena_providers.dart';
import '../arena_text.dart';
import '../data/tournament_models.dart';
import '../tournament_actions_ui.dart';

/// Rebuilds every [every] with the current time (countdowns, "Starts in 12 min").
class NowBuilder extends ConsumerStatefulWidget {
  const NowBuilder({super.key, required this.builder, this.every = const Duration(seconds: 1)});

  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration every;

  @override
  ConsumerState<NowBuilder> createState() => _NowBuilderState();
}

class _NowBuilderState extends ConsumerState<NowBuilder> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.every, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, ref.read(liveClockProvider)());
}

/// The shared-element tag between a card in the Arena list and the tournament's header.
String tournamentHeroTag(String id) => 'tournament-$id';

/// What flies between the card and the header: the pastel backdrop, re-sized on the way.
Widget tournamentHeroShuttle(PastelTone tone) => Builder(
  builder: (context) {
    final colors = context.colors;
    final pair = colors.pastel(tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppRadii.tile,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [pair.container, Color.lerp(pair.container, colors.surface, 0.55)!],
        ),
      ),
    );
  },
);

/// A tournament card in the Arena: subject colour, the LIVE / registration / locked badge,
/// "5 of 8 needed", "Prize now 625 of 2,500", the capacity bar, the fee, the start, and a
/// button that does the next thing (Register, Check in, Watch, …). Tapping elsewhere opens it.
class ArenaTournamentCard extends ConsumerStatefulWidget {
  const ArenaTournamentCard({super.key, required this.tournament, this.hero = true});

  final Tournament tournament;

  /// Whether this card flies into the tournament's header (only one card per tournament on a
  /// screen may).
  final bool hero;

  @override
  ConsumerState<ArenaTournamentCard> createState() => _ArenaTournamentCardState();
}

class _ArenaTournamentCardState extends ConsumerState<ArenaTournamentCard> {
  bool _busy = false;

  Tournament get _t => widget.tournament;

  /// Opens the tournament; the card goes along, so its header shows (and the shared element
  /// flies) before the detail loads.
  void _open() => unawaited(context.push(Routes.tournament(_t.id), extra: _t));

  Future<void> _act(CardAction action) async {
    switch (action) {
      case CardAction.register:
        await showRegisterSheet(context, _t);
      case CardAction.checkIn:
        setState(() => _busy = true);
        await checkInNow(context, ref, _t);
        if (mounted) setState(() => _busy = false);
      case CardAction.results:
        unawaited(context.push(Routes.tournamentResults(_t.id)));
      default:
        _open();
    }
  }

  @override
  Widget build(BuildContext context) {
    final goal = ref.watch(meProvider.select((me) => me.goal));
    return NowBuilder(
      every: const Duration(seconds: 15),
      builder: (context, now) {
        final t = _t;
        final tone = tournamentTone(t);
        final action = cardAction(t, now, goal: goal);
        final badge = statusBadge(t, now);
        final notes = [?neededLine(t), ?prizeLine(t)];
        final card = TournamentCard(
          title: t.title,
          subjectLabel: subjectName(t.subject),
          tone: tone,
          live: t.status.isLive,
          statusLabel: badge?.label,
          statusIcon: badge?.icon ?? AppIcons.clock,
          rounds: t.rounds,
          entryFee: t.isFree ? null : t.entryFee,
          prizePool: t.poolNow,
          prizeLabel: t.poolGrows
              ? '${formatCount(t.poolNow)} of ${formatCount(t.prizePool)}'
              : null,
          joined: t.players,
          capacity: t.capacity,
          scheduleLabel: startLine(t, now),
          footnote: notes.isEmpty ? null : notes.join('\n'),
          ctaLabel: action.label,
          primaryCta: action.primary,
          ctaLoading: _busy,
          onCta: action.enabled ? () => unawaited(_act(action)) : null,
          onTap: _open,
        );
        if (!widget.hero) return card;
        return Hero(
          tag: tournamentHeroTag(t.id),
          flightShuttleBuilder: (_, _, _, _, _) => tournamentHeroShuttle(tone),
          child: Material(type: MaterialType.transparency, child: card),
        );
      },
    );
  }
}

/// Loading placeholder for a list of tournament cards.
class TournamentCardsSkeleton extends StatelessWidget {
  const TournamentCardsSkeleton({super.key, this.cards = 2});

  final int cards;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < cards; i++)
        const Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.md),
          child: CardSkeleton(height: 250),
        ),
    ],
  );
}

/// The next tournament for Home ("Live and next"): the viewer's live or next one, otherwise
/// the soonest open one. Nothing at all when there's no tournament to show.
class NextTournamentCard extends ConsumerWidget {
  const NextTournamentCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = ref.watch(nextTournamentProvider);
    return switch (next) {
      AsyncValue(value: final Tournament t) => ArenaTournamentCard(tournament: t, hero: false),
      AsyncValue(hasValue: true) => const SizedBox.shrink(),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load tournaments',
        message: failureMessage(error),
        retrying: next.isLoading,
        onRetry: () => ref.invalidate(nextTournamentProvider),
      ),
      _ => const CardSkeleton(height: 250),
    };
  }
}

/// One tournament in Profile → Tournaments: the final rank and prize once it's over, else when
/// it starts.
class TournamentHistoryRow extends StatelessWidget {
  const TournamentHistoryRow({super.key, required this.item});

  final MyTournament item;

  @override
  Widget build(BuildContext context) {
    final t = item.tournament;
    final result = item.result;
    final now = DateTime.now();
    final subtitle = switch (t.status) {
      TournamentStatus.cancelled => 'Cancelled · ${shortDate(t.startsAt, now: now)}',
      _ when t.me?.withdrawn ?? false => 'Withdrew · ${shortDate(t.startsAt, now: now)}',
      _ when result != null => [
        result.placeLine,
        if (result.prize > 0) '+${formatCount(result.prize)} coins',
        shortDate(t.startsAt, now: now),
      ].join(' · '),
      _ when t.status.isLive => 'Live now',
      _ => startLine(t, now),
    };
    final won = result != null && result.rank <= 3;
    return ListRowCard(
      title: t.title,
      subtitle: subtitle,
      leading: RowIcon(icon: won ? AppIcons.medal : AppIcons.arena, tone: tournamentTone(t)),
      trailing: HugeIcon(AppIcons.chevronRight, size: 18, color: context.colors.inkMuted),
      onTap: () => unawaited(
        context.push(result != null ? Routes.tournamentResults(t.id) : Routes.tournament(t.id)),
      ),
    );
  }
}
