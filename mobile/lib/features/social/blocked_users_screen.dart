import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import 'data/social_models.dart';
import 'social_providers.dart';
import 'widgets/social_widgets.dart';

/// The players the user has blocked, with Unblock (`Routes.blockedUsers`,
/// opened from Settings → Privacy).
class BlockedUsersScreen extends ConsumerWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blockedUsersProvider);
    return Scaffold(
      appBar: AppTopBar(
        title: 'Blocked players',
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.settingsPrivacy),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(blockedUsersProvider);
          try {
            await ref.read(blockedUsersProvider.future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.huge,
          ),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Text(
              'Blocked players can\'t find you, send you requests or invites, or be matched '
              'with you. They aren\'t told.',
              style: context.text.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.lg),
            switch (blocked) {
              AsyncValue(:final value?) when value.isEmpty => EmptyState(
                icon: AppIcons.shield,
                tone: PastelTone.mint,
                title: 'Nobody is blocked',
                message: 'You can block a player from their profile or your friends list.',
                actionLabel: 'Go to Social',
                onAction: () => context.go(Routes.social),
              ),
              AsyncValue(:final value?) => RowList(
                children: [for (final user in value) _BlockedRow(user: user)],
              ),
              AsyncValue(:final error?) => ErrorState(
                compact: true,
                title: 'Couldn\'t load blocked players',
                message: failureMessage(error),
                retrying: blocked.isLoading,
                onRetry: () => ref.invalidate(blockedUsersProvider),
              ),
              _ => const PlayerRowsSkeleton(),
            },
          ],
        ),
      ),
    );
  }
}

class _BlockedRow extends ConsumerWidget {
  const _BlockedRow({required this.user});

  final UserCard user;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PlayerRow(
    user: user,
    // Their profile isn't available while they're blocked.
    openProfile: false,
    trailing: AppButton(
      label: 'Unblock',
      variant: AppButtonVariant.secondary,
      size: AppButtonSize.small,
      expand: false,
      onPressed: () => runSocialAction(
        context,
        () => ref.read(socialActionsProvider).unblock(user),
        done: '${user.displayName} is unblocked',
      ),
    ),
  );
}

/// A row for Settings → Privacy that opens the blocked players list and
/// says how many there are once known.
class BlockedUsersEntry extends ConsumerWidget {
  const BlockedUsersEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final count = ref.watch(blockedUsersProvider).value?.length;
    return ListRowCard(
      title: 'Blocked players',
      subtitle: switch (count) {
        null => 'People you\'ve blocked',
        0 => 'Nobody is blocked',
        1 => '1 player',
        _ => '$count players',
      },
      leading: HugeIcon(AppIcons.lock, size: 22, color: colors.ink),
      trailing: HugeIcon(AppIcons.chevronRight, size: 20, color: colors.inkMuted),
      onTap: () => context.push(Routes.blockedUsers),
    );
  }
}
