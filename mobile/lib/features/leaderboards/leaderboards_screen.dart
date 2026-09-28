import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/live/live_hub.dart' show liveClockProvider;
import '../../app/router.dart';
import '../../app/shell.dart' show Gutter;
import '../../core/auth/session.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import 'data/leaderboard_models.dart';
import 'leaderboard_providers.dart';
import 'widgets/leaderboard_widgets.dart';

/// The leaderboards hub (`/leaderboards`): where the viewer stands, one card
/// per board, and last week's champions.
class LeaderboardsScreen extends ConsumerStatefulWidget {
  const LeaderboardsScreen({super.key});

  @override
  ConsumerState<LeaderboardsScreen> createState() => _LeaderboardsScreenState();
}

class _LeaderboardsScreenState extends ConsumerState<LeaderboardsScreen> {
  /// Keeps "Ends in 2 d 4 h" current.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(examScopeProvider);
    final hub = ref.watch(leaderboardHubProvider(scope));
    final myId = ref.watch(currentUserIdProvider);
    final now = ref.watch(liveClockProvider)();

    final List<Widget> content = switch (hub) {
      AsyncValue(:final value?) => _content(context, value, scope, myId, now),
      AsyncValue(:final error?) => [
        Gutter(
          child: SurfaceCard(
            child: ErrorState(
              title: 'Couldn\'t load leaderboards',
              message: failureMessage(error),
              retrying: hub.isLoading,
              onRetry: () => ref.invalidate(leaderboardHubProvider(scope)),
            ),
          ),
        ),
      ],
      _ => const [Gutter(child: HubSkeleton())],
    };

    return Scaffold(
      appBar: AppTopBar(onBack: () => context.canPop() ? context.pop() : context.go(Routes.home)),
      body: RefreshIndicator(
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        onRefresh: () async {
          ref.invalidate(leaderboardHubProvider(scope));
          try {
            await ref.read(leaderboardHubProvider(scope).future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            LargeTitle(
              title: 'Leaderboards',
              subtitle: switch (hub.value) {
                final value? when hubHeadline(value.boards).isNotEmpty => hubHeadline(value.boards),
                _ => 'Who is leading where',
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            Gutter(
              child: AppSegmentedControl<ExamScope>(
                segments: [
                  for (final option in _scopes(ref)) AppSegment(value: option, label: option.label),
                ],
                selected: scope,
                onChanged: (value) => ref.read(examScopeProvider.notifier).select(value),
                height: AppSizes.buttonSmall + 4,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            ...content,
          ],
        ),
      ),
    );
  }

  /// The viewer's own exam first, then All India. Someone without an exam
  /// yet sees both exams.
  static List<ExamScope> _scopes(WidgetRef ref) {
    final goal = ref.read(meProvider).goal;
    return [
      if (goal == null) ...[ExamScope.neet, ExamScope.jee] else ExamScope.of(goal),
      ExamScope.allIndia,
    ];
  }

  List<Widget> _content(
    BuildContext context,
    LeaderboardHub hub,
    ExamScope scope,
    String? myId,
    DateTime now,
  ) {
    final boards = [
      for (final card in hub.boards)
        if (scope.shows(card.subject)) card,
    ];
    return [
      if (hub.lastWeek.isNotEmpty) ...[
        const SectionHeader(
          title: 'Last week\'s champions',
          subtitle: 'Top 3 by XP',
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
        ),
        Gutter(
          child: SurfaceCard(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, 0),
            child: Podium(
              entries: [
                for (final row in hub.lastWeek.take(3))
                  PodiumEntry(
                    name: isMine(row, myId) ? 'You' : row.user.displayName,
                    score: row.valueDisplay,
                    avatar: row.user.avatar.toData(),
                  ),
              ],
            ),
          ),
        ),
      ],
      const SectionHeader(title: 'Boards'),
      if (boards.isEmpty)
        Gutter(
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.arena,
              tone: PastelTone.lemon,
              title: 'No boards yet',
              message: 'Play a battle or practise to get the boards going.',
              actionLabel: 'Play a battle',
              onAction: () => context.go(Routes.battle),
            ),
          ),
        ),
      for (final card in boards)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: BoardCard(
            card: card,
            now: now,
            myId: myId,
            onTap: () => context.push(Routes.board(card.board)),
          ),
        ),
    ];
  }
}
