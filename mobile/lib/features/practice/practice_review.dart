import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'data/practice_models.dart';
import 'practice_controller.dart';

/// Every question of a finished session with the user's pick, the correct
/// answer and the explanation. For Self Challenge this is where the answers
/// are first shown.
class PracticeReviewView extends StatelessWidget {
  const PracticeReviewView({
    super.key,
    required this.state,
    required this.onBack,
    required this.onReport,
  });

  final PracticeState state;
  final VoidCallback onBack;
  final ValueChanged<PracticeQuestion> onReport;

  @override
  Widget build(BuildContext context) {
    final questions = state.session.questions;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              AppIconButton(icon: AppIcons.back, semanticLabel: 'Back', onPressed: onBack),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text('Review answers', style: context.text.titleMedium)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.sm,
              AppSpacing.gutter,
              AppSpacing.xxl,
            ),
            itemCount: questions.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.lg),
            itemBuilder: (context, i) => ReviewQuestionCard(
              question: questions[i],
              number: i + 1,
              total: questions.length,
              answer: state.answers[questions[i].position],
              onReport: () => onReport(questions[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// One question in the review: what was picked, what was right, and why.
class ReviewQuestionCard extends StatelessWidget {
  const ReviewQuestionCard({
    super.key,
    required this.question,
    required this.number,
    required this.total,
    required this.answer,
    required this.onReport,
  });

  final PracticeQuestion question;
  final int number;
  final int total;

  /// Null when the question was never reached (a challenge that ran out).
  final SessionAnswer? answer;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final (label, icon, background, foreground) = switch (answer?.outcome) {
      AnswerOutcome.correct => (
        'Correct',
        AppIcons.checkCircle,
        colors.successContainer,
        colors.onSuccessContainer,
      ),
      AnswerOutcome.wrong => (
        'Wrong',
        AppIcons.close,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      AnswerOutcome.skipped => ('Skipped', AppIcons.chevronRight, colors.surfaceMuted, colors.ink),
      AnswerOutcome.timeout => (
        'Out of time',
        AppIcons.timer,
        colors.warningContainer,
        colors.onWarningContainer,
      ),
      null => ('Not answered', AppIcons.hourglass, colors.surfaceMuted, colors.inkMuted),
    };
    final tag = question.topic?.name ?? question.chapter?.name;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OverlineBadge(label: 'Question $number / $total', solid: true),
              const SizedBox(width: AppSpacing.sm),
              if (tag != null)
                Flexible(
                  child: OverlineBadge(label: tag, tone: PastelTone.sky),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: InfoChip(
              icon: icon,
              label: label,
              background: background,
              foreground: foreground,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          QuizText(question.stem, style: text.titleMedium.copyWith(height: 1.4)),
          const SizedBox(height: AppSpacing.lg),
          for (final (i, option) in question.options.indexed) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            AnswerOption(
              index: i,
              text: option.text,
              state: option.id == question.answer
                  ? AnswerOptionState.correct
                  : option.id == answer?.selectedOption
                  ? AnswerOptionState.wrong
                  : AnswerOptionState.dimmed,
            ),
          ],
          if (question.explanation.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: QuizText(question.explanation, style: text.bodyMedium),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Report',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              leadingIcon: AppIcons.alert,
              expand: false,
              onPressed: onReport,
            ),
          ),
        ],
      ),
    );
  }
}
