import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';
import 'tab_scaffold.dart';

class HomeMockScreen extends StatelessWidget {
  const HomeMockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return TabScaffold(
      selectedTab: 0,
      children: [
        GreetingHeader(
          avatar: const AppAvatar(data: Mock.me, ring: true),
          greeting: 'Hi, Aarav!',
          subtitle: 'NEET 2027 · Level 7',
          onAvatarTap: () {},
          actions: [
            AppIconButton(
              icon: AppIcons.award,
              semanticLabel: 'Leaderboard',
              motion: IconMotions.trophy,
              onPressed: () {},
            ),
            AppIconButton(
              icon: AppIcons.notification,
              semanticLabel: 'Notifications',
              badgeCount: 3,
              motion: IconMotions.bell,
              onPressed: () {},
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        Gutter(
          child: HeroStatCard(
            label: 'Rating',
            value: const NumberTicker(value: 1523),
            caption: '+18 this week',
            trailing: const OverlineBadge(label: 'Top 12%', tone: PastelTone.lime, solid: true),
            stats: const [
              HeroStat(label: 'Global rank', value: '#1,204'),
              HeroStat(label: 'Coins', value: '250', icon: AppIcons.coins),
              HeroStat(label: 'Streak', value: '6 days', icon: AppIcons.fire),
            ],
            actions: [
              HeroAction(label: 'Play', icon: AppIcons.battle, onTap: () {}),
              HeroAction(label: 'Practice', icon: AppIcons.learn, onTap: () {}),
              HeroAction(label: 'Arena', icon: AppIcons.arena, onTap: () {}),
            ],
          ),
        ),
        const SectionHeader(title: 'Next tournament', actionLabel: 'See all'),
        Gutter(
          child: TournamentCard(
            title: 'All-India Arena Finals',
            description: 'Six Swiss rounds across Physics, Chemistry and Biology.',
            statusLabel: 'Starts in 2h 10m',
            subjectLabel: 'All subjects',
            rounds: 6,
            entryFee: 50,
            prizePool: 2500,
            joined: 142,
            capacity: 256,
            ctaLabel: 'Join',
            onCta: () {},
          ),
        ),
        const SectionHeader(title: 'Play'),
        Gutter(
          child: Row(
            children: [
              Expanded(
                child: PastelTile(
                  tone: PastelTone.sky,
                  icon: AppIcons.battle,
                  title: 'Play 1v1',
                  subtitle: 'Find an opponent',
                  onTap: () {},
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: PastelTile(
                  tone: PastelTone.peach,
                  icon: AppIcons.social,
                  title: 'Group battle',
                  subtitle: 'Up to 8 friends',
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
        const SectionHeader(title: 'Continue practice'),
        Gutter(
          child: SurfaceCard(
            onTap: () {},
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                Row(
                  children: [
                    const _SubjectBadge(tone: PastelTone.sky, icon: AppIcons.physics),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Kinematics', style: text.titleMedium),
                          Text('Physics · 12 of 20 answered', style: text.bodySmall),
                        ],
                      ),
                    ),
                    AppButton(
                      label: 'Resume',
                      onPressed: () {},
                      variant: AppButtonVariant.ink,
                      size: AppButtonSize.small,
                      expand: false,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                const AppProgressBar(value: 0.6, color: Color(0xFF28648F)),
              ],
            ),
          ),
        ),
        const SectionHeader(
          title: 'Today\'s missions',
          subtitle: '1 of 3 done · resets at midnight',
        ),
        Gutter(
          child: SurfaceCard(
            child: Column(
              children: [
                const SegmentedProgress(total: 3, completed: 1),
                const SizedBox(height: AppSpacing.lg),
                const _MissionRow(
                  icon: AppIcons.learn,
                  tone: PastelTone.mint,
                  title: 'Practice 20 questions',
                  progress: '20 / 20',
                  xp: 20,
                  done: true,
                ),
                const _MissionRow(
                  icon: AppIcons.flash,
                  tone: PastelTone.sky,
                  title: 'Win 1 rated battle',
                  progress: '0 / 1',
                  xp: 25,
                ),
                const _MissionRow(
                  icon: AppIcons.target,
                  tone: PastelTone.peach,
                  title: 'Review 5 weak questions',
                  progress: '2 / 5',
                  xp: 30,
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: colors.lemon.container,
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                  ),
                  child: Row(
                    children: [
                      HugeIcon(AppIcons.party, size: 22, color: colors.lemon.onContainer),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Finish all 3: +100 XP and 25 coins',
                          style: text.labelMedium.copyWith(color: colors.lemon.onContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SectionHeader(title: 'Your coach'),
        Gutter(
          child: SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _SubjectBadge(tone: PastelTone.lavender, icon: AppIcons.idea),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(child: Text('Your week in review', style: text.titleMedium)),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                const _InsightRow(
                  label: 'Strong',
                  value: 'Chemical Bonding · 86%',
                  tone: PastelTone.mint,
                ),
                const SizedBox(height: AppSpacing.sm),
                const _InsightRow(
                  label: 'Needs work',
                  value: 'Laws of Motion · 48%',
                  tone: PastelTone.rose,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: 'Practice weak spots',
                  onPressed: () {},
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.medium,
                  trailingIcon: AppIcons.chevronRight,
                ),
              ],
            ),
          ),
        ),
        const SectionHeader(title: 'This month', subtitle: 'Questions answered per day'),
        Gutter(
          child: SurfaceCard(
            child: DotMatrixChart(
              values: Mock.weeklyActivity,
              initialIndex: 13,
              tooltipBuilder: (i, v) => '${v.round()} questions',
              semanticLabel: 'Questions answered per day',
            ),
          ),
        ),
      ],
    );
  }
}

class _SubjectBadge extends StatelessWidget {
  const _SubjectBadge({required this.tone, required this.icon});

  final PastelTone tone;
  final HugeIconData icon;

  @override
  Widget build(BuildContext context) {
    final pair = context.colors.pastel(tone);
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
      child: HugeIcon(icon, size: 22, color: pair.onContainer),
    );
  }
}

class _MissionRow extends StatelessWidget {
  const _MissionRow({
    required this.icon,
    required this.tone,
    required this.title,
    required this.progress,
    required this.xp,
    this.done = false,
  });

  final HugeIconData icon;
  final PastelTone tone;
  final String title;
  final String progress;
  final int xp;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _SubjectBadge(tone: tone, icon: done ? AppIcons.check : icon),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleMedium.copyWith(
                    fontSize: 15,
                    decoration: done ? TextDecoration.lineThrough : null,
                    color: done ? colors.inkMuted : colors.ink,
                  ),
                ),
                Text(progress, style: text.caption),
              ],
            ),
          ),
          OverlineBadge(label: '+$xp XP', tone: done ? PastelTone.mint : PastelTone.lemon),
        ],
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.label, required this.value, required this.tone});

  final String label;
  final String value;
  final PastelTone tone;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 104,
          child: OverlineBadge(label: label, tone: tone),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(value, style: context.text.bodyLarge.copyWith(fontSize: 15))),
      ],
    );
  }
}
