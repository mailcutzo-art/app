import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../../core/network/connectivity.dart';
import '../learn/learn_providers.dart';
import '../learn/report_sheet.dart';
import '../learn/widgets/learn_widgets.dart';
import 'ask_ai.dart';
import 'challenge_clock.dart';
import 'data/practice_models.dart';
import 'practice_controller.dart';
import 'practice_review.dart';
import 'practice_summary.dart';

/// A practice session (`/practice/:sessionId`), full screen above the tabs.
///
/// Each question is timed with a stopwatch from the moment it shows; the
/// stopwatch pauses while the app is in the background, a sheet is open or
/// the passage is being read. Answers go to the upload queue at once, so
/// moving on never waits for the network.
///
/// * Self Challenge counts down one total time from the server's deadline
///   (it keeps running in the background) and ends the session when it runs
///   out. Answers are shown at the end, in the review.
/// * Fun & Learn shows the passage first, and keeps it a tap away.
class PracticeScreen extends ConsumerStatefulWidget {
  const PracticeScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends ConsumerState<PracticeScreen> {
  late final Stopwatch _clock = ref.read(practiceStopwatchProvider)();
  late final AppLifecycleListener _lifecycle;

  /// Time left on a timed question, for the countdown ring.
  final _left = ValueNotifier<Duration?>(null);
  Timer? _ticker;

  /// Self Challenge: the total time left, counted down from the deadline.
  final _challengeLeft = ValueNotifier<Duration?>(null);
  ChallengeClock? _challenge;
  Timer? _challengeTicker;

  /// The question the clock is timing.
  String? _timing;
  bool _hidden = false;
  bool _sheetOpen = false;

  /// Fun & Learn: the passage is on screen before the questions.
  bool _reading = false;
  bool _readingDecided = false;

  /// The finished session's answers are on screen instead of its summary.
  bool _reviewing = false;

  bool get _paused => _hidden || _sheetOpen || _reading;

  late final _provider = practiceControllerProvider(widget.sessionId);

  PracticeController get _controller => ref.read(_provider.notifier);

  PracticeState? get _state => ref.read(_provider).value;

  int get _elapsedMs => _clock.elapsedMilliseconds;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _hidden = true;
        _pauseClock();
      },
      onShow: () {
        _hidden = false;
        _resumeClock();
        // The challenge went on while the app was away.
        _tickChallenge();
      },
    );
    ref.listenManual(_provider, (_, next) => _follow(next.value), fireImmediately: true);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticker?.cancel();
    _challengeTicker?.cancel();
    _left.dispose();
    _challengeLeft.dispose();
    super.dispose();
  }

  /// Starts timing a question when it appears and stops once it's answered.
  void _follow(PracticeState? s) {
    if (s != null && !_readingDecided) {
      _readingDecided = true;
      // A passage is read first, unless the questions were already started.
      _reading = s.session.passage != null && s.answers.isEmpty && !s.done;
    }
    if (s != null && !s.done && _challenge == null) _startChallenge(s.session);
    if (s != null && s.done) {
      _challengeTicker?.cancel();
      _challengeTicker = null;
    }
    if (s == null || s.done || s.answer != null) {
      _pauseClock();
      return;
    }
    if (_timing == s.question.ref) return;
    _timing = s.question.ref;
    _clock
      ..reset()
      ..start();
    final limit = s.session.perQuestionMs;
    _left.value = limit == null ? null : Duration(milliseconds: limit);
    if (limit != null) _startTicker(limit);
    if (_paused) _pauseClock();
  }

  void _startChallenge(PracticeSession session) {
    final clock = _challenge = ChallengeClock.of(session);
    if (clock == null) return;
    _challengeTicker = Timer.periodic(const Duration(seconds: 1), (_) => _tickChallenge());
    // Not from inside the provider listener: this may end the session.
    scheduleMicrotask(_tickChallenge);
  }

  /// Updates the countdown and ends the challenge when time is up. The
  /// deadline is the server's, so this reads the wall clock, not the
  /// stopwatch.
  void _tickChallenge() {
    final clock = _challenge;
    if (!mounted || clock == null || _challengeTicker == null) return;
    final left = clock.remaining(ref.read(practiceNowProvider)());
    _challengeLeft.value = left;
    if (left > Duration.zero) return;
    _challengeTicker?.cancel();
    _challengeTicker = null;
    _pauseClock();
    unawaited(_controller.finish(timeMs: _elapsedMs, timeUp: true));
  }

  void _pauseClock() {
    _clock.stop();
    _ticker?.cancel();
    _ticker = null;
  }

  void _resumeClock() {
    if (_paused) return;
    final s = _state;
    if (s == null || s.done || s.answer != null || _timing != s.question.ref) return;
    _clock.start();
    if (s.session.perQuestionMs case final limit?) _startTicker(limit);
  }

  void _startTicker(int limitMs) {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick(limitMs));
  }

  void _tick(int limitMs) {
    final left = Duration(milliseconds: limitMs) - _clock.elapsed;
    if (left > Duration.zero) {
      _left.value = left;
      return;
    }
    _left.value = Duration.zero;
    _pauseClock();
    _controller.timeOut();
  }

  void _choose(int optionId) => _controller.choose(optionId, timeMs: _elapsedMs);

  void _skip() {
    final s = _state;
    if (s == null) return;
    if (s.session.instantFeedback) {
      _controller.skip(timeMs: _elapsedMs);
    } else if (s.isLast) {
      unawaited(_controller.finish(timeMs: _elapsedMs));
    } else {
      _controller.next(timeMs: _elapsedMs);
    }
  }

  void _next() => _controller.next(timeMs: _elapsedMs);

  Future<void> _finish() => _controller.finish(timeMs: _elapsedMs);

  Future<void> _toggleBookmark() async {
    final failure = await _controller.toggleBookmark();
    if (failure == null || !mounted) return;
    final message = switch (failure) {
      ConflictFailure(code: 'BOOKMARK_LIMIT') => 'You\'ve reached the bookmark limit.',
      NetworkFailure() => 'You\'re offline, so the bookmark wasn\'t saved.',
      _ => 'Couldn\'t save the bookmark. Please try again.',
    };
    showAppToast(context, message, icon: AppIcons.alert);
  }

  /// Opens a sheet with the question clock paused.
  Future<T> _withSheet<T>(Future<T> Function() open) async {
    _sheetOpen = true;
    _pauseClock();
    try {
      return await open();
    } finally {
      if (mounted) {
        _sheetOpen = false;
        _resumeClock();
      }
    }
  }

  Future<void> _report(PracticeQuestion question) =>
      _withSheet(() => showReportSheet(context, questionRef: question.ref));

  Future<void> _showPassage(Passage passage) => _withSheet(
    () => showAppSheet<void>(
      context,
      builder: (context) => SheetScaffold(
        title: passage.title,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.xl,
          ),
          child: PassageText(passage.body),
        ),
      ),
    ),
  );

  void _startQuestions() {
    setState(() => _reading = false);
    _resumeClock();
  }

  Future<void> _requestClose() async {
    final s = _state;
    if (s == null || s.done) {
      if (_reviewing) {
        setState(() => _reviewing = false);
      } else {
        _leave();
      }
      return;
    }
    final challenge = _challenge != null;
    final choice = await _withSheet(
      () => showAppSheet<_LeaveChoice>(
        context,
        builder: (context) => SheetScaffold(
          title: challenge ? 'Leave the challenge?' : 'Leave practice?',
          subtitle: challenge
              ? 'The timer keeps running. Your answers so far are saved.'
              : 'Your answers so far are saved.',
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppButton(
                label: challenge ? 'Keep going' : 'Keep practising',
                onPressed: () => Navigator.pop(context, _LeaveChoice.stay),
              ),
              if (challenge) ...[
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: 'Submit now',
                  variant: AppButtonVariant.secondary,
                  onPressed: () => Navigator.pop(context, _LeaveChoice.submit),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Leave',
                variant: challenge ? AppButtonVariant.ghost : AppButtonVariant.secondary,
                onPressed: () => Navigator.pop(context, _LeaveChoice.leave),
              ),
            ],
          ),
          child: const SizedBox.shrink(),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _LeaveChoice.leave:
        _leave();
      case _LeaveChoice.submit:
        // Ends the challenge where it is; unanswered questions stay so.
        await _controller.finish(timeMs: _elapsedMs, timeUp: true);
      case _LeaveChoice.stay || null:
        break;
    }
  }

  void _leave() {
    // "Continue practice" and chapter progress on the Learn tab change.
    ref.invalidate(progressProvider);
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.learn);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_provider);
    final (phase, body) = switch (async) {
      AsyncValue(value: final s?) when s.done && _reviewing => (
        'review',
        PracticeReviewView(
          state: s,
          onBack: () => setState(() => _reviewing = false),
          onReport: _report,
        ),
      ),
      AsyncValue(value: final s?) when s.done => (
        'summary',
        PracticeSummaryView(
          state: s,
          onDone: _leave,
          onReview: () => setState(() => _reviewing = true),
        ),
      ),
      AsyncValue(value: final s?) when _reading && s.session.passage != null => (
        'passage',
        _PassageView(
          passage: s.session.passage!,
          questions: s.total,
          onStart: _startQuestions,
          onClose: _requestClose,
        ),
      ),
      AsyncValue(value: final s?) => ('question', _questionView(context, s)),
      AsyncValue(:final error?) => (
        'error',
        _LoadError(
          error: error,
          retrying: async.isLoading,
          onRetry: () => ref.invalidate(_provider),
          onClose: _leave,
        ),
      ),
      _ => ('loading', const _PracticeSkeleton()),
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestClose());
      },
      child: Scaffold(
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.medium),
            child: KeyedSubtree(key: ValueKey(phase), child: body),
          ),
        ),
      ),
    );
  }

  Widget _questionView(BuildContext context, PracticeState s) {
    final question = s.question;
    final online = ref.watch(isOnlineProvider);
    final goal = ref.watch(learnGoalProvider);
    final toneName = ref.watch(
      catalogProvider(goal)
          .select((c) => c.value?.subjectOfChapter(question.chapter?.slug ?? '')?.tone),
    );
    final reduced = AppMotion.reduced(context);
    return Column(
      children: [
        _TopBar(
          state: s,
          left: _left,
          challengeLeft: _challenge == null ? null : _challengeLeft,
          onClose: _requestClose,
          onBookmark: _toggleBookmark,
          onReport: () => _report(question),
          onPassage: switch (s.session.passage) {
            final passage? => () => _showPassage(passage),
            null => null,
          },
        ),
        OfflineBanner(visible: !online, message: 'You\'re offline — answers will sync later'),
        Expanded(
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.medium),
            switchInCurve: AppMotion.emphasized,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: reduced ? Offset.zero : const Offset(0.06, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _QuestionBody(
              key: ValueKey(question.ref),
              state: s,
              tone: toneName == null ? PastelTone.sky : subjectTone(toneName),
              onChoose: _choose,
            ),
          ),
        ),
        _BottomBar(state: s, onSkip: _skip, onNext: _next, onFinish: _finish),
      ],
    );
  }
}

