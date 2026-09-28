import 'dart:async';

import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart' hide AnswerOption;

import '../../../app/router.dart';
import '../../../core/auth/session.dart';
import '../../../core/realtime/live_match.dart';
import '../../../core/realtime/live_providers.dart';
import '../../../core/realtime/live_text.dart';
import '../../arena/tournament_live.dart' show isTournamentGame;
import '../../learn/data/learn_models.dart' as learn;
import '../../learn/widgets/learn_widgets.dart' show CoachTipCard;
import '../../rooms/lobby_screen.dart' show RoomRematchPanel;
import '../../rooms/room_text.dart';
import '../../rooms/rooms_controller.dart';
import '../../share/share_sheet.dart';
import '../../share/share_sources.dart';
import 'group_widgets.dart';
import 'match_widgets.dart';

/// The result dots: one per question, from the reveals this device saw.
List<ResultDot> resultDots(MatchView view) {
  final total = view.state.total > 0 ? view.state.total : view.reveals.length;
  return [
    for (var q = 1; q <= total; q++)
      if (view.reveals[q]?.players[view.me] case final mine?)
        ResultDot(
          outcome: mine.opt == null
              ? DotOutcome.missed
              : (mine.correct ? DotOutcome.right : DotOutcome.wrong),
          speed: view.isBot || mine.opt == null
              ? null
              : switch (mine.speed) {
                  Speed.fast => DotSpeed.fast,
                  Speed.slow => DotSpeed.slow,
                  Speed.even => DotSpeed.even,
                  null => null,
                },
        )
      else
        const ResultDot(outcome: DotOutcome.unknown),
  ];
}

/// The coach tip of a settlement, as the Learn tab's tip (so its button works the same).
learn.Tip? learnTipOf(Tip? tip, String matchId) {
  if (tip == null) return null;
  return learn.Tip(
    key: 'match:$matchId',
    message: tip.message,
    action: learn.TipAction.parse(tip.action),
    params: {
      for (final MapEntry(:key, :value) in tip.params.entries)
        if (value is String || value is num || value is bool) key: '$value',
    },
  );
}

/// A rating display ("1518?") as a number, when it is one.
int? ratingValue(String display) => int.tryParse(display.replaceAll('?', '').trim());

/// The end of a match (`/battle/match/:id` once it's over): the outcome, the dots, the rewards,
/// and what to do next.
class ResultView extends ConsumerStatefulWidget {
  const ResultView({super.key, required this.matchId, required this.onDone});

  final String matchId;
  final VoidCallback onDone;

