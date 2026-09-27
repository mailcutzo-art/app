import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../learn/widgets/learn_widgets.dart';
import 'data/practice_models.dart';
import 'practice_controller.dart';
import 'start_practice.dart';

/// "5 min 12 s", "42 s", "1 h 5 min".
String formatDuration(int ms) {
  final seconds = (ms / 1000).round();
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) {
    final rest = seconds % 60;
    return rest == 0 ? '$minutes min' : '$minutes min $rest s';
  }
  final rest = minutes % 60;
  return rest == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h $rest min';
}

/// The result of a finished session: score, time, XP, a short per-topic
/// list (plain rows, no charts) and the coach tip for this session.
class PracticeSummaryView extends ConsumerStatefulWidget {
  const PracticeSummaryView({super.key, required this.state, required this.onDone});

  final PracticeState state;
  final VoidCallback onDone;

  @override
  ConsumerState<PracticeSummaryView> createState() => _PracticeSummaryViewState();
}

class _PracticeSummaryViewState extends ConsumerState<PracticeSummaryView> {
  bool _starting = false;

  /// Same settings, new idempotency key: a new set of questions.
  Future<void> _practiseAgain(SessionSettings settings) async {
    setState(() => _starting = true);
    try {
      final session = await ref
          .read(practiceStarterProvider)
          .start(settings, idempotencyKey: randomHexId());
      if (mounted) context.pushReplacement(Routes.practiceSession(session.sessionId));
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, practiceStartError(failure), icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final summary = state.summary!;
    final settings = state.settings;
    final text = context.text;
    final colors = context.colors;
    final xp = summary.xp;
    final capped = xp?.capped ?? false;
    final score = summary.score;
    final maxScore = summary.maxScore;
    final refused = refusalNotice(state.refusals);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.md,
        AppSpacing.gutter,
        AppSpacing.xxl,
      ),
      children: [
        Row(
          children: [
            AppIconButton(icon: AppIcons.close, semanticLabel: 'Close', onPressed: widget.onDone),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Practice complete', style: text.headlineLarge),
        if (state.session.title.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(state.session.title, style: text.bodyMedium),
        ],
        const SizedBox(height: AppSpacing.xl),
        HeroStatCard(
          label: 'Correct',
          tone: PastelTone.mint,
          trailing: state.syncing
              ? InfoChip(
                  icon: AppIcons.refresh,
                  label: 'Syncing…',
                  background: colors.surface.withValues(alpha: 0.7),
                )
              : null,
          value: Semantics(
            label: '${summary.correct} of ${summary.answered} correct',
            excludeSemantics: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                NumberTicker(value: summary.correct),
                Text(' / ${summary.answered}', style: text.numericLarge),
              ],
            ),
          ),
          caption: summary.skipped == 0
              ? 'correct answers'
              : 'correct answers · ${summary.skipped} skipped',
          stats: [
            HeroStat(
              label: 'Time taken',
              value: formatDuration(summary.timeMs),
              icon: AppIcons.clock,
            ),
            // A capped day explains itself below instead of a small number.
            if (!capped)
              HeroStat(
                label: 'XP gained',
                value: xp == null ? '—' : '+${xp.delta}',
                icon: AppIcons.flash,
              ),
            if (score != null && maxScore != null)
              HeroStat(label: 'Score', value: '$score/$maxScore'),
          ],
        ),
        if (capped) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(
            icon: AppIcons.flash,
            text: 'Daily practice XP limit reached · resets at midnight',
            background: colors.lemon.container,
            foreground: colors.lemon.onContainer,
          ),
        ],
        if (refused != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(
            icon: AppIcons.alert,
            text: refused,
            background: colors.errorContainer,
            foreground: colors.onErrorContainer,
          ),
        ],
        if (summary.topics.isNotEmpty) ...[
          const SectionHeader(
            title: 'By topic',
            padding: EdgeInsets.fromLTRB(0, AppSpacing.xxl, 0, AppSpacing.md),
          ),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              children: [
                for (final (i, topic) in summary.topics.indexed) ...[
                  if (i > 0) const Divider(),
                  MergeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        children: [
                          Expanded(child: Text(topic.name, style: text.bodyLarge)),
                          const SizedBox(width: AppSpacing.md),
                          Text(
                            '${topic.correct}/${topic.answered}',
                            style: text.numericMedium,
                            semanticsLabel: '${topic.correct} of ${topic.answered} correct',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (summary.tip case final tip?) ...[
          const SectionHeader(
            title: 'Next step',
            padding: EdgeInsets.fromLTRB(0, AppSpacing.xxl, 0, AppSpacing.md),
          ),
          CoachTipCard(tip: tip, replaceRoute: true),
        ],
        const SizedBox(height: AppSpacing.xxl),
        if (settings != null) ...[
          AppButton(
            label: 'Practise again',
            leadingIcon: AppIcons.refresh,
            loading: _starting,
            onPressed: () => _practiseAgain(settings),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        AppButton(
          label: 'Done',
          variant: settings == null ? AppButtonVariant.primary : AppButtonVariant.secondary,
          onPressed: widget.onDone,
        ),
      ],
    );
  }
}

/// One line under the result card (an XP cap, answers that weren't saved).
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final HugeIconData icon;
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Row(
        children: [
          HugeIcon(icon, size: 18, color: foreground),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(text, style: context.text.labelMedium.copyWith(color: foreground)),
          ),
        ],
      ),
    );
  }
}