enum _LeaveChoice { stay, submit, leave }

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.left,
    required this.challengeLeft,
    required this.onClose,
    required this.onBookmark,
    required this.onReport,
    required this.onPassage,
  });

  final PracticeState state;
  final ValueListenable<Duration?> left;

  /// Self Challenge only.
  final ValueListenable<Duration?>? challengeLeft;
  final VoidCallback onClose;
  final VoidCallback onBookmark;
  final VoidCallback onReport;

  /// Fun & Learn only: shows the passage again.
  final VoidCallback? onPassage;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final colors = context.colors;
    final limit = state.session.perQuestionMs;
    final bookmarked = state.bookmarked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, 0),
      child: Column(
        children: [
          Row(
            children: [
              AppIconButton(
                icon: AppIcons.close,
                semanticLabel: 'Leave practice',
                onPressed: onClose,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  state.session.title,
                  style: text.labelMedium.copyWith(color: colors.inkMuted),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              if (limit != null) ...[
                ValueListenableBuilder<Duration?>(
                  valueListenable: left,
                  builder: (context, left, _) => _Countdown(
                    left: left ?? Duration(milliseconds: limit),
                    limitMs: limit,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (challengeLeft case final challengeLeft?) ...[
                ValueListenableBuilder<Duration?>(
                  valueListenable: challengeLeft,
                  builder: (context, left, _) => ChallengeTimerChip(left: left),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (onPassage != null) ...[
                AppIconButton(
                  icon: AppIcons.learn,
                  semanticLabel: 'Read the passage',
                  onPressed: onPassage,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              AppIconButton(
                icon: AppIcons.alert,
                semanticLabel: 'Report question',
                onPressed: onReport,
              ),
              const SizedBox(width: AppSpacing.sm),
              AppIconButton(
                icon: AppIcons.bookmark,
                semanticLabel: bookmarked ? 'Remove bookmark' : 'Bookmark question',
                variant: bookmarked ? AppIconButtonVariant.ink : AppIconButtonVariant.surface,
                motion: IconMotions.bookmark,
                onPressed: onBookmark,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SegmentedProgress(
            total: state.total,
            completed: state.answers.length,
            gap: state.total > 15 ? 3 : 6,
          ),
        ],
      ),
    );
  }
}

/// The total time left in a Self Challenge ("9:41"); warning colours in
/// the last minute.
class ChallengeTimerChip extends StatelessWidget {
  const ChallengeTimerChip({super.key, required this.left});

  /// Null before the first tick.
  final Duration? left;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final left = this.left;
    final low = left != null && left <= ChallengeClock.lowAfter;
    return Semantics(
      label: left == null ? 'Timer' : countdownSemantics(left),
      excludeSemantics: true,
      child: InfoChip(
        icon: AppIcons.timer,
        label: left == null ? '–:––' : formatCountdown(left),
        background: low ? colors.warningContainer : colors.surfaceMuted,
        foreground: low ? colors.onWarningContainer : colors.ink,
      ),
    );
  }
}

/// Fun & Learn: the passage, then a button to its questions.
class _PassageView extends StatelessWidget {
  const _PassageView({
    required this.passage,
    required this.questions,
    required this.onStart,
    required this.onClose,
  });

  final Passage passage;
  final int questions;
  final VoidCallback onStart;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            0,
          ),
          child: Row(
            children: [
              AppIconButton(
                icon: AppIcons.close,
                semanticLabel: 'Leave practice',
                onPressed: onClose,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.lg,
              AppSpacing.gutter,
              AppSpacing.lg,
            ),
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: OverlineBadge(
                  label: 'Fun & Learn',
                  tone: PastelTone.mint,
                  icon: AppIcons.learn,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(passage.title, style: text.headlineMedium),
              const SizedBox(height: AppSpacing.lg),
              PassageText(passage.body),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.lg,
          ),
          child: AppButton(
            label: questions == 1 ? 'Answer the question' : 'Answer $questions questions',
            trailingIcon: AppIcons.chevronRight,
            onPressed: onStart,
          ),
        ),
      ],
    );
  }
}

/// A passage in quiz markup, one paragraph per blank-line-separated block.
class PassageText extends StatelessWidget {
  const PassageText(this.body, {super.key});

  final String body;

  @override
  Widget build(BuildContext context) {
    final paragraphs = body
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final style = context.text.bodyLarge.copyWith(height: 1.55);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, paragraph) in paragraphs.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          QuizText(paragraph, style: style),
        ],
      ],
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.left, required this.limitMs});

  final Duration left;
  final int limitMs;

  @override
  Widget build(BuildContext context) {
    final seconds = (left.inMilliseconds / 1000).ceil();
    // With reduced motion the ring moves once a second instead of smoothly.
    final progress = AppMotion.reduced(context)
        ? seconds * 1000 / limitMs
        : left.inMilliseconds / limitMs;
    return CountdownRing(progress: progress, label: '$seconds', size: AppSizes.iconButton);
  }
}

