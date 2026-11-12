import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/env.dart';
import '../../app/router.dart';
import '../../app/shell.dart' show Gutter;
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import '../practice/data/answer_queue.dart';
import 'data/settings_models.dart';
import 'settings_providers.dart';
import 'widgets/settings_widgets.dart';

/// This app's name and version, for About.
final packageInfoProvider = FutureProvider<PackageInfo>((ref) => PackageInfo.fromPlatform());

/// Settings (`/settings`): the account pages, appearance, sound and haptics, analytics,
/// devices, help, licences and about, sign out and delete account.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _signingOut = false;

  void _open(String location) => unawaited(context.push(location));

  Future<void> _openLegal(String page) async {
    final base = ref.read(appEnvProvider).legalBaseUrl;
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse('$base/$page'), mode: LaunchMode.externalApplication);
    } on Object {
      opened = false;
    }
    if (!opened && mounted) {
      showAppToast(context, 'Couldn\'t open that page.', icon: AppIcons.alert);
    }
  }

  Future<void> _setAnalytics({required bool on}) async {
    try {
      await ref.read(appSettingsProvider.notifier).save(AppSettings(analytics: on));
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    }
  }

  Future<void> _about() async {
    PackageInfo? info;
    try {
      info = await ref.read(packageInfoProvider.future);
    } on Object {
      info = null; // Shown without a version.
    }
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'Quiz Arena',
      applicationVersion: info == null ? null : '${info.version} (${info.buildNumber})',
      applicationLegalese: 'Live quiz battles for NEET and JEE aspirants.',
    );
  }

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
    final env = ref.watch(appEnvProvider);
    final theme = ref.watch(themeModeProvider);
    final touch = ref.watch(touchPrefsProvider);
    final analytics = ref.watch(appSettingsProvider);
    final version = ref.watch(packageInfoProvider).value;

    return SettingsPage(
      title: 'Settings',
      onBack: () => context.canPop() ? context.pop() : context.go(Routes.profile),
      children: [
        const SettingsHeader('Account'),
        SettingsLink(
          title: 'Edit profile',
          subtitle: [me.displayName, if (me.handle != null) '@${me.handle}'].join(' · '),
          icon: AppIcons.edit,
          tone: PastelTone.lime,
          onTap: () => _open(Routes.settingsProfile),
        ),
        SettingsLink(
          title: 'Privacy',
          subtitle: 'Friend requests, challenges, online status',
          icon: AppIcons.shield,
          tone: PastelTone.mint,
          onTap: () => _open(Routes.settingsPrivacy),
        ),
        SettingsLink(
          title: 'Notifications',
          subtitle: 'What to be told about, and quiet hours',
          icon: AppIcons.notification,
          tone: PastelTone.sky,
          onTap: () => _open(Routes.settingsNotifications),
        ),
        SettingsLink(
          title: 'Devices',
          subtitle: 'Where you\'re signed in',
          icon: AppIcons.device,
          tone: PastelTone.lavender,
          onTap: () => _open(Routes.settingsDevices),
        ),
        const SettingsHeader('Appearance'),
        Gutter(
          child: AppSegmentedControl<ThemeMode>(
            segments: const [
              AppSegment(value: ThemeMode.system, label: 'System', icon: AppIcons.device),
              AppSegment(value: ThemeMode.light, label: 'Light', icon: AppIcons.sun),
              AppSegment(value: ThemeMode.dark, label: 'Dark', icon: AppIcons.moon),
            ],
            selected: theme,
            onChanged: (mode) => unawaited(ref.read(themeModeProvider.notifier).set(mode)),
          ),
        ),
        const SettingsHeader('Sound and haptics'),
        ToggleRow(
          title: 'Sounds',
          subtitle: 'A click on every tap',
          icon: AppIcons.sound,
          value: touch.sounds,
          onChanged: (on) => unawaited(ref.read(touchPrefsProvider.notifier).setSounds(on: on)),
        ),
        ToggleRow(
          title: 'Haptics',
          subtitle: 'A light buzz on taps and answers',
          icon: AppIcons.vibrate,
          value: touch.haptics,
          onChanged: (on) => unawaited(ref.read(touchPrefsProvider.notifier).setHaptics(on: on)),
        ),
        const SettingsHeader('Data'),
        switch (analytics) {
          AsyncValue(:final value?) => ToggleRow(
            title: 'Usage analytics',
            subtitle: me.isMinor
                ? 'Counts of screens opened, never linked to you'
                : 'Which screens you open, to help us improve the app',
            icon: AppIcons.analytics,
            value: value.analytics,
            onChanged: (on) => unawaited(_setAnalytics(on: on)),
          ),
          AsyncValue(:final error) => SettingsLoadState(
            error: error,
            retrying: analytics.isLoading,
            rows: 1,
            title: 'Couldn\'t load the analytics setting',
            onRetry: () => ref.invalidate(appSettingsProvider),
          ),
        },
        const SettingsHeader('Help'),
        SettingsLink(
          title: 'Send feedback',
          subtitle: 'Report a problem or suggest an idea',
          icon: AppIcons.feedback,
          tone: PastelTone.peach,
          onTap: () => _open(Routes.settingsFeedback),
        ),
        if (env.legalBaseUrl.isNotEmpty) ...[
          SettingsLink(
            title: 'Terms',
            icon: AppIcons.document,
            onTap: () => unawaited(_openLegal('terms')),
          ),
          SettingsLink(
            title: 'Privacy policy',
            icon: AppIcons.lock,
            onTap: () => unawaited(_openLegal('privacy')),
          ),
        ],
        const SettingsHeader('About'),
        SettingsLink(
          title: 'About Quiz Arena',
          subtitle: version == null ? null : 'Version ${version.version} (${version.buildNumber})',
          icon: AppIcons.info,
          onTap: () => unawaited(_about()),
        ),
        SettingsLink(
          title: 'Open-source licences',
          icon: AppIcons.document,
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Quiz Arena',
            applicationVersion: version?.version,
          ),
        ),
        if (env.isDev)
          SettingsLink(
            title: 'Debug settings',
            subtitle: 'Server address, demo data and build info',
            icon: AppIcons.settings,
            onTap: () => _open(Routes.debug),
          ),
        const SizedBox(height: AppSpacing.xxl),
        Gutter(
          child: AppButton(
            label: 'Sign out',
            leadingIcon: AppIcons.logout,
            variant: AppButtonVariant.secondary,
            loading: _signingOut,
            onPressed: _signOut,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Gutter(
          child: AppButton(
            label: 'Delete account',
            leadingIcon: AppIcons.delete,
            variant: AppButtonVariant.ghost,
            onPressed: () => _open(Routes.settingsDelete),
          ),
        ),
      ],
    );
  }
}
