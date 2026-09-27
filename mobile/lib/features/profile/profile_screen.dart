import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/env.dart';
import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../practice/data/answer_queue.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _signingOut = false;

  Future<void> _signOut() async {
    // Practice answers still on the phone would wait for this user's next
    // sign-in, so try to send them first.
    setState(() => _signingOut = true);
    final queue = ref.read(answerQueueProvider);
    await queue.flush().timeout(const Duration(seconds: 5), onTimeout: () {});
    if (!mounted) return;
    setState(() => _signingOut = false);
    final unsaved = queue.pendingCount;
    final confirmed = await showAppSheet<bool>(
      context,
      builder: (context) => SheetScaffold(
        title: 'Sign out?',
        subtitle: switch (unsaved) {
          0 => 'You can sign back in with the same Google account any time.',
          1 => '1 answer isn\'t saved yet. Sign out anyway?',
          _ => '$unsaved answers aren\'t saved yet. Sign out anyway?',
        },
        footer: Column(
          children: [
            AppButton(
              label: unsaved == 0 ? 'Sign out' : 'Sign out anyway',
              variant: AppButtonVariant.danger,
              onPressed: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Cancel',
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
        child: unsaved == 0
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                child: Text(
                  'They\'ll be sent the next time you sign in on this phone.',
                  style: context.text.bodySmall,
                ),
              ),
      ),
    );
    if (confirmed != true) return;
    setState(() => _signingOut = true);
    await ref.read(sessionProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).value;
    if (session is! SignedIn) return const Scaffold();
    final me = session.user;
    final text = context.text;
    final env = ref.watch(appEnvProvider);

    return Scaffold(
      appBar: const AppTopBar(title: 'Profile'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          Center(child: AppAvatar(data: me.avatar.toData(), size: 104, ring: true)),
          const SizedBox(height: AppSpacing.lg),
          Center(child: Text(me.displayName, style: text.headlineMedium)),
          if (me.handle != null) Center(child: Text('@${me.handle}', style: text.bodyMedium)),
          const SizedBox(height: AppSpacing.md),
          if (me.goal != null)
            Center(
              child: OverlineBadge(label: me.goal!.label, tone: PastelTone.mint),
            ),
          const SizedBox(height: AppSpacing.xxxl),
          if (env.isDev) ...[
            ListRowCard(
              title: 'Debug settings',
              subtitle: 'Server address and build info',
              leading: HugeIcon(AppIcons.settings, size: 22, color: context.colors.ink),
              trailing: HugeIcon(AppIcons.chevronRight, size: 20, color: context.colors.inkMuted),
              onTap: () => context.push(Routes.debug),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          AppButton(
            label: 'Sign out',
            leadingIcon: AppIcons.logout,
            variant: AppButtonVariant.secondary,
            loading: _signingOut,
            onPressed: _signOut,
          ),
        ],
      ),
    );
  }
}