  @override
  ConsumerState<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends ConsumerState<ResultView> {
  bool _starting = false;

  Future<void> _playAgain(MatchView view) async {
    final live = ref.read(liveControllerProvider);
    if (live == null) return;
    setState(() => _starting = true);
    try {
      final started = await live.playAgain(view);
      if (!mounted) return;
      if (!started) {
        widget.onDone();
        return;
      }
      // A bot game opens by itself; a search shows the search screen.
      if (!view.isBot) context.go(Routes.battleSearch);
      WidgetsBinding.instance.addPostFrameCallback((_) => live.closeMatch(widget.matchId));
    } on RealtimeError catch (error) {
      if (mounted && error.code != RealtimeErrorCode.busy) {
        showAppToast(context, LiveText.joinError(error), icon: AppIcons.alert);
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(matchViewProvider(widget.matchId));
    if (view == null) return const SizedBox.shrink();
    if (view.phase == MatchPhase.aborted || view.phase == MatchPhase.voided) {
      return _CancelledResult(view: view, onDone: widget.onDone);
    }
    final settlement = view.settlement;
    final tip = learnTipOf(settlement?.tip, view.matchId);
    // Enabled once the result is known.
    final share = matchShareData(view, ref.watch(meProvider));
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.md,
        AppSpacing.gutter,
        AppSpacing.xxl,
      ),
      children: [
        Row(
          children: [
            AppIconButton(icon: AppIcons.close, semanticLabel: 'Close', onPressed: widget.onDone),
            const Spacer(),
            AppIconButton(
              icon: AppIcons.share,
              semanticLabel: 'Share result',
              onPressed: share == null
                  ? null
                  : () => unawaited(showShareSheet(context, data: share)),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        if (view.isGroup) GroupStandingsView(view: view) else _OutcomeCard(view: view),
        const SizedBox(height: AppSpacing.lg),
        _SettlementStatus(view: view),
        if (settlement != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Rewards(settlement: settlement, view: view),
        ],
        if (tip != null) ...[const SizedBox(height: AppSpacing.lg), CoachTipCard(tip: tip)],
        if (view.isCasual) ...[const SizedBox(height: AppSpacing.lg), _RematchPanel(view: view)],
        if (view.isRoomGame) ...[
          const SizedBox(height: AppSpacing.lg),
          _RoomAfterGame(matchId: view.matchId),
        ],
        const SizedBox(height: AppSpacing.xxl),
        // A tournament game leads back to the lobby, where the next round is called.
        if (isTournamentGame(view))
          AppButton(
            label: 'Back to tournament',
            leadingIcon: AppIcons.arena,
            onPressed: widget.onDone,
          )
        else if (!view.isRoomGame) ...[
          AppButton(
            label: 'Play again',
            leadingIcon: AppIcons.refresh,
            loading: _starting,
            onPressed: _starting ? null : () => _playAgain(view),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        AppButton(
          label: 'Review answers',
          variant: AppButtonVariant.secondary,
          leadingIcon: AppIcons.checklist,
          onPressed: () => context.push(Routes.battleReview(view.matchId)),
        ),
        if (view.isRoomGame && ref.watch(roomViewProvider) != null) ...[
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Back to lobby',
            variant: AppButtonVariant.secondary,
            leadingIcon: AppIcons.social,
            onPressed: widget.onDone,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Leave room',
            variant: AppButtonVariant.ghost,
            leadingIcon: AppIcons.logout,
            onPressed: () async {
              await roomsOf(ref)?.leave();
              if (context.mounted) context.go(Routes.battle);
            },
          ),
        ] else ...[
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Done',
            variant: AppButtonVariant.ghost,
            onPressed: widget.onDone,
          ),
        ],
      ],
    );
  }
}

/// After a friend duel or a group battle: the room's rematch (both within 30 s for a duel;
/// "Play again" keeps a group's room for 3 minutes).
class _RoomAfterGame extends ConsumerStatefulWidget {
  const _RoomAfterGame({required this.matchId});

  final String matchId;

  @override
  ConsumerState<_RoomAfterGame> createState() => _RoomAfterGameState();
}

class _RoomAfterGameState extends ConsumerState<_RoomAfterGame> {
  bool _busy = false;

  Future<void> _rematch(bool accept) async {
    setState(() => _busy = true);
    try {
      await roomsOf(ref)?.rematch(accept: accept);
    } on RealtimeError catch (error) {
      if (mounted) showAppToast(context, RoomText.error(error), icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = ref.watch(roomViewProvider);
    if (room == null || room.state.status != RoomStatus.finished) {
      return const SizedBox.shrink();
    }
    if (room.state.matchId != null && room.state.matchId != widget.matchId) {
      return const SizedBox.shrink();
    }
    return RoomRematchPanel(view: room, busy: _busy, onRematch: _rematch);
  }
}

class _OutcomeCard extends ConsumerWidget {
  const _OutcomeCard({required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.text;
    final me = ref.watch(meProvider);
    final outcome = view.outcome;
    final result = outcome?.result ?? MatchResult.unknown;
    final (title, icon, tone) = switch (result) {
      MatchResult.win => ('Victory!', AppIcons.crown, PastelTone.mint),
      MatchResult.loss => ('Defeat', AppIcons.sad, PastelTone.rose),
      MatchResult.draw => ('Draw', AppIcons.thumbsUp, PastelTone.lemon),
      MatchResult.unknown => ('Game over', AppIcons.award, PastelTone.sky),
    };
    final pair = colors.pastel(tone);
    final reason = outcome == null
        ? null
        : LiveText.endReason(outcome, opponent: view.opponentName);
    final subject = view.intro?.request?.subjectLabel;
    final kind = switch (view.mode) {
      // "Practice game · not rated" follows right under the card.
      'bot' => 'Practice Bot',
      'casual' => 'Casual',
      'rated' => 'Rated',
      'friend' => 'Friend battle · unrated',
      _ => null,
    };
    final caption = [?reason, if (reason == null) ?subject, if (reason == null) ?kind].join(' · ');
    final myPoints = view.myTotals.points;
    final theirPoints = view.opponentTotals.points;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: pair.container,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _PopIn(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: colors.isDark ? colors.surface : Colors.white,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: HugeIcon(icon, size: 28, color: pair.onContainer),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(header: true, child: Text(title, style: text.headlineLarge)),
                    if (caption.isNotEmpty)
                      Text(caption, style: text.labelMedium.copyWith(color: pair.onContainer)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Semantics(
            label: 'You $myPoints, ${view.opponentName} $theirPoints',
            excludeSemantics: true,
            child: Row(
              children: [
                Expanded(
                  child: _ScoreSide(
                    avatar: me.avatar.toData(),
                    name: 'You',
                    points: myPoints,
                    alignEnd: false,
                  ),
                ),
                Text('–', style: text.numericLarge.copyWith(color: pair.onContainer)),
                Expanded(
                  child: _ScoreSide(
                    avatar: avatarOf(view.opponentCard),
                    name: view.opponentName,
                    points: theirPoints,
                    alignEnd: true,
                  ),
                ),
              ],
            ),
          ),
          if (view.reveals.isNotEmpty || view.state.total > 0) ...[
            const SizedBox(height: AppSpacing.xl),
            // On a plain strip, so the dots read on any outcome colour.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: colors.isDark ? colors.surface : Colors.white,
                borderRadius: BorderRadius.circular(AppRadii.xl),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final dots = resultDots(view);
                  // One row on any phone: each dot (and its speed badge) shares the width.
                  final count = dots.isEmpty ? 1 : dots.length;
                  final share = (constraints.maxWidth - AppSpacing.sm * (count - 1)) / count / 1.15;
                  return ResultDots(dots: dots, size: share.clamp(20, 32).toDouble());
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScoreSide extends StatelessWidget {
  const _ScoreSide({
    required this.avatar,
    required this.name,
    required this.points,
    required this.alignEnd,
  });

  final AvatarData avatar;
  final String name;
  final int points;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final info = Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(name, style: text.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        NumberTicker(value: points, style: text.numericLarge),
      ],
    );
    final children = [
      AppAvatar(data: avatar, size: 40),
      const SizedBox(width: AppSpacing.sm),
      Flexible(child: info),
    ];
    return Row(
      mainAxisAlignment: alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: alignEnd ? children.reversed.toList() : children,
    );
  }
}

/// "Results syncing…" until settlement; "Result saved. Rewards will appear shortly" when the
/// server is still settling after 20 s; "Practice game · not rated" for the bot.
class _SettlementStatus extends ConsumerWidget {
  const _SettlementStatus({required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final Widget child;
    if (view.syncing) {
      child = InfoChip(
        key: const ValueKey('syncing'),
        icon: AppIcons.refresh,
        label: view.settlementStatus == SettlementStatus.failed
            ? 'Results syncing… trying again'
            : 'Results syncing…',
        background: colors.surfaceMuted,
      );
    } else if (view.settlement == null && view.settlementStatus == SettlementStatus.later) {
      child = InfoChip(
        key: const ValueKey('later'),
        icon: AppIcons.checkCircle,
        label: 'Result saved. Rewards will appear shortly',
        background: colors.successContainer,
        foreground: colors.onSuccessContainer,
      );
    } else if (view.isBot) {
      child = InfoChip(
        key: const ValueKey('bot'),
        icon: AppIcons.robot,
        label: 'Practice game · not rated',
        background: colors.lavender.container,
        foreground: colors.lavender.onContainer,
      );
    } else {
      child = const SizedBox.shrink(key: ValueKey('none'));
    }
    return Semantics(
      liveRegion: true,
      child: Center(
        child: AnimatedSwitcher(duration: AppMotion.of(context, AppMotion.medium), child: child),
      ),
    );
  }
}

class _Rewards extends StatelessWidget {
  const _Rewards({required this.settlement, required this.view});

  final Settlement settlement;
  final MatchView view;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final rating = settlement.rating;
    final rank = settlement.rank;
    final coins = settlement.coins;
    final xp = settlement.xp;
    final streak = settlement.streak;
    final capped = (coins?.capped ?? false) || (xp?.capped ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rating != null || rank != null)
          SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rating != null) _RatingRow(rating: rating),
                if (rating != null && rank != null) const SizedBox(height: AppSpacing.md),
                if (rank != null)
                  Row(
                    children: [
                      HugeIcon(AppIcons.arena, size: 20, color: colors.ink),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          LiveText.rankLine(rank),
                          style: text.titleMedium.copyWith(fontSize: 15),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        if (xp?.levelUp ?? false) ...[
          const SizedBox(height: AppSpacing.md),
          _LevelUp(level: xp!.level),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (coins != null && !view.isBot)
              Expanded(
                child: _RewardTile(
                  label: 'Coins',
                  value: CoinAmount(
                    amount: coins.delta,
                    signed: true,
                    iconSize: 20,
                    style: text.numericMedium,
                  ),
                  footer: 'Balance ${formatCount(coins.balance)}',
                ),
              ),
            if (coins != null && !view.isBot && xp != null) const SizedBox(width: AppSpacing.md),
            if (xp != null)
              Expanded(
                child: _RewardTile(
                  label: 'XP',
                  value: NumberTicker(value: xp.delta, prefix: '+', style: text.numericMedium),
                  footer: 'Level ${xp.level} · ${xp.intoLevel}/${xp.forNext}',
                  progress: xp.forNext <= 0 ? null : xp.intoLevel / xp.forNext,
                ),
              ),
          ],
        ),
        if (capped) ...[
          const SizedBox(height: AppSpacing.sm),
          _Note(
            icon: AppIcons.info,
            text: (coins?.capped ?? false)
                ? 'Daily coin limit reached · resets at midnight'
                : 'Daily XP limit reached · resets at midnight',
          ),
        ],
        if (settlement.missions.isNotEmpty || streak != null) ...[
          const SizedBox(height: AppSpacing.md),
          SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (streak != null)
                  Row(
                    children: [
                      HugeIcon(AppIcons.fire, size: 20, color: colors.warning),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          streak.days == 1 ? '1-day streak' : '${streak.days}-day streak',
                          style: text.titleMedium.copyWith(fontSize: 15),
                        ),
                      ),
                      if (streak.extended) Text('Extended today', style: text.caption),
                    ],
                  ),
                for (final mission in settlement.missions) ...[
                  const SizedBox(height: AppSpacing.md),
                  _MissionRow(mission: mission),
                ],
              ],
            ),
          ),
        ],
        if (settlement.achievements.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final achievement in settlement.achievements)
                InfoChip(
                  icon: AppIcons.medal,
                  label: achievement.title,
                  background: colors.lemon.container,
                  foreground: colors.lemon.onContainer,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({required this.rating});

  final RatingChange rating;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final before = ratingValue(rating.before);
    final after = ratingValue(rating.after);
    final provisional = rating.after.contains('?');
    final subject = LiveText.boardName('rating:${rating.scope}').replaceFirst('in ', '');
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$subject rating', style: text.caption),
              if (after == null)
                Text(rating.after, style: text.numericLarge)
              else
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: (before ?? after).toDouble(), end: after.toDouble()),
                  duration: AppMotion.of(context, const Duration(milliseconds: 900)),
                  curve: AppMotion.emphasized,
                  builder: (context, value, _) => Text(
                    '${value.round()}${provisional ? '?' : ''}',
                    style: text.numericLarge,
                    semanticsLabel: rating.after,
                  ),
                ),
            ],
          ),
        ),
        RatingDelta(delta: rating.delta),
      ],
    );
  }
}

