import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../practice/data/practice_models.dart';
import '../practice/start_practice.dart';
import 'data/learn_models.dart';
import 'learn_providers.dart';
import 'widgets/learn_widgets.dart';

/// The Self Challenge set-up the screen starts from: 20 questions in 10
/// minutes, +4/−1 marking.
@immutable
class ChallengeSetup {
  const ChallengeSetup({
    required this.subject,
    this.chapters = const {},
    this.count = 20,
    this.minutes = 10,
    this.difficulty = Difficulty.mixed,
    this.marking = true,
    this.unseenOnly = false,
  });

  static const counts = [10, 20, 30, 50];
  static const minuteOptions = [5, 10, 15, 30, 60];

  final String subject;

  /// Chapter slugs; empty is the whole subject.
  final Set<String> chapters;
  final int count;
  final int minutes;
  final Difficulty difficulty;

  /// NEET marking: +4 for a correct answer, −1 for a wrong one.
  final bool marking;
  final bool unseenOnly;

  /// The `challenge` session body. Chapters keep the catalog's order.
  SessionSettings settings(CatalogSubject catalog) => SessionSettings(
    mode: PracticeMode.challenge,
    subject: subject,
    chapters: [
      for (final chapter in catalog.chapters)
        if (chapters.contains(chapter.slug)) chapter.slug,
    ],
    count: count,
    difficulty: difficulty,
    timeLimitS: minutes * 60,
    marking: marking ? Marking.neet : Marking.none,
    unseenOnly: unseenOnly,
  );

  ChallengeSetup copyWith({
    String? subject,
    Set<String>? chapters,
    int? count,
    int? minutes,
    Difficulty? difficulty,
    bool? marking,
    bool? unseenOnly,
  }) => ChallengeSetup(
    subject: subject ?? this.subject,
    chapters: chapters ?? this.chapters,
    count: count ?? this.count,
    minutes: minutes ?? this.minutes,
    difficulty: difficulty ?? this.difficulty,
    marking: marking ?? this.marking,
    unseenOnly: unseenOnly ?? this.unseenOnly,
  );
}

/// Self Challenge set-up (`/learn/challenge?subject=`): a subject and its
/// chapters, how many questions, the total time, difficulty, marking and
/// "Unseen only". Start creates a timed `challenge` session; answers are
/// shown at the end.
class ChallengeScreen extends ConsumerStatefulWidget {
  const ChallengeScreen({super.key, this.subject});

  /// Subject slug to start with.
  final String? subject;

  @override
  ConsumerState<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends ConsumerState<ChallengeScreen> {
  ChallengeSetup? _setup;
  bool _starting = false;
  String? _error;

  /// A retry of the same settings reuses the key, so a request that timed
  /// out after the server created the session doesn't create a second one.
  String? _key;
  SessionSettings? _keyFor;

  ChallengeSetup _setupFor(Catalog catalog) {
    final current = _setup;
    if (current != null && catalog.subject(current.subject) != null) return current;
    final subject = catalog.subject(widget.subject ?? '') ?? catalog.subjects.first;
    return ChallengeSetup(subject: subject.slug);
  }

  void _change(ChallengeSetup setup) => setState(() {
    _setup = setup;
    _error = null;
  });

  Future<void> _start(CatalogSubject subject, ChallengeSetup setup) async {
    final settings = setup.settings(subject);
    if (settings != _keyFor) {
      _keyFor = settings;
      _key = randomHexId();
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final session = await ref
          .read(practiceStarterProvider)
          .start(settings, idempotencyKey: _key!);
      if (!mounted) return;
      // The set-up is used up: a new start gets a new session.
      _keyFor = null;
      setState(() => _starting = false);
      await context.push(Routes.practiceSession(session.sessionId));
      // Back from the challenge: back to Learn too.
      if (mounted && context.canPop()) context.pop();
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(
          () => _error = practiceStartError(
            failure,
            noQuestions: setup.unseenOnly
                ? 'You\'ve seen every question that matches. Turn off "Unseen only" or pick more '
                      'chapters.'
                : null,
          ),
        );
      }
    } finally {
      if (mounted && _starting) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final goal = ref.watch(learnGoalProvider);
    final catalog = ref.watch(catalogProvider(goal));
    return Scaffold(
      appBar: const AppTopBar(title: 'Self Challenge'),
      body: switch (catalog) {
        AsyncValue(:final value?) when value.subjects.isEmpty => ListView(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          children: [
            SurfaceCard(
              child: EmptyState(
                icon: AppIcons.timer,
                tone: PastelTone.lavender,
                title: 'No subjects yet',
                message: 'Questions for ${goal.label} are on the way.',
              ),
            ),
          ],
        ),
        AsyncValue(:final value?) => _form(context, value),
        AsyncValue(:final error?) => ListView(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          children: [
            ErrorState(
              title: 'Couldn\'t load subjects',
              message: failureMessage(error),
              retrying: catalog.isLoading,
              onRetry: () => ref.invalidate(catalogProvider(goal)),
            ),
          ],
        ),
        _ => const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: RowsSkeleton(rows: 6),
        ),
      },
    );
  }

