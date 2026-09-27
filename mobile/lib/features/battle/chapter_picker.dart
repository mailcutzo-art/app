import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../learn/data/learn_models.dart' show ChapterLabel;
import '../learn/widgets/learn_widgets.dart' show plural;
import 'data/battle_models.dart';

/// The pick from [showChapterPicker]: a chapter slug, or `null` for all chapters.
@immutable
class ChapterChoice {
  const ChapterChoice(this.chapter);

  final String? chapter;
}

/// "All chapters" or one battle-ready chapter of [subject]. Chapters that aren't ready show
/// "Coming soon" and can't be picked. Closes with the choice, or null when dismissed.
Future<ChapterChoice?> showChapterPicker(
  BuildContext context, {
  required BattleSubject subject,
  required String? selected,
}) => showAppSheet<ChapterChoice>(
  context,
  builder: (_) => ChapterPicker(subject: subject, selected: selected),
);

/// "48 questions · Needs work", or "Coming soon".
String chapterSubtitle(BattleChapter chapter) {
  if (!chapter.battleReady) return 'Coming soon';
  final count = plural(chapter.questionCount, 'question');
  return switch (chapter.label) {
    ChapterLabel.strong => '$count · Strong',
    ChapterLabel.needsWork => '$count · Needs work',
    null => count,
  };
}

class ChapterPicker extends StatelessWidget {
  const ChapterPicker({super.key, required this.subject, required this.selected});

  final BattleSubject subject;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final total = subject.chapters
        .where((c) => c.battleReady)
        .fold(0, (sum, c) => sum + c.questionCount);
    return SheetScaffold(
      title: 'Choose a chapter',
      subtitle: '${subject.name} · questions come from here',
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        children: [
          SelectableRow(
            title: 'All chapters',
            subtitle: 'Mixed questions · fastest match',
            icon: AppIcons.allChapters,
            iconBackground: colors.lemon.container,
            iconColor: colors.lemon.onContainer,
            trailingText: total > 0 ? '$total Qs' : null,
            selected: selected == null,
            onTap: () => Navigator.pop(context, const ChapterChoice(null)),
          ),
          for (final chapter in subject.chapters)
            SelectableRow(
              title: chapter.name,
              subtitle: chapterSubtitle(chapter),
              selected: selected == chapter.slug && chapter.battleReady,
              enabled: chapter.battleReady,
              onTap: () => Navigator.pop(context, ChapterChoice(chapter.slug)),
            ),
        ],
      ),
    );
  }
}
