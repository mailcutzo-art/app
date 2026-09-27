import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';
import 'matchmaking_screen.dart';
import 'tab_scaffold.dart';

class BattleMockScreen extends StatefulWidget {
  const BattleMockScreen({super.key});

  @override
  State<BattleMockScreen> createState() => _BattleMockScreenState();
}

class _BattleMockScreenState extends State<BattleMockScreen> {
  bool _rated = true;
  int _subject = 0;
  String _chapter = 'Kinematics';

  Future<void> _pickChapter() async {
    final picked = await showAppSheet<String>(
      context,
      builder: (context) => _ChapterPicker(selected: _chapter),
    );
    if (picked != null) setState(() => _chapter = picked);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final subjects = Mock.subjects.take(3).toList();
    return TabScaffold(
      selectedTab: 2,
      children: [
        LargeTitle(
          title: 'Battle',
          subtitle: 'Pick a chapter, find an opponent, play live.',
          trailing: AppIconButton(
            icon: AppIcons.award,
            semanticLabel: 'Leaderboard',
            motion: IconMotions.trophy,
            onPressed: () {},
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Gutter(
          child: SurfaceCard(
            elevated: true,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.md),
                  child: Text('Quick battle', style: text.titleLarge),
                ),
                AppSegmentedControl<bool>(
                  segments: const [
                    AppSegment(value: true, label: 'Rated', icon: AppIcons.flash),
                    AppSegment(value: false, label: 'Casual', icon: AppIcons.smile),
                  ],
                  selected: _rated,
                  onChanged: (v) => setState(() => _rated = v),
                ),
                const SizedBox(height: AppSpacing.lg),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.sm),
                  child: Text('Subject', style: text.labelMedium.copyWith(color: colors.inkMuted)),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < subjects.length; i++) ...[
                        if (i > 0) const SizedBox(width: AppSpacing.sm),
                        AppChip(
                          label: subjects[i].name,
                          dotColor: colors.pastel(subjects[i].tone).onContainer,
                          selected: _subject == i,
                          onSelected: (_) => setState(() => _subject = i),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Pressable(
                  onPressed: _pickChapter,
                  semanticLabel: 'Chapter: $_chapter',
                  pressedScale: 0.98,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
                    decoration: BoxDecoration(
                      color: colors.surfaceMuted,
                      borderRadius: BorderRadius.circular(AppRadii.lg),
                    ),
                    child: Row(
                      children: [
                        HugeIcon(AppIcons.learn, size: 20, color: colors.inkMuted),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Chapter', style: text.caption),
                              Text(_chapter, style: text.titleMedium),
                            ],
                          ),
                        ),
                        HugeIcon(AppIcons.chevronDown, size: 20, color: colors.ink),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    InfoChip(
                      icon: _rated ? AppIcons.chart : AppIcons.shield,
                      label: _rated ? 'Rating changes' : 'No rating impact',
                      background: colors.surfaceMuted,
                    ),
                    InfoChip(
                      icon: AppIcons.coins,
                      iconColor: colors.coin,
                      label: _rated ? 'Free' : '5 coins to enter',
                      background: colors.surfaceMuted,
                    ),
                    InfoChip(
                      icon: AppIcons.timer,
                      label: '7 questions · 15 s',
                      background: colors.surfaceMuted,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                AppButton(
                  label: 'Find opponent',
                  trailingIcon: AppIcons.search,
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const MatchmakingMockScreen())),
                ),
              ],
            ),
          ),
        ),
        const SectionHeader(title: 'More ways to play'),
        Gutter(
          child: Row(
            children: [
              Expanded(
                child: PastelTile(
                  tone: PastelTone.lavender,
                  icon: AppIcons.userAdd,
                  title: 'Play a friend',
                  subtitle: 'Private 1v1',
                  onTap: () {},
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: PastelTile(
                  tone: PastelTone.peach,
                  icon: AppIcons.social,
                  title: 'Group battle',
                  subtitle: '2–8 players',
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
        const SectionHeader(
          title: 'Leaderboard',
          subtitle: 'Physics · this week',
          actionLabel: 'View all',
        ),
        const Gutter(
          child: Column(
            children: [
              LeaderboardRow(rank: 1, name: 'Riya', score: '1,912', avatar: Mock.riya),
              SizedBox(height: AppSpacing.sm),
              LeaderboardRow(rank: 2, name: 'Kabir', score: '1,874', avatar: Mock.kabir),
              SizedBox(height: AppSpacing.sm),
              LeaderboardRow(rank: 3, name: 'Zara', score: '1,801', avatar: Mock.zara),
              SizedBox(height: AppSpacing.sm),
              LeaderboardRow(
                rank: 1204,
                name: 'Aarav',
                score: '1,523',
                avatar: Mock.me,
                highlight: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChapterPicker extends StatefulWidget {
  const _ChapterPicker({required this.selected});

  final String selected;

  @override
  State<_ChapterPicker> createState() => _ChapterPickerState();
}

class _ChapterPickerState extends State<_ChapterPicker> {
  late String _selected = widget.selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SheetScaffold(
      title: 'Choose a chapter',
      subtitle: 'Physics · questions come from this chapter',
      footer: AppButton(label: 'Done', onPressed: () => Navigator.pop(context, _selected)),
      child: ListView(
        shrinkWrap: true,
        children: [
          SelectableRow(
            title: 'All chapters',
            subtitle: 'Mixed questions · fastest match',
            icon: AppIcons.allChapters,
            iconBackground: colors.lemon.container,
            iconColor: colors.lemon.onContainer,
            trailingText: '96 Qs',
            selected: _selected == 'All chapters',
            onTap: () => setState(() => _selected = 'All chapters'),
          ),
          for (final chapter in Mock.physicsChapters)
            SelectableRow(
              title: chapter.name,
              subtitle: chapter.accuracy == null
                  ? 'Not played yet'
                  : 'Your accuracy ${(chapter.accuracy! * 100).round()}%',
              trailingText: '${chapter.questions} Qs',
              selected: _selected == chapter.name,
              onTap: () => setState(() => _selected = chapter.name),
            ),
        ],
      ),
    );
  }
}
