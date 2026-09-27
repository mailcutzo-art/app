import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';

/// Shown instead of everything else while the account is suspended: why, until
/// when, how to appeal, and a way out. Never a splash screen retrying forever.
class SuspendedScreen extends ConsumerWidget {
  const SuspendedScreen({super.key});

  static String reasonText(String? reason) => switch (reason) {
    'cheating' => 'Our fair-play checks found unusual activity in your games.',
    'abuse' => 'Other players reported abusive behaviour.',
    'offensive_name' => 'Your name or username broke our community rules.',
    _ => 'Your account broke our community rules.',
  };

  static String untilText(DateTime? until) {
    if (until == null) return 'This suspension doesn\'t have an end date.';
    final local = until.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return 'You can play again from ${local.day} ${months[local.month - 1]} ${local.year}.';
  }

  Future<void> _appeal(BuildContext context, String contact) async {
    final uri = contact.contains('@')
        ? Uri(scheme: 'mailto', path: contact, query: 'subject=Account%20appeal')
        : Uri.tryParse(contact);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } on Object {
        opened = false;
      }
    }
    if (!opened && context.mounted) {
      showAppToast(context, 'Write to $contact to appeal.', icon: AppIcons.mail);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final suspended = session is Suspended ? session : const Suspended();
    final appeal = suspended.appeal;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            children: [
              const SizedBox(height: AppSpacing.xxxl),
              EmptyState(
                icon: AppIcons.shield,
                tone: PastelTone.rose,
                title: 'Your account is suspended',
                message: '${reasonText(suspended.reason)} ${untilText(suspended.until)}',
              ),
              if (appeal != null) ...[
                AppButton(
                  label: 'Appeal',
                  variant: AppButtonVariant.secondary,
                  leadingIcon: AppIcons.mail,
                  onPressed: () => _appeal(context, appeal),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              AppButton(
                label: 'Sign out',
                variant: AppButtonVariant.ghost,
                onPressed: () => ref.read(sessionProvider.notifier).leaveSuspended(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
