import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';
import 'tab_scaffold.dart';

class LearnMockScreen extends StatefulWidget {
  const LearnMockScreen({super.key});

  @override
  State<LearnMockScreen> createState() => _LearnMockScreenState();
}

class _LearnMockScreenState extends State<LearnMockScreen> {
  String _goal = 'NEET';

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final colors = context.colors;
    final subjects = Mock.subjects.where(
      (s) => _goal == 'JEE' ? s.name != 'Biology' : s.name != 'Maths',
    );
    return TabScaffold(
      selectedTab: 1,
      children: [
        const LargeTitle(title: 'What do you want\nto practice today?'),
        const SizedBox(height: AppSpacing.lg),
        Gutter(
          child: AppSegmentedControl<String>(
            segments: const [
              AppSegment(value: 'NEET', label: 'NEET', icon: AppIcons.biology),
              AppSegment(value: 'JEE', label: 'JEE', icon: AppIcons.maths),
            ],
            selected: _goal,
            onChanged: (goal) => setState(() => _goal = goal),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const Gutter(child: AppSearchField(hint: 'Search questions or chapters')),
        const SectionHeader(title: 'Subjects'),
        Gutter(
          child: GridView.count(
            padding: EdgeInsets.zero,
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 1.1,
            children: [
              for (final s in subjects)
                PastelTile(
                  tone: s.tone,
                  icon: s.icon,
                  title: s.name,
                  subtitle: '${s.questions} questions · ${s.chapters} chapters',
                  onTap: () {},
                ),
              PastelTile(
                tone: PastelTone.lemon,
                icon: AppIcons.allChapters,
                title: 'Mixed',
                subtitle: 'All subjects',
                onTap: () {},
              ),
            ],
          ),
        ),
        const SectionHeader(title: 'Practice tools'),
        const Gutter(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _ToolTile(
                      icon: AppIcons.timer,
                      tone: PastelTone.peach,
                      title: 'Self challenge',
                      subtitle: 'Timed test',
                    ),
                  ),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _ToolTile(
                      icon: AppIcons.bookmark,
                      tone: PastelTone.sky,
                      title: 'Bookmarks',
                      subtitle: '24 saved',
                    ),
                  ),
                ],
              ),
              SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: _ToolTile(
                      icon: AppIcons.learn,
                      tone: PastelTone.mint,
                      title: 'Fun & learn',
                      subtitle: 'Read and answer',
                    ),
                  ),
                  SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _ToolTile(
                      icon: AppIcons.brain,
                      tone: PastelTone.lavender,
                      title: 'Guess the word',
                      subtitle: 'Science terms',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SectionHeader(title: 'Physics chapters', actionLabel: 'All'),
        for (final chapter in Mock.physicsChapters)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              AppSpacing.sm,
            ),
            child: SurfaceCard(
              onTap: () {},
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(chapter.name, style: text.titleMedium)),
                      Text('${chapter.questions} Qs', style: text.caption),
                      const SizedBox(width: AppSpacing.sm),
                      HugeIcon(AppIcons.chevronRight, size: 18, color: colors.inkMuted),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (chapter.accuracy == null)
                    Text('Not started', style: text.bodySmall)
                  else
                    Row(
                      children: [
                        Expanded(
                          child: AppProgressBar(
                            value: chapter.accuracy!,
                            height: 6,
                            color: chapter.accuracy! >= 0.6 ? colors.success : colors.warning,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Text(
                          '${(chapter.accuracy! * 100).round()}%',
                          style: text.numericMedium.copyWith(fontSize: 14),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
  });

  final HugeIconData icon;
  final PastelTone tone;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final pair = context.colors.pastel(tone);
    return SurfaceCard(
      onTap: () {},
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
            child: HugeIcon(icon, size: 22, color: pair.onContainer),
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