class _QuestionBody extends StatelessWidget {
  const _QuestionBody({super.key, required this.state, required this.tone, required this.onChoose});

  final PracticeState state;
  final PastelTone tone;
  final ValueChanged<int> onChoose;

  @override
  Widget build(BuildContext context) {
    final question = state.question;
    final open = state.answer == null && !state.finishing;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.lg,
        AppSpacing.gutter,
        AppSpacing.lg,
      ),
      children: [
        QuestionCard(
          number: state.index + 1,
          total: state.total,
          text: question.stem,
          tag: question.topic?.name ?? question.chapter?.name,
          tone: tone,
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final (i, option) in question.options.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          AnswerOption(
            index: i,
            text: option.text,
            state: _optionState(option),
            onTap: open ? () => onChoose(option.id) : null,
          ),
        ],
      ],
    );
  }

  AnswerOptionState _optionState(PracticeOption option) {
    final answer = state.answer;
    if (answer == null || !state.session.instantFeedback) {
      final picked = answer?.selectedOption ?? state.selection;
      return picked == option.id ? AnswerOptionState.selected : AnswerOptionState.idle;
    }
    if (option.id == state.question.answer) return AnswerOptionState.correct;
    if (option.id == answer.selectedOption) return AnswerOptionState.wrong;
    return AnswerOptionState.dimmed;
  }
}