class _RewardTile extends StatelessWidget {
  const _RewardTile({required this.label, required this.value, this.footer, this.progress});

  final String label;
  final Widget value;
  final String? footer;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: text.overline),
          const SizedBox(height: AppSpacing.xs),
          value,
          if (progress case final progress?) ...[
            const SizedBox(height: AppSpacing.sm),
            AppProgressBar(value: progress, height: 6, semanticLabel: 'Progress to the next level'),
          ],
          if (footer case final footer?) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(footer, style: text.caption),
          ],
        ],
      ),
    );
  }
}

class _MissionRow extends StatelessWidget {
  const _MissionRow({required this.mission});

  final MissionProgress mission;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return MergeSemantics(
      child: Row(
        children: [
          HugeIcon(
            mission.done ? AppIcons.checkCircle : AppIcons.target,
            size: 20,
            color: mission.done ? colors.success : colors.inkMuted,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mission.title ?? 'Mission', style: text.labelMedium),
                const SizedBox(height: AppSpacing.xs),
                SegmentedProgress(
                  total: mission.target.clamp(1, 10),
                  completed: mission.progress.clamp(0, mission.target.clamp(1, 10)),
                  color: mission.done ? colors.success : null,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text('${mission.progress}/${mission.target}', style: text.numericMedium),
        ],
      ),
    );
  }
}

