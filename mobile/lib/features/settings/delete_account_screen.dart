import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/shell.dart' show Gutter;
import '../../core/auth/google_auth.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import 'data/settings_repository.dart';
import 'settings_providers.dart';
import 'widgets/settings_widgets.dart';

/// What the sign-in screen says after a delete.
const deletedMessage = 'Your account will be deleted in 7 days. Sign in before then to restore it.';

/// Delete account (`/settings/delete-account`): what happens, type DELETE, sign in again, then
/// `POST /v1/me/delete`. Every session ends and the app signs out.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  static const confirmWord = 'DELETE';

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _confirm = TextEditingController();
  bool _deleting = false;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  bool get _confirmed => _confirm.text.trim() == DeleteAccountScreen.confirmWord;

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      final proof = await ref.read(reauthenticateProvider)();
      await ref.read(accountRepositoryProvider).deleteAccount(proof);
      await ref.read(sessionProvider.notifier).endLocally(message: deletedMessage);
    } on SignInCancelled {
      // The user closed the account picker: nothing happens.
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return SettingsPage(
      title: 'Delete account',
      children: [
        const Gutter(
          child: EmptyState(
            icon: AppIcons.delete,
            tone: PastelTone.rose,
            title: 'Delete your account?',
            message: 'You can change your mind for 7 days.',
          ),
        ),
        const SettingsHeader('What happens'),
        for (final line in const [
          'You\'re signed out on every device, and live games are forfeited.',
          'Your profile, friends, ranks and history are hidden at once. Tournament entries '
              'are withdrawn and refunded.',
          'For 7 days, signing in again offers to restore everything exactly as it was.',
          'After 30 days the account is erased for good, including your coins. Game records '
              'stay only as anonymous numbers.',
        ])
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 4, AppSpacing.gutter, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7, right: AppSpacing.md),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: context.colors.ink, shape: BoxShape.circle),
                  ),
                ),
                Expanded(child: Text(line, style: text.bodyMedium)),
              ],
            ),
          ),
        const SettingsHeader('Confirm'),
        Gutter(
          child: AppTextField(
            label: 'Type ${DeleteAccountScreen.confirmWord} to confirm',
            controller: _confirm,
            hint: DeleteAccountScreen.confirmWord,
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SettingsNote('You\'ll sign in again to prove it\'s you.'),
        const SizedBox(height: AppSpacing.xl),
        Gutter(
          child: AppButton(
            label: 'Delete my account',
            variant: AppButtonVariant.danger,
            leadingIcon: AppIcons.delete,
            loading: _deleting,
            onPressed: _confirmed && !_deleting ? _delete : null,
          ),
        ),
      ],
    );
  }
}
