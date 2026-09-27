import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/auth/session.dart';

/// Placeholder body for tabs whose features land in later phases. The avatar
/// still opens Profile, so no tab is a dead end.
class ComingSoonTab extends ConsumerWidget {
  const ComingSoonTab({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tone,
    required this.message,
  });

  final String title;
  final String subtitle;
  final HugeIconData icon;
  final PastelTone tone;
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    return TabPage(
      children: [
        LargeTitle(
          title: title,
          subtitle: subtitle,
          trailing: Pressable(
            onPressed: () => context.push(Routes.profile),
            semanticLabel: 'Your profile',
            child: AppAvatar(data: me.avatar.toData(), ring: true),
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Gutter(
          child: SurfaceCard(
            child: EmptyState(icon: icon, tone: tone, title: 'Coming soon', message: message),
          ),
        ),
      ],
    );
  }
}
