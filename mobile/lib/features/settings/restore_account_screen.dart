import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/time_text.dart';
import 'data/settings_repository.dart';

/// Shown instead of everything else while the account awaits deletion (`/restore`): restore
/// it, or sign out. The session can do nothing else.
class RestoreAccountScreen extends ConsumerStatefulWidget {
  const RestoreAccountScreen({super.key});

  @override
  ConsumerState<RestoreAccountScreen> createState() => _RestoreAccountScreenState();
}

class _RestoreAccountScreenState extends ConsumerState<RestoreAccountScreen> {
  bool _restoring = false;
  bool _signingOut = false;

  Future<void> _restore() async {
    setState(() => _restoring = true);
    try {
      final me = await ref.read(accountRepositoryProvider).restore();
      final session = ref.read(sessionProvider.notifier);
      if (me != null && !me.isPendingDeletion) {
        await session.updateUser(me);
      } else {
        await session.refreshUser();
      }
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    await ref.read(sessionProvider.notifier).signOut();
  }

  static String untilText(DateTime? until) => until == null
      ? 'You can restore it for 7 days after deleting it.'
      : 'You can restore it until ${fullDate(until)}, ${clockTime(until)}.';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).value;
    final pending = session is PendingDeletion ? session : null;
    final name = pending?.user.displayName.split(' ').first;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            children: [
              const SizedBox(height: AppSpacing.xxxl),
              EmptyState(
                icon: AppIcons.refresh,
                tone: PastelTone.peach,
                title: name == null ? 'Your account is being deleted' : 'Welcome back, $name',
                message:
                    'You asked to delete this account. ${untilText(pending?.restoreUntil)} '
                    'Restoring brings back your profile, friends, ranks and history exactly.',
              ),
              AppButton(
                label: 'Restore my account',
                leadingIcon: AppIcons.refresh,
                loading: _restoring,
                onPressed: _restoring || _signingOut ? null : _restore,
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: 'Sign out',
                variant: AppButtonVariant.ghost,
                loading: _signingOut,
                onPressed: _restoring || _signingOut ? null : _signOut,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
