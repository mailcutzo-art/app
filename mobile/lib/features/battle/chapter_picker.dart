import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../learn/data/learn_models.dart' show ChapterLabel;
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

/// "Strong", "Needs work", or "Coming soon" (no bank sizes: they aren't shown to players).
String? chapterSubtitle(BattleChapter chapter) {
  if (!chapter.battleReady) return 'Coming soon';
  return switch (chapter.label) {
    ChapterLabel.strong => 'Strong',
    ChapterLabel.needsWork => 'Needs work',
    null => null,
  };
}

class ChapterPicker extends StatelessWidget {
  const ChapterPicker({super.key, required this.subject, required this.selected});

  final BattleSubject subject;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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