class _LevelUp extends StatelessWidget {
  const _LevelUp({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.lemon;
    return _PopIn(
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: pair.container,
            borderRadius: BorderRadius.circular(AppRadii.xl),
          ),
          child: Row(
            children: [
              HugeIcon(AppIcons.party, size: 28, color: pair.onContainer),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Level up!', style: context.text.titleLarge),
                    Text(
                      'You\'re now level $level',
                      style: context.text.bodySmall.copyWith(color: pair.onContainer),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final HugeIconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.lemon.container,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Row(
        children: [
          HugeIcon(icon, size: 18, color: colors.lemon.onContainer),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: context.text.labelMedium.copyWith(color: colors.lemon.onContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _RematchPanel extends ConsumerWidget {
  const _RematchPanel({required this.view});

  final MatchView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.text;
    final name = view.opponentName;
    Future<void> rematch({bool accept = true}) async =>
        ref.read(liveControllerProvider)?.rematch(view.matchId, accept: accept);
    final failure =
        view.rematchError ??
        switch (view.state.rematch) {
          Rematch.declined => '$name said no to a rematch',
          Rematch.expired => 'The rematch offer ran out',
          Rematch.failed => switch (view.state.rematchFailure) {
            'insufficient_coins' => 'A rematch needs 5 coins each',
            'opponent_left' => '$name has left',
            _ => 'The rematch couldn\'t start',
          },
          _ => null,
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        switch (view.state.rematch) {
          Rematch.offeredByMe => AppButton(
            label: 'Waiting for $name…',
            variant: AppButtonVariant.tonal,
            tone: PastelTone.lavender,
            loading: true,
            onPressed: null,
          ),
          Rematch.offeredByThem => AppButton(
            label: 'Accept rematch',
            variant: AppButtonVariant.tonal,
            tone: PastelTone.lavender,
            leadingIcon: AppIcons.refresh,
            onPressed: rematch,
          ),
          Rematch.accepted => const AppButton(
            label: 'Starting the rematch…',
            variant: AppButtonVariant.tonal,
            tone: PastelTone.lavender,
            loading: true,
            onPressed: null,
          ),
          _ => AppButton(
            label: 'Rematch',
            variant: AppButtonVariant.tonal,
            tone: PastelTone.lavender,
            leadingIcon: AppIcons.refresh,
            onPressed: failure == null || view.rematchError != null ? rematch : null,
          ),
        },
        if (view.state.rematch == Rematch.offeredByThem) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            '$name wants a rematch · ${LiveText.coins(5)} each',
            style: text.caption,
            textAlign: TextAlign.center,
          ),
        ],
        if (failure != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(failure, style: text.caption, textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

/// An aborted or voided game: what happened, and the way back.
class _CancelledResult extends StatefulWidget {
  const _CancelledResult({required this.view, required this.onDone});

  final MatchView view;
  final VoidCallback onDone;

  @override
  State<_CancelledResult> createState() => _CancelledResultState();
}

class _CancelledResultState extends State<_CancelledResult> {
  Timer? _back;

  @override
  void initState() {
    super.initState();
    // An aborted start explains itself, then goes back by itself.
    if (widget.view.phase == MatchPhase.aborted) {
      _back = Timer(const Duration(seconds: 5), () {
        if (mounted) widget.onDone();
      });
    }
  }

  @override
  void dispose() {
    _back?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final aborted = view.phase == MatchPhase.aborted;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyState(
              icon: aborted ? AppIcons.hourglass : AppIcons.shield,
              tone: PastelTone.lemon,
              title: aborted ? 'The game didn\'t start' : 'This game didn\'t count',
              message: aborted
                  ? LiveText.aborted(
                      opponent: view.opponentName,
                      iWasReady: view.readySent,
                      casual: view.isCasual,
                    )
                  : LiveText.voided(casual: view.isCasual),
            ),
            AppButton(label: 'Back to Battle', onPressed: widget.onDone),
          ],
        ),
      ),
    );
  }
}

/// Scales its child in once, unless motion is reduced.
class _PopIn extends StatelessWidget {
  const _PopIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0.6, end: 1),
    duration: AppMotion.of(context, AppMotion.slow),
    curve: AppMotion.bouncy,
    builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
    child: child,
  );
}
