import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/auth/user.dart';
import '../../core/network/app_failure.dart';
import '../../core/network/connectivity.dart';
import '../../core/utils/ids.dart';
import '../practice/data/practice_models.dart';
import '../practice/data/session_store.dart';
import '../practice/start_practice.dart';
import 'data/learn_models.dart';
import 'learn_providers.dart';
import 'widgets/learn_widgets.dart';

/// The Learn tab: exam switcher, continue practice, coach tip, subjects and
/// practice tools. Catalog and progress load and fail independently.
class LearnScreen extends ConsumerWidget {
  const LearnScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(learnGoalProvider);
    final catalog = ref.watch(catalogProvider(goal));
    final progress = ref.watch(progressProvider(goal));
    final online = ref.watch(isOnlineProvider);

    // Sections that failed load again by themselves when the connection is back.
    ref.listen(isOnlineProvider, (wasOnline, online) {
      if (!online || wasOnline != false) return;
      if (ref.read(catalogProvider(goal)).hasError) ref.invalidate(catalogProvider(goal));
      if (ref.read(progressProvider(goal)).hasError) ref.invalidate(progressProvider(goal));
    });

    final showingSaved = catalog.value?.fromCache ?? false;
    return TabPage(
      onRefresh: () => _refresh(context, ref, goal),
      children: [
        OfflineBanner(
          visible: !online || showingSaved,
          message: online ? 'Couldn\'t reach the server — showing saved subjects' : null,
        ),
        const LargeTitle(title: 'Learn', subtitle: 'Practise by subject, chapter and topic.'),
        const SizedBox(height: AppSpacing.lg),
        Gutter(
          child: AppSegmentedControl<Goal>(
            segments: const [
              AppSegment(value: Goal.neet, label: 'NEET', icon: AppIcons.biology),
              AppSegment(value: Goal.jee, label: 'JEE', icon: AppIcons.maths),
            ],
            selected: goal,
            onChanged: ref.read(learnGoalProvider.notifier).select,
          ),
        ),
        _ProgressCards(goal: goal, progress: progress),
        const SectionHeader(title: 'Subjects'),
        Gutter(
          child: _Subjects(goal: goal, catalog: catalog),
        ),
        const SectionHeader(title: 'Practice tools'),
        Gutter(child: _PracticeTools(reviewsDue: progress.value?.reviewsDue)),
      ],
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref, Goal goal) async {
    ref
      ..invalidate(catalogProvider(goal))
      ..invalidate(progressProvider(goal));
    await Future.wait([
      _settle(ref.read(catalogProvider(goal).future)),
      _settle(ref.read(progressProvider(goal).future)),
    ]);
    if (!context.mounted) return;
    final failed =
        ref.read(catalogProvider(goal)).hasError || ref.read(progressProvider(goal)).hasError;
    if (failed) showAppToast(context, 'Couldn\'t refresh everything. Try again in a moment.');
  }

  static Future<void> _settle(Future<Object?> future) async {
    try {
      await future;
    } on Object {
      // Each section shows its own error.
    }
  }
}

/// Continue practice and the coach tip, which both come from progress.
/// Without progress (offline), the session saved on this device still offers
/// "Continue practice".
class _ProgressCards extends ConsumerWidget {
  const _ProgressCards({required this.goal, required this.progress});

  final Goal goal;
  final AsyncValue<Progress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const padding = EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.lg, AppSpacing.gutter, 0);
    Widget continueCard(ContinuePractice practice) => Padding(
      padding: padding,
      child: ContinuePracticeCard(
        practice: practice,
        onResume: () => context.push(Routes.practiceSession(practice.sessionId)),
      ),
    );
    return switch (progress) {
      AsyncValue(:final value?) => Column(
        children: [
          if (value.continuePractice case final practice?) continueCard(practice),
          if (value.tip case final tip?)
            Padding(
              padding: padding,
              child: CoachTipCard(tip: tip),
            ),
        ],
      ),
      AsyncValue(:final error?) => Column(
        children: [
          if (_savedPractice(ref) case final practice?) continueCard(practice),
          Padding(
            padding: padding,
            child: ErrorState(
              compact: true,
              title: 'Couldn\'t load your progress',
              message: failureMessage(error),
              retrying: progress.isLoading,
              onRetry: () => ref.invalidate(progressProvider(goal)),
            ),
          ),
        ],
      ),
      _ => const Padding(padding: padding, child: CardSkeleton(height: 172)),
    };
  }

  /// The unfinished session saved on this device, as a "Continue" entry.
  static ContinuePractice? _savedPractice(WidgetRef ref) {
    final saved = ref.watch(practiceSessionStoreProvider).active();
    if (saved == null) return null;
    final session = saved.session;
    final answered = {...session.answers.map((a) => a.position), ...saved.answers.keys};
    return ContinuePractice(
      sessionId: session.sessionId,
      title: session.title,
      answered: answered.length,
      count: session.questions.length,
    );
  }
}

