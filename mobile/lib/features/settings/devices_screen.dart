import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/shell.dart' show Gutter;
import '../../core/network/app_failure.dart';
import '../../core/utils/time_text.dart';
import '../common/paged_list.dart' show RowIcon;
import 'data/settings_models.dart';
import 'data/settings_repository.dart';
import 'settings_providers.dart';
import 'widgets/settings_widgets.dart';

/// Devices (`/settings/devices`): where the account is signed in, with Sign out for one device
/// or all the others. They notice on their next request.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  /// The device being signed out, or `*` for all others.
  String? _busy;

  Future<bool> _confirm(String title, String message, String action) async =>
      await showAppSheet<bool>(
        context,
        builder: (context) => SheetScaffold(
          title: title,
          subtitle: message,
          footer: Column(
            children: [
              AppButton(
                label: action,
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
          child: const SizedBox.shrink(),
        ),
      ) ??
      false;

  Future<void> _run(String busy, Future<void> Function() action, String done) async {
    setState(() => _busy = busy);
    try {
      await action();
      ref.invalidate(devicesProvider);
      if (mounted) showAppToast(context, done, icon: AppIcons.check);
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _signOutOne(DeviceSession device) async {
    final ok = await _confirm(
      'Sign out this device?',
      '${device.platformLabel} will be signed out the next time it connects.',
      'Sign out',
    );
    if (!ok || !mounted) return;
    await _run(
      device.id,
      () => ref.read(settingsRepositoryProvider).endSession(device.id),
      'Signed out',
    );
  }

  Future<void> _signOutOthers() async {
    final ok = await _confirm(
      'Sign out all other devices?',
      'Only this phone stays signed in.',
      'Sign out others',
    );
    if (!ok || !mounted) return;
    await _run(
      '*',
      () => ref.read(settingsRepositoryProvider).endOtherSessions(),
      'Other devices signed out',
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);
    final value = devices.value;
    if (value == null) {
      return SettingsPage(
        title: 'Devices',
        children: [
          SettingsLoadState(
            error: devices.error,
            retrying: devices.isLoading,
            title: 'Couldn\'t load your devices',
            onRetry: () => ref.invalidate(devicesProvider),
          ),
        ],
      );
    }
    final others = value.where((d) => !d.current).length;
    return SettingsPage(
      title: 'Devices',
      children: [
        for (final device in value)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 4),
            child: ListRowCard(
              title: device.current ? '${device.platformLabel} · This phone' : device.platformLabel,
              subtitle:
                  'App ${device.appVersion} · '
                  '${device.current ? 'active now' : 'active ${relativeTime(device.lastSeenAt).toLowerCase()}'}',
              leading: RowIcon(
                icon: AppIcons.device,
                tone: device.current ? PastelTone.mint : PastelTone.neutral,
              ),
              trailing: device.current
                  ? null
                  : AppButton(
                      label: 'Sign out',
                      size: AppButtonSize.small,
                      variant: AppButtonVariant.secondary,
                      expand: false,
                      loading: _busy == device.id,
                      onPressed: _busy == null ? () => unawaited(_signOutOne(device)) : null,
                    ),
            ),
          ),
        if (others > 0) ...[
          const SizedBox(height: AppSpacing.xl),
          Gutter(
            child: AppButton(
              label: 'Sign out all other devices',
              variant: AppButtonVariant.secondary,
              leadingIcon: AppIcons.logout,
              loading: _busy == '*',
              onPressed: _busy == null ? () => unawaited(_signOutOthers()) : null,
            ),
          ),
        ],
        const SettingsNote('Devices you sign out here notice the next time they connect.'),
      ],
    );
  }
}
