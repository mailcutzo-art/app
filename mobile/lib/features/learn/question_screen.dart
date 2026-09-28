import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/app_failure.dart';
import '../practice/data/practice_models.dart';
import 'bookmark_states.dart';
import 'data/learn_repository.dart';
import 'data/question_models.dart';
import 'report_sheet.dart';
import 'widgets/learn_widgets.dart';

/// `GET /v1/questions/{ref}` while the screen is open.
final questionDetailProvider = FutureProvider.autoDispose.family<QuestionDetail, String>(
  (ref, questionRef) => ref.watch(learnRepositoryProvider).question(questionRef),
  retry: (_, _) => null,
);

/// One question (`/learn/question/:ref`), opened from search or bookmarks:
/// try it by tapping an option, or reveal the answer; then the explanation.
/// Bookmark it or report it from here.
class QuestionScreen extends ConsumerStatefulWidget {
  const QuestionScreen({super.key, required this.questionRef});

  final String questionRef;

  @override
  ConsumerState<QuestionScreen> createState() => _QuestionScreenState();
}

class _QuestionScreenState extends ConsumerState<QuestionScreen> {
  /// The option the user tried, if any.
  int? _picked;
  bool _revealed = false;

  late final _provider = questionDetailProvider(widget.questionRef);

  void _pick(int optionId) => setState(() {
    _picked = optionId;
    _revealed = true;
  });

  Future<void> _toggleBookmark(bool bookmarked) async {
    final failure = await ref
        .read(bookmarkStatesProvider.notifier)
        .set(widget.questionRef, bookmarked: !bookmarked);
    if (failure != null && mounted) {
      showAppToast(context, bookmarkFailureMessage(failure), icon: AppIcons.alert);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_provider);
    final question = async.value;
    final bookmarked = question == null
        ? null
        : ref.watch(bookmarkStatesProvider.select((s) => s[question.ref] ?? question.bookmarked));
    return Scaffold(
      appBar: AppTopBar(
        title: 'Question',
        actions: [
          if (bookmarked != null)
            AppIconButton(
              icon: AppIcons.bookmark,
              semanticLabel: bookmarked ? 'Remove bookmark' : 'Bookmark question',
              variant: bookmarked ? AppIconButtonVariant.ink : AppIconButtonVariant.surface,
              motion: IconMotions.bookmark,
              onPressed: () => _toggleBookmark(bookmarked),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          128,
        ),
        children: switch (async) {
          AsyncValue(value: final q?) => _question(context, q),
          AsyncValue(error: NotFoundFailure()) => const [
            EmptyState(
              icon: AppIcons.hourglass,
              title: 'This question isn\'t available',
              message: 'It may have been removed after a review.',
            ),
          ],
          AsyncValue(:final error?) => [
            ErrorState(
              title: 'Couldn\'t load this question',
              message: failureMessage(error),
              retrying: async.isLoading,
              onRetry: () => ref.invalidate(_provider),
            ),
          ],
          _ => const [
            Shimmer(
              child: Column(
                children: [
                  SkeletonBox(height: 160, radius: AppRadii.xxl),
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
          ],
        },
      ),
    );
  }

  List<Widget> _question(BuildContext context, QuestionDetail q) {
    final text = context.text;
    final colors = context.colors;
    final correctIndex = q.options.indexWhere((o) => o.id == q.answer);
    final letter = String.fromCharCode(65 + correctIndex);
    final tag = q.topic?.name ?? q.chapter?.name;
    return [
      SurfaceCard(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (tag != null) OverlineBadge(label: tag, tone: PastelTone.sky),
                OverlineBadge(label: difficultyLabel(q.difficulty)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            QuizText(q.stem, style: text.titleMedium.copyWith(height: 1.4)),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      for (final (i, option) in q.options.indexed) ...[
        if (i > 0) const SizedBox(height: AppSpacing.md),
        AnswerOption(
          index: i,
          text: option.text,
          state: _optionState(q, option),
          onTap: _revealed ? null : () => _pick(option.id),
        ),
      ],
      const SizedBox(height: AppSpacing.lg),
      if (!_revealed)
        AppButton(
          label: 'Show answer',
          variant: AppButtonVariant.secondary,
          leadingIcon: AppIcons.view,
          onPressed: () => setState(() => _revealed = true),
        )
      else ...[
        Semantics(
          liveRegion: true,
          child: Align(
            alignment: Alignment.centerLeft,
            child: switch (_picked) {
              null => InfoChip(
                icon: AppIcons.info,
                label: 'The answer is $letter',
                background: colors.surfaceMuted,
              ),
              final picked when picked == q.answer => InfoChip(
                icon: AppIcons.checkCircle,
                label: 'Correct',
                background: colors.successContainer,
                foreground: colors.onSuccessContainer,
              ),
              _ => InfoChip(
                icon: AppIcons.close,
                label: 'Not quite · the answer is $letter',
                background: colors.errorContainer,
                foreground: colors.onErrorContainer,
              ),
            },
          ),
        ),
        if (q.explanation.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          ExplanationCard(
            text: q.explanation,
            correct: _picked == null ? null : _picked == q.answer,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        AppButton(
          label: 'Try again',
          variant: AppButtonVariant.ghost,
          leadingIcon: AppIcons.refresh,
          onPressed: () => setState(() {
            _picked = null;
            _revealed = false;
          }),
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      AppButton(
        label: 'Report question',
        variant: AppButtonVariant.ghost,
        leadingIcon: AppIcons.alert,
        onPressed: () => showReportSheet(context, questionRef: q.ref),
      ),
    ];
  }

  AnswerOptionState _optionState(QuestionDetail q, PracticeOption option) {
    if (!_revealed) return AnswerOptionState.idle;
    if (option.id == q.answer) return AnswerOptionState.correct;
    if (option.id == _picked) return AnswerOptionState.wrong;
    return AnswerOptionState.dimmed;
  }
}
