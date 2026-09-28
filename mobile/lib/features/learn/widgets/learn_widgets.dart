import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/app_failure.dart';
import '../data/learn_models.dart';
import '../tip_actions.dart';

/// Pastel tone for a catalog `tone` name; unknown names are neutral.
PastelTone subjectTone(String name) =>
    PastelTone.values.where((t) => t.name == name).firstOrNull ?? PastelTone.neutral;

/// Icon for a catalog `icon` name.
HugeIconData subjectIcon(String name) => switch (name) {
  'physics' => AppIcons.physics,
  'chemistry' => AppIcons.chemistry,
  'biology' => AppIcons.biology,
  'maths' => AppIcons.maths,
  _ => AppIcons.learn,
};

/// "1 question", "16 questions".
String plural(int count, String noun) => count == 1 ? '1 $noun' : '$count ${noun}s';

/// "2 chapters · 16 questions".
String subjectCounts(CatalogSubject subject) =>
    '${plural(subject.chapters.length, 'chapter')} · ${plural(subject.questionCount, 'question')}';

/// The text to show for a failed load. Only [AppFailure] messages are written
/// for people; anything else gets a generic line.
String failureMessage(Object error) =>
    error is AppFailure ? error.message : 'Something went wrong. Please try again.';

/// Two equal columns that size to their content (tiles keep their height).
class TwoColumnGrid extends StatelessWidget {
  const TwoColumnGrid({super.key, required this.children, this.spacing = AppSpacing.md});

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < children.length; i += 2)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : spacing),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: children[i]),
                SizedBox(width: spacing),
                Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox()),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Continue practice": the latest unfinished session, with Resume.
class ContinuePracticeCard extends StatelessWidget {
  const ContinuePracticeCard({super.key, required this.practice, required this.onResume});

  final ContinuePractice practice;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final done = practice.count == 0 ? 0.0 : practice.answered / practice.count;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const OverlineBadge(
                label: 'Continue practice',
                tone: PastelTone.lime,
                icon: AppIcons.quiz,
              ),
              const Spacer(),
              Text(
                '${practice.answered}/${practice.count}',
                style: text.numericMedium,
                semanticsLabel: '${practice.answered} of ${practice.count} answered',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            practice.title,
            style: text.titleMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.md),
          AppProgressBar(value: done, semanticLabel: 'Answered'),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            label: 'Resume',
            variant: AppButtonVariant.ink,
            size: AppButtonSize.medium,
            trailingIcon: AppIcons.chevronRight,
            onPressed: onResume,
          ),
        ],
      ),
    );
  }
}

/// One coach tip: a sentence and one button. Tips are instructions, so there
/// is never a chart here.
class CoachTipCard extends ConsumerStatefulWidget {
  const CoachTipCard({super.key, required this.tip, this.replaceRoute = false});

  final Tip tip;

  /// Open a suggested session in place of the current screen.
  final bool replaceRoute;

  @override
  ConsumerState<CoachTipCard> createState() => _CoachTipCardState();
}

class _CoachTipCardState extends ConsumerState<CoachTipCard> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await openTip(context, ref, widget.tip, replace: widget.replaceRoute);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.lemon;
    final actionable = tipDestination(widget.tip) != null;
    return SurfaceCard(
      color: pair.container,
      bordered: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.isDark ? colors.surface : Colors.white,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: HugeIcon(AppIcons.idea, size: 22, color: pair.onContainer),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('COACH TIP', style: text.overline.copyWith(color: pair.onContainer)),
                    const SizedBox(height: AppSpacing.xs),
                    QuizText(
                      widget.tip.message,
                      style: text.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (actionable) ...[
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: tipButtonLabel(widget.tip),
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.medium,
              trailingIcon: AppIcons.chevronRight,
              expand: false,
              loading: _busy,
              onPressed: _run,
            ),
          ],
        ],
      ),
    );
  }
}

/// White practice-tool tile with a pastel icon circle (reference 2).
class ToolTile extends StatelessWidget {
  const ToolTile({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.badge,
    this.busy = false,
  });

  final HugeIconData icon;
  final PastelTone tone;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  /// Top-right corner (e.g. a "Soon" badge).
  final Widget? badge;

  /// Shows progress in the corner and ignores taps.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(tone);
    return SurfaceCard(
      onTap: busy ? null : onTap,
      semanticLabel: busy ? '$title, loading' : title,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
                child: HugeIcon(icon, size: 22, color: pair.onContainer),
              ),
              const Spacer(),
              if (busy)
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: colors.ink),
                )
              else
                ?badge,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            style: context.text.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(subtitle, style: context.text.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// "Strong" (success colours) or "Needs work" (warning colours) next to a
/// chapter. The only analytics on the Learn screens, and it's a word.
class ChapterLabelChip extends StatelessWidget {
  const ChapterLabelChip({super.key, required this.label});

  final ChapterLabel label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return switch (label) {
      ChapterLabel.strong => InfoChip(
        label: 'Strong',
        background: colors.successContainer,
        foreground: colors.onSuccessContainer,
      ),
      ChapterLabel.needsWork => InfoChip(
        label: 'Needs work',
        background: colors.warningContainer,
        foreground: colors.onWarningContainer,
      ),
    };
  }
}

/// Loading placeholder shaped like a card.
class CardSkeleton extends StatelessWidget {
  const CardSkeleton({super.key, this.height = 150});

  final double height;

  @override
  Widget build(BuildContext context) => Shimmer(
    child: SkeletonBox(height: height, radius: AppRadii.xl),
  );
}

/// Loading placeholder shaped like the subject grid.
class SubjectGridSkeleton extends StatelessWidget {
  const SubjectGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Shimmer(
    child: TwoColumnGrid(
      children: [for (var i = 0; i < 4; i++) const SkeletonBox(height: 150, radius: AppRadii.xxl)],
    ),
  );
}

/// Loading placeholder shaped like a list of chapter rows.
class RowsSkeleton extends StatelessWidget {
  const RowsSkeleton({super.key, this.rows = 4});

  final int rows;

  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      children: [
        for (var i = 0; i < rows; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: SkeletonBox(height: 76, radius: AppRadii.xl),
          ),
      ],
    ),
  );
}

/// A small uppercase label above a group of settings in a sheet.
class OverlineLabel extends StatelessWidget {
  const OverlineLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.gutter,
      AppSpacing.lg,
      AppSpacing.gutter,
      AppSpacing.sm,
    ),
    child: Text(text.toUpperCase(), style: context.text.overline),
  );
}

/// Gives a 40 dp chip a 48 dp tall tap target without changing its look.
class TallTapTarget extends StatelessWidget {
  const TallTapTarget({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSizes.minTouch),
      child: Center(widthFactor: 1, child: child),
    ),
  );
}

/// An error inside a sheet or form, read out when it appears.
class InlineError extends StatelessWidget {
  const InlineError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            HugeIcon(AppIcons.alert, size: 20, color: colors.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: context.text.labelMedium.copyWith(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
