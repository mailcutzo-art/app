import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../practice/data/practice_models.dart';
import '../practice/start_practice.dart';
import 'data/learn_models.dart';
import 'data/learn_repository.dart';
import 'data/question_models.dart';
import 'learn_providers.dart';
import 'widgets/learn_widgets.dart';
import 'widgets/question_widgets.dart';

/// `GET /v1/passages?subject=` while the screen is open (null: every subject).
final passagesProvider = FutureProvider.autoDispose.family<List<PassageItem>, String?>(
  (ref, subject) => ref.watch(learnRepositoryProvider).passages(subject: subject),
  retry: (_, _) => null,
);

/// Fun & Learn (`/learn/passages`): short passages by subject. Opening one
/// starts a `passage` session, which shows the passage to read first, then
/// its questions with an explanation after each.
class PassagesScreen extends ConsumerStatefulWidget {
  const PassagesScreen({super.key});

  @override
  ConsumerState<PassagesScreen> createState() => _PassagesScreenState();
}

class _PassagesScreenState extends ConsumerState<PassagesScreen> {
  String? _subject;

  /// The passage whose session is being created.
  String? _starting;

  Future<void> _open(PassageItem passage) async {
    if (_starting != null) return;
    setState(() => _starting = passage.id);
    try {
      final session = await ref
          .read(practiceStarterProvider)
          .start(
            SessionSettings(mode: PracticeMode.passage, passageId: passage.id),
            idempotencyKey: randomHexId(),
          );
      if (!mounted) return;
      await context.push(Routes.practiceSession(session.sessionId));
      // "Done" marks may have changed.
      if (mounted) ref.invalidate(passagesProvider(_subject));
    } on AppFailure catch (failure) {
      if (!mounted) return;
      showAppToast(
        context,
        practiceStartError(failure, noQuestions: 'This passage has no questions yet.'),
        icon: AppIcons.alert,
      );
    } finally {
      if (mounted) setState(() => _starting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = passagesProvider(_subject);
    final async = ref.watch(provider);
    final catalog = ref.watch(catalogProvider(ref.watch(learnGoalProvider))).value;
    final List<Widget> children = switch (async) {
      AsyncValue(:final value?) when value.isEmpty => [
        SurfaceCard(
          child: EmptyState(
            icon: AppIcons.learn,
            tone: PastelTone.mint,
            title: 'No passages yet',
            message: _subject == null
                ? 'New reading sets are on the way.'
                : 'None for ${subjectName(catalog, _subject!)} yet. Try another subject.',
          ),
        ),
      ],
      AsyncValue(:final value?) => [
        for (final passage in value)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _PassageRow(
              passage: passage,
              catalog: catalog,
              busy: _starting == passage.id,
              onTap: () => _open(passage),
            ),
          ),
      ],
      AsyncValue(:final error?) => [
        ErrorState(
          title: 'Couldn\'t load passages',
          message: failureMessage(error),
          retrying: async.isLoading,
          onRetry: () => ref.invalidate(provider),
        ),
      ],
      _ => const [RowsSkeleton()],
    };
    return Scaffold(
      appBar: AppTopBar(
        title: 'Fun & Learn',
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.learn),
      ),
      body: RefreshIndicator(
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        onRefresh: () async {
          ref.invalidate(provider);
          try {
            await ref.read(provider.future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 128),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                0,
                AppSpacing.gutter,
                AppSpacing.md,
              ),
              child: Text(
                'Read a short passage, answer its questions, then see the explanations.',
                style: context.text.bodyMedium,
              ),
            ),
            if (catalog != null && catalog.subjects.length > 1) ...[
              SubjectFilter(
                subjects: catalog.subjects,
                selected: _subject,
                onChanged: (subject) => setState(() => _subject = subject),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(children: children),
            ),
          ],
        ),
      ),
    );
  }
}

class _PassageRow extends StatelessWidget {
  const _PassageRow({
    required this.passage,
    required this.catalog,
    required this.busy,
    required this.onTap,
  });

  final PassageItem passage;
  final Catalog? catalog;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final subject = catalog?.subject(passage.subject);
    final pair = colors.pastel(subjectTone(subject?.tone ?? ''));
    return ListRowCard(
      title: passage.title,
      subtitle: [
        passage.chapter?.name ?? subjectName(catalog, passage.subject),
        plural(passage.questionCount, 'question'),
        difficultyLabel(passage.difficulty),
      ].join(' · '),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: HugeIcon(subjectIcon(subject?.icon ?? ''), size: 20, color: pair.onContainer),
      ),
      trailing: busy
          ? SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: colors.ink),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (passage.done) ...[
                  InfoChip(
                    icon: AppIcons.check,
                    label: 'Done',
                    background: colors.successContainer,
                    foreground: colors.onSuccessContainer,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                HugeIcon(AppIcons.chevronRight, size: 20, color: colors.inkMuted),
              ],
            ),
      onTap: busy ? null : onTap,
    );
  }
}
