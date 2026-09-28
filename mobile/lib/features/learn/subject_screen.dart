import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import 'chapter_sheet.dart';
import 'data/learn_models.dart';
import 'learn_providers.dart';
import 'widgets/learn_widgets.dart';

/// A subject's chapters (`/learn/:subject`), on the Learn tab's navigator.
class SubjectScreen extends ConsumerWidget {
  const SubjectScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(learnGoalProvider);
    final catalog = ref.watch(catalogProvider(goal));
    final progress = ref.watch(progressProvider(goal));
    final subject = catalog.value?.subject(slug);

    final List<Widget> children = switch (catalog) {
      AsyncValue(hasValue: true) when subject == null => [
        Gutter(
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.learn,
              title: 'Not in ${goal.label}',
              message: 'This subject isn\'t part of the ${goal.label} syllabus here.',
              actionLabel: 'Back to Learn',
              onAction: () => context.go(Routes.learn),
            ),
          ),
        ),
      ],
      AsyncValue(hasValue: true) => _subject(context, ref, subject!, progress),
      AsyncValue(:final error?) => [
        Gutter(
          child: SurfaceCard(
            child: ErrorState(
              title: 'Couldn\'t load chapters',
              message: failureMessage(error),
              retrying: catalog.isLoading,
              onRetry: () => ref.invalidate(catalogProvider(goal)),
            ),
          ),
        ),
      ],
      _ => const [
        Padding(
          padding: EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.lg, AppSpacing.gutter, 0),
          child: Shimmer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: 180, height: 34),
                SizedBox(height: AppSpacing.sm),
                SkeletonBox(width: 140, height: 16),
              ],
            ),
          ),
        ),
        SizedBox(height: AppSpacing.xxl),
        Gutter(child: RowsSkeleton()),
      ],
    };

    return Scaffold(
      appBar: AppTopBar(
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.learn),
      ),
      body: RefreshIndicator(
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        onRefresh: () async {
          ref
            ..invalidate(catalogProvider(goal))
            ..invalidate(progressProvider(goal));
          try {
            await ref.read(catalogProvider(goal).future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: ListView(
          // Clears the floating nav bar.
          padding: const EdgeInsets.only(bottom: 128),
          physics: const AlwaysScrollableScrollPhysics(),
          children: children,
        ),
      ),
    );
  }

  List<Widget> _subject(
    BuildContext context,
    WidgetRef ref,
    CatalogSubject subject,
    AsyncValue<Progress> progress,
  ) {
    final colors = context.colors;
    final pair = colors.pastel(subjectTone(subject.tone));
    final goal = ref.read(learnGoalProvider);
    return [
      LargeTitle(
        title: subject.name,
        subtitle: subjectCounts(subject),
        trailing: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: HugeIcon(subjectIcon(subject.icon), size: 26, color: pair.onContainer),
        ),
      ),
      if (progress case AsyncValue(hasValue: false, :final error?))
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.lg,
            AppSpacing.gutter,
            0,
          ),
          child: ErrorState(
            compact: true,
            title: 'Couldn\'t load your progress',
            message: failureMessage(error),
            retrying: progress.isLoading,
            onRetry: () => ref.invalidate(progressProvider(goal)),
          ),
        ),
      const SectionHeader(title: 'Chapters'),
      if (subject.chapters.isEmpty)
        const Gutter(
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.learn,
              title: 'No chapters yet',
              message: 'Questions for this subject are on the way.',
            ),
          ),
        ),
      for (final (i, chapter) in subject.chapters.indexed)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: _ChapterRow(
            number: i + 1,
            chapter: chapter,
            tone: subjectTone(subject.tone),
            progress: progress.value?.chapter(subject.slug, chapter.slug),
            progressKnown: progress.hasValue,
            onTap: () => _openChapter(context, subject, chapter),
          ),
        ),
    ];
  }

  Future<void> _openChapter(
    BuildContext context,
    CatalogSubject subject,
    CatalogChapter chapter,
  ) async {
    final session = await showChapterSheet(context, subject: subject, chapter: chapter);
    if (session != null && context.mounted) {
      unawaited(context.push(Routes.practiceSession(session.sessionId)));
    }
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.number,
    required this.chapter,
    required this.tone,
    required this.progress,
    required this.progressKnown,
    required this.onTap,
  });

  final int number;
  final CatalogChapter chapter;
  final PastelTone tone;
  final ChapterProgress? progress;
  final bool progressKnown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(tone);
    final questions = plural(chapter.questionCount, 'question');
    final seen = progress?.seen ?? 0;
    final label = progress?.label;
    return ListRowCard(
      title: chapter.name,
      subtitle: switch ((progressKnown, seen)) {
        (false, _) => questions,
        (true, 0) => '$questions · Not started',
        _ => '$questions · $seen seen',
      },
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text('$number', style: context.text.labelLarge.copyWith(color: pair.onContainer)),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null) ...[
            ChapterLabelChip(label: label),
            const SizedBox(width: AppSpacing.sm),
          ],
          HugeIcon(AppIcons.chevronRight, size: 20, color: colors.inkMuted),
        ],
      ),
      onTap: onTap,
    );
  }
}