/// Skip before answering; after the reveal, the explanation and Next.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.state,
    required this.onSkip,
    required this.onNext,
    required this.onFinish,
  });

  final PracticeState state;
  final VoidCallback onSkip;
  final VoidCallback onNext;
  final Future<void> Function() onFinish;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.medium);
    final s = state;
    final Widget child;
    if (s.revealed) {
      child = _FeedbackPanel(
        key: ValueKey('feedback-${s.question.ref}'),
        state: s,
        onNext: onNext,
        onFinish: onFinish,
      );
    } else if (s.selection != null) {
      // End-of-session feedback: the pick is made, move on.
      child = Padding(
        key: const ValueKey('next'),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.lg,
        ),
        child: AppButton(
          label: s.isLast ? 'Finish' : 'Next',
          trailingIcon: s.isLast ? AppIcons.check : AppIcons.chevronRight,
          loading: s.finishing,
          onPressed: s.isLast ? onFinish : onNext,
        ),
      );
    } else {
      child = Padding(
        key: const ValueKey('skip'),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.lg,
        ),
        child: AppButton(
          label: 'Skip',
          variant: AppButtonVariant.ghost,
          loading: s.finishing,
          onPressed: s.answer == null ? onSkip : null,
        ),
      );
    }
    final switcher = AnimatedSwitcher(
      duration: duration,
      switchInCurve: AppMotion.emphasized,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
    // A zero-length AnimatedSize (reduced motion) re-dirties itself mid-layout.
    if (duration == Duration.zero) return switcher;
    return AnimatedSize(
      duration: duration,
      curve: AppMotion.emphasized,
      alignment: Alignment.bottomCenter,
      child: switcher,
    );
  }
}

