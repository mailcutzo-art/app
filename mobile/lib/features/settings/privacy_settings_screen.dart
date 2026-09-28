import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import 'data/settings_models.dart';
import 'settings_providers.dart';
import 'widgets/settings_widgets.dart';

/// Privacy (`/settings/privacy`): who can send friend requests, who can challenge me, who sees
/// me online, and whether I appear on public boards. Minors start with the safest options.
class PrivacySettingsScreen extends ConsumerWidget {
  const PrivacySettingsScreen({super.key});

  Future<void> _save(BuildContext context, WidgetRef ref, PrivacySettings next) async {
    try {
      await ref.read(privacySettingsProvider.notifier).save(next);
    } on AppFailure catch (failure) {
      if (context.mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final privacy = ref.watch(privacySettingsProvider);
    final minor = ref.watch(meProvider.select((me) => me.isMinor));
    final value = privacy.value;
    if (value == null) {
      return SettingsPage(
        title: 'Privacy',
        children: [
          SettingsLoadState(
            error: privacy.error,
            retrying: privacy.isLoading,
            rows: 6,
            title: 'Couldn\'t load your privacy settings',
            onRetry: () => ref.invalidate(privacySettingsProvider),
          ),
        ],
      );
    }
    void save(PrivacySettings next) => unawaited(_save(context, ref, next));
    return SettingsPage(
      title: 'Privacy',
      children: [
        const SettingsHeader('Who can send me friend requests'),
        for (final option in FriendRequestsFrom.values)
          SelectableRow(
            title: option.label,
            subtitle: minor && option == FriendRequestsFrom.everyone
                ? 'Not available under 18'
                : null,
            enabled: !(minor && option == FriendRequestsFrom.everyone),
            selected: value.friendRequests == option,
            onTap: () => save(value.copyWith(friendRequests: option)),
          ),
        if (minor)
          const SettingsNote(
            'Under 18s only get friend requests from people they\'ve played, to keep strangers '
            'out.',
          ),
        const SettingsHeader('Who can challenge me'),
        for (final option in ChallengesFrom.values)
          SelectableRow(
            title: option.label,
            selected: value.challenges == option,
            onTap: () => save(value.copyWith(challenges: option)),
          ),
        const SettingsHeader('Who sees when I\'m online'),
        for (final option in PresenceTo.values)
          SelectableRow(
            title: option.label,
            selected: value.presence == option,
            onTap: () => save(value.copyWith(presence: option)),
          ),
        const SettingsHeader('Leaderboards'),
        ToggleRow(
          title: 'Show me on public boards',
          subtitle: 'Off: you still see your own rank; others don\'t see you',
          icon: AppIcons.arena,
          value: value.publicBoards,
          onChanged: (on) => save(value.copyWith(publicBoards: on)),
        ),
      ],
    );
  }
}
