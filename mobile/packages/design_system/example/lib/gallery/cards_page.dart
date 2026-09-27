import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';
import 'gallery_scaffold.dart';

class CardsPage extends StatelessWidget {
  const CardsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GalleryScaffold(
      title: 'Cards',
      children: [
        DemoBlock(
          title: 'Pastel tiles',
          child: GridView.count(
            padding: EdgeInsets.zero,
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 1.1,
            children: [
              PastelTile(
                tone: PastelTone.sky,
                icon: AppIcons.physics,
                title: 'Physics',
                subtitle: '96 questions',
                onTap: () {},
              ),
              PastelTile(
                tone: PastelTone.lavender,
                icon: AppIcons.chemistry,
                title: 'Chemistry',
                subtitle: '88 questions',
                onTap: () {},
              ),
              PastelTile(
                tone: PastelTone.mint,
                icon: AppIcons.biology,
                title: 'Biology',
                subtitle: '92 questions',
                onTap: () {},
              ),
              PastelTile(
                tone: PastelTone.peach,
                icon: AppIcons.maths,
                title: 'Maths',
                subtitle: '84 questions',
                badge: const OverlineBadge(label: 'New', solid: true),
                onTap: () {},
              ),
            ],
          ),
        ),
        DemoBlock(
          title: 'Hero stat card',
          child: HeroStatCard(
            label: 'Rating',
            value: const NumberTicker(value: 1523),
            caption: '+18 this week',
            stats: const [
              HeroStat(label: 'Rank', value: '#1,204'),
              HeroStat(label: 'Coins', value: '250', icon: AppIcons.coins),
              HeroStat(label: 'Streak', value: '6', icon: AppIcons.fire),
            ],
            actions: [
              HeroAction(label: 'Play', icon: AppIcons.battle, onTap: () {}),
              HeroAction(label: 'Practice', icon: AppIcons.learn, onTap: () {}),
              HeroAction(label: 'Arena', icon: AppIcons.arena, onTap: () {}),
            ],
          ),
        ),
        DemoBlock(
          title: 'List rows',
          child: Spaced(
            gap: AppSpacing.sm,
            children: [
              ListRowCard(
                leading: const AppAvatar(data: Mock.riya, presence: Presence.online),
                title: 'Riya Sharma',
                subtitle: 'Online · NEET',
                trailing: AppButton(
                  label: 'Challenge',
                  size: AppButtonSize.small,
                  expand: false,
                  variant: AppButtonVariant.ink,
                  onPressed: () {},
                ),
              ),
              const ListRowCard(
                leading: AppAvatar(data: Mock.kabir, presence: Presence.playing),
                title: 'Kabir Mehta',
                subtitle: 'In a battle',
                trailing: RatingDelta(delta: 24),
              ),
              ListRowCard(
                leading: const AppAvatar(data: Mock.dev),
                title: 'Dev Singh',
                subtitle: 'Rival · you lead 5–3',
                trailing: HugeIcon(AppIcons.chevronRight, size: 20, color: colors.inkMuted),
                onTap: () {},
              ),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Avatars',
          child: Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppAvatar(data: Mock.me, size: 64, ring: true),
              AppAvatar(data: Mock.riya, presence: Presence.online),
              AppAvatar(data: Mock.kabir, presence: Presence.playing),
              AppAvatar(data: Mock.dev),
              AvatarStack(avatars: [Mock.riya, Mock.kabir, Mock.zara, Mock.dev], extraCount: 138),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Section header',
          child: SectionHeader(
            title: 'Leaderboard',
            subtitle: 'Physics · this week',
            actionLabel: 'View all',
            padding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}