class _FeedbackPanel extends ConsumerWidget {
  const _FeedbackPanel({
    super.key,
    required this.state,
    required this.onNext,
    required this.onFinish,
  });

  final PracticeState state;
  final VoidCallback onNext;
  final Future<void> Function() onFinish;

  Future<void> _askAi(BuildContext context, WidgetRef ref) async {
    final goal = ref.read(meProvider).goal;
    final target = await askAiAbout(ref, state.question, goal: goal);
    final message = askAiMessage(target);
    if (message != null && context.mounted) showAppToast(context, message, icon: AppIcons.info);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.text;
    final question = state.question;
    final answer = state.answer!;
    final letter = String.fromCharCode(
      65 + question.options.indexWhere((o) => o.id == question.answer),
    );
    final (label, icon, background, foreground) = switch (answer.outcome) {
      AnswerOutcome.correct => (
        'Correct',
        AppIcons.checkCircle,
        colors.successContainer,
        colors.onSuccessContainer,
      ),
      AnswerOutcome.wrong => (
        'Not quite · the answer is $letter',
        AppIcons.close,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      AnswerOutcome.skipped => (
        'Skipped · the answer is $letter',
        AppIcons.chevronRight,
        colors.surfaceMuted,
        colors.ink,
      ),
      AnswerOutcome.timeout => (
        'Time\'s up · the answer is $letter',
        AppIcons.timer,
        colors.warningContainer,
        colors.onWarningContainer,
      ),
    };
    return SurfaceCard(
      elevated: true,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadii.xxl)),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.lg,
        AppSpacing.gutter,
        AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: InfoChip(
              icon: icon,
              label: label,
              background: background,
              foreground: foreground,
            ),
          ),
          if (question.explanation.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.28),
              child: SingleChildScrollView(
                child: QuizText(question.explanation, style: text.bodyLarge),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              // A skipped question gets a way to learn it: an AI tutor with the question ready.
              if (answer.outcome == AnswerOutcome.skipped) ...[
                AskAiButton(onPressed: () => _askAi(context, ref)),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: AppButton(
                  label: state.isLast ? 'Finish' : 'Next',
                  trailingIcon: state.isLast ? AppIcons.check : AppIcons.chevronRight,
                  loading: state.finishing,
                  onPressed: state.isLast ? onFinish : onNext,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({
    required this.error,
    required this.retrying,
    required this.onRetry,
    required this.onClose,
  });

  final Object error;
  final bool retrying;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            0,
          ),
          child: Row(
            children: [
              AppIconButton(icon: AppIcons.close, semanticLabel: 'Close', onPressed: onClose),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: error is NotFoundFailure
                  ? EmptyState(
                      icon: AppIcons.hourglass,
                      title: 'This practice has ended',
                      message: 'Practice sessions last a day. Start a new one from Learn.',
                      actionLabel: 'Back to Learn',
                      onAction: onClose,
                    )
                  : ErrorState(
                      title: 'Couldn\'t open this practice',
                      message: failureMessage(error),
                      retrying: retrying,
                      onRetry: onRetry,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Loading placeholder shaped like a question.
class _PracticeSkeleton extends StatelessWidget {
  const _PracticeSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, 0),
      child: Shimmer(
        child: Column(
          children: [
            Row(
              children: [
                SkeletonBox(height: AppSizes.iconButton, circle: true),
                Spacer(),
                SkeletonBox(height: AppSizes.iconButton, circle: true),
              ],
            ),
            SizedBox(height: AppSpacing.md),
            SkeletonBox(height: 6),
            SizedBox(height: AppSpacing.lg),
            SkeletonBox(height: 180, radius: AppRadii.xxl),
            SizedBox(height: AppSpacing.lg),
            SkeletonBox(height: AppSizes.answerOptionMin, radius: AppRadii.lg),
            SizedBox(height: AppSpacing.md),
            SkeletonBox(height: AppSizes.answerOptionMin, radius: AppRadii.lg),
            SizedBox(height: AppSpacing.md),
            SkeletonBox(height: AppSizes.answerOptionMin, radius: AppRadii.lg),
            SizedBox(height: AppSpacing.md),
            SkeletonBox(height: AppSizes.answerOptionMin, radius: AppRadii.lg),
          ],
        ),
      ),
    );
  }
}