class _Subjects extends ConsumerWidget {
  const _Subjects({required this.goal, required this.catalog});

  final Goal goal;
  final AsyncValue<Catalog> catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (catalog) {
      AsyncValue(:final value?) when value.subjects.isEmpty => SurfaceCard(
        child: EmptyState(
          icon: AppIcons.learn,
          tone: PastelTone.mint,
          title: 'No subjects yet',
          message: 'Questions for ${goal.label} are on the way.',
        ),
      ),
      AsyncValue(:final value?) => TwoColumnGrid(
        children: [
          for (final subject in value.subjects)
            PastelTile(
              tone: subjectTone(subject.tone),
              icon: subjectIcon(subject.icon),
              title: subject.name,
              subtitle: subjectCounts(subject),
              onTap: () => context.push(Routes.subject(subject.slug)),
            ),
        ],
      ),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load subjects',
        message: failureMessage(error),
        retrying: catalog.isLoading,
        onRetry: () => ref.invalidate(catalogProvider(goal)),
      ),
      _ => const SubjectGridSkeleton(),
    };
  }
}

enum _Tool { review, bookmarks }

class _PracticeTools extends ConsumerStatefulWidget {
  const _PracticeTools({required this.reviewsDue});

  /// Null while progress is loading or failed.
  final int? reviewsDue;

  @override
  ConsumerState<_PracticeTools> createState() => _PracticeToolsState();
}

class _PracticeToolsState extends ConsumerState<_PracticeTools> {
  _Tool? _starting;

  Future<void> _start(_Tool tool) async {
    if (_starting != null) return;
    setState(() => _starting = tool);
    final settings = SessionSettings(
      mode: tool == _Tool.review ? PracticeMode.review : PracticeMode.bookmarks,
      count: 20,
    );
    try {
      final session = await ref
          .read(practiceStarterProvider)
          .start(settings, idempotencyKey: randomHexId());
      if (mounted) unawaited(context.push(Routes.practiceSession(session.sessionId)));
    } on AppFailure catch (failure) {
      if (!mounted) return;
      final empty = switch (tool) {
        _Tool.review => 'Nothing to review yet. Questions you miss show up here.',
        _Tool.bookmarks => 'No bookmarks yet. Tap the bookmark on any question to save it.',
      };
      showAppToast(context, practiceStartError(failure, noQuestions: empty), icon: AppIcons.info);
    } finally {
      if (mounted) setState(() => _starting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final due = widget.reviewsDue;
    const soon = OverlineBadge(label: 'Soon');
    return TwoColumnGrid(
      children: [
        ToolTile(
          icon: AppIcons.refresh,
          tone: PastelTone.peach,
          title: 'Review',
          subtitle: switch (due) {
            null => 'Questions you missed',
            0 => 'Nothing due',
            _ => '$due due',
          },
          busy: _starting == _Tool.review,
          onTap: () => _start(_Tool.review),
        ),
        ToolTile(
          icon: AppIcons.bookmark,
          tone: PastelTone.sky,
          title: 'Bookmarks',
          subtitle: 'Saved questions',
          busy: _starting == _Tool.bookmarks,
          onTap: () => _start(_Tool.bookmarks),
        ),
        const ToolTile(
          icon: AppIcons.timer,
          tone: PastelTone.lavender,
          title: 'Self Challenge',
          subtitle: 'Timed test',
          badge: soon,
        ),
        const ToolTile(
          icon: AppIcons.learn,
          tone: PastelTone.mint,
          title: 'Fun & Learn',
          subtitle: 'Read and answer',
          badge: soon,
        ),
      ],
    );
  }
}
