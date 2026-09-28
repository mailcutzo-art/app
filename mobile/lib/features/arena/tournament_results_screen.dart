import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/paging.dart';
import '../learn/widgets/learn_widgets.dart' show CardSkeleton, failureMessage;
import 'arena_providers.dart';
import 'arena_text.dart';
import 'data/tournament_models.dart';
import 'tournament_live.dart';

/// A finished tournament's final results (`/arena/:id/results`): "You finished #3 of 64", the
/// prize credited automatically, the XP, and the podium. `t.finished` leads here, and so do the
/// Inbox and Profile → Tournaments.
class TournamentResultsScreen extends ConsumerWidget {
  const TournamentResultsScreen({super.key, required this.id});

  final String id;

  void _close(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.arena);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(tournamentDetailProvider(id));
    final live = ref.watch(tournamentLiveProvider)[id];
    return Scaffold(
      appBar: AppTopBar(
        title: detail.value?.tournament.title ?? 'Results',
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.tournament(id)),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref
            ..invalidate(tournamentDetailProvider(id))
            ..invalidate(standingsProvider(id));
          await settle(ref.read(tournamentDetailProvider(id).future));
        },
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
          children: switch (detail) {
            AsyncValue(:final value?) => [
              ..._results(context, ref, value, value.me?.result ?? live?.result),
            ],
            AsyncValue(:final error?) => [
              ErrorState(
                title: 'Couldn\'t load the results',
                message: failureMessage(error),
                retrying: detail.isLoading,
                onRetry: () => ref.invalidate(tournamentDetailProvider(id)),
              ),
            ],
            _ => [
              const CardSkeleton(height: 260),
              const SizedBox(height: AppSpacing.lg),
              const CardSkeleton(height: 200),
            ],
          },
        ),
      ),
    );
  }

  List<Widget> _results(
    BuildContext context,
    WidgetRef ref,
    TournamentDetail detail,
    TournamentFinal? result,
  ) {
    final t = detail.tournament;
    final text = context.text;
    final colors = context.colors;
    if (result == null) {
      return [
        SurfaceCard(
          child: EmptyState(
            icon: AppIcons.hourglass,
            tone: tournamentTone(t),
            title: t.status.isOver ? 'No result for you' : 'Results aren\'t in yet',
            message: t.status.isOver
                ? 'You didn\'t play in this tournament.'
                : 'They\'re ready as soon as the last round ends.',
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'Open tournament',
          onPressed: () => unawaited(context.push(Routes.tournament(t.id))),
        ),
      ];
    }
    final pair = colors.pastel(result.rank <= 3 ? PastelTone.lemon : tournamentTone(t));
    final standings = ref.watch(standingsProvider(t.id));
    final podium = standings.value?.rows.take(3).toList() ?? const <StandingRow>[];
    return [
      Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: pair.container,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
        ),
        child: Column(
          children: [
            HugeIcon(
              result.rank <= 3 ? AppIcons.medal : AppIcons.award,
              size: 48,
              color: pair.onContainer,
            ),
            const SizedBox(height: AppSpacing.md),
            Semantics(
              header: true,
              child: Text(
                'You finished ${result.placeLine}',
                style: text.headlineLarge,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${formatPoints(result.points)} points · ${subjectName(t.subject)}',
              style: text.labelLarge.copyWith(color: pair.onContainer),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: _Reward(
                    value: result.prize > 0 ? CoinAmount(amount: result.prize, signed: true) : null,
                    label: result.prize > 0
                        ? 'Prize, credited to your wallet'
                        : 'No prize this time',
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _Reward(
                    value: Text('+${result.xp} XP', style: text.numericMedium),
                    label: 'XP for the rounds you played',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      if (podium.isNotEmpty) ...[
        const SectionHeader(
          title: 'Podium',
          padding: EdgeInsets.fromLTRB(0, AppSpacing.xxl, 0, AppSpacing.md),
        ),
        Podium(
          entries: [
            for (final row in podium)
              PodiumEntry(
                name: row.user.displayName,
                score: '${formatPoints(row.points)} pts',
                avatar: row.user.avatar.toData(),
              ),
          ],
        ),
      ],
      const SizedBox(height: AppSpacing.xxl),
      AppButton(
        label: 'Final standings',
        variant: AppButtonVariant.secondary,
        leadingIcon: AppIcons.chart,
        onPressed: () => unawaited(
          context.push(
            Uri(path: Routes.tournament(t.id), queryParameters: {'tab': 'standings'}).toString(),
          ),
        ),
      ),
      if (result.prize > 0) ...[
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: 'Open wallet',
          variant: AppButtonVariant.ghost,
          leadingIcon: AppIcons.wallet,
          onPressed: () => unawaited(context.push(Routes.wallet)),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      AppButton(label: 'Done', onPressed: () => _close(context)),
    ];
  }
}

class _Reward extends StatelessWidget {
  const _Reward({required this.label, this.value});

  final Widget? value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: context.colors.isDark ? context.colors.surface : Colors.white,
      borderRadius: BorderRadius.circular(AppRadii.xl),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        value ?? Text('—', style: context.text.numericMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(label, style: context.text.caption),
      ],
    ),
  );
}
