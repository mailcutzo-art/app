import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/auth/session.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final offline = switch (ref.watch(sessionProvider).value) {
      SignedIn(:final offline) => offline,
      _ => false,
    };
    final firstName = me.displayName.split(' ').first;

    return TabPage(
      onRefresh: () => ref.read(sessionProvider.notifier).refreshUser(),
      children: [
        OfflineBanner(visible: offline),
        GreetingHeader(
          avatar: AppAvatar(data: me.avatar.toData(), ring: true, semanticLabel: 'Your avatar'),
          greeting: 'Hi, $firstName!',
          subtitle: [
            if (me.goal != null) me.goal!.label,
            if (me.handle != null) '@${me.handle}',
          ].join(' · '),
          onAvatarTap: () => context.push(Routes.profile),
          actions: [
            AppIconButton(
              icon: AppIcons.notification,
              semanticLabel: 'Notifications',
              motion: IconMotions.bell,
              onPressed: () {},
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        Gutter(
          child: HeroStatCard(
            label: 'Rating',
            value: const Text('—'),
            caption: 'Play rated battles to earn your rating',
            stats: const [
              HeroStat(label: 'Global rank', value: '—'),
              HeroStat(label: 'Coins', value: '—', icon: AppIcons.coins),
              HeroStat(label: 'Streak', value: '0 days', icon: AppIcons.fire),
            ],
            actions: [
              HeroAction(
                label: 'Play',
                icon: AppIcons.battle,
                onTap: () => context.go(Routes.battle),
              ),
              HeroAction(
                label: 'Practice',
                icon: AppIcons.learn,
                onTap: () => context.go(Routes.learn),
              ),
              HeroAction(
                label: 'Arena',
                icon: AppIcons.arena,
                onTap: () => context.go(Routes.arena),
              ),
            ],
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
                  onTap: () => context.go(Routes.battle),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: PastelTile(
                  tone: PastelTone.lavender,
                  icon: AppIcons.learn,
                  title: 'Practice',
                  subtitle: 'By chapter',
                  onTap: () => context.go(Routes.learn),
                ),
              ),
            ],
          ),
        ),
        const SectionHeader(title: 'Today\'s missions'),
        const Gutter(
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.target,
              tone: PastelTone.lemon,
              title: 'Missions are on the way',
              message: 'Daily goals with XP and coin rewards will show up here.',
            ),
          ),
        ),
      ],
    );
  }
}