  Widget _form(BuildContext context, Catalog catalog) {
    final setup = _setupFor(catalog);
    final subject = catalog.subject(setup.subject)!;
    final text = context.text;
    final chapters = setup.chapters;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            children: [
              Gutter(
                child: Text(
                  'A timed test. Answers and explanations are shown at the end.',
                  style: text.bodyMedium,
                ),
              ),
              if (catalog.subjects.length > 1) ...[
                const OverlineLabel('Subject'),
                Gutter(
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    children: [
                      for (final s in catalog.subjects)
                        TallTapTarget(
                          onTap: () => _change(setup.copyWith(subject: s.slug, chapters: {})),
                          child: AppChip(
                            label: s.name,
                            icon: subjectIcon(s.icon),
                            selected: s.slug == setup.subject,
                            onSelected: (_) =>
                                _change(setup.copyWith(subject: s.slug, chapters: {})),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const OverlineLabel('Chapters'),
              SelectableRow(
                title: 'All chapters',
                subtitle: plural(subject.questionCount, 'question'),
                icon: AppIcons.allChapters,
                selected: chapters.isEmpty,
                onTap: () => _change(setup.copyWith(chapters: {})),
              ),
              for (final chapter in subject.chapters)
                SelectableRow(
                  title: chapter.name,
                  subtitle: plural(chapter.questionCount, 'question'),
                  selected: chapters.contains(chapter.slug),
                  onTap: () => _change(
                    setup.copyWith(
                      chapters: chapters.contains(chapter.slug)
                          ? ({...chapters}..remove(chapter.slug))
                          : {...chapters, chapter.slug},
                    ),
                  ),
                ),
              const OverlineLabel('Questions'),
              Gutter(
                child: AppSegmentedControl<int>(
                  segments: [
                    for (final n in ChallengeSetup.counts) AppSegment(value: n, label: '$n'),
                  ],
                  selected: setup.count,
                  onChanged: (n) => _change(setup.copyWith(count: n)),
                ),
              ),
              const OverlineLabel('Total time (minutes)'),
              Gutter(
                child: AppSegmentedControl<int>(
                  segments: [
                    for (final m in ChallengeSetup.minuteOptions) AppSegment(value: m, label: '$m'),
                  ],
                  selected: setup.minutes,
                  onChanged: (m) => _change(setup.copyWith(minutes: m)),
                ),
              ),
              const OverlineLabel('Difficulty'),
              Gutter(
                child: Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    for (final difficulty in Difficulty.values)
                      TallTapTarget(
                        onTap: () => _change(setup.copyWith(difficulty: difficulty)),
                        child: AppChip(
                          label: difficulty.label,
                          selected: setup.difficulty == difficulty,
                          onSelected: (_) => _change(setup.copyWith(difficulty: difficulty)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ToggleRow(
                title: '+4 / −1 marking',
                subtitle: 'Exam-style: 4 marks for right, −1 for wrong',
                icon: AppIcons.target,
                value: setup.marking,
                onChanged: (on) => _change(setup.copyWith(marking: on)),
              ),
              ToggleRow(
                title: 'Unseen only',
                subtitle: 'Only questions you\'ve never answered',
                icon: AppIcons.sparkles,
                value: setup.unseenOnly,
                onChanged: (on) => _change(setup.copyWith(unseenOnly: on)),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.sm,
              AppSpacing.gutter,
              AppSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  InlineError(message: _error!),
                  const SizedBox(height: AppSpacing.md),
                ],
                AppButton(
                  label: 'Start · ${setup.count} questions in ${setup.minutes} min',
                  trailingIcon: AppIcons.chevronRight,
                  loading: _starting,
                  onPressed: () => _start(subject, setup),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
