import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/app_failure.dart';
import 'data/settings_models.dart';
import 'settings_providers.dart';
import 'widgets/settings_widgets.dart';

/// Notifications (`/settings/notifications`): each kind on or off, and quiet hours when
/// notifications go to the inbox without a push.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  Future<void> _save(BuildContext context, WidgetRef ref, NotificationSettings next) async {
    try {
      await ref.read(notificationSettingsProvider.notifier).save(next);
    } on AppFailure catch (failure) {
      if (context.mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    }
  }

  Future<void> _pickTime(
    BuildContext context,
    WidgetRef ref,
    NotificationSettings value, {
    required bool start,
  }) async {
    final current = start ? value.quietStart : value.quietEnd;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: start ? 'Quiet hours start' : 'Quiet hours end',
    );
    if (picked == null || !context.mounted) return;
    final time = DayTime(picked.hour, picked.minute);
    await _save(
      context,
      ref,
      start ? value.withQuietHours(start: time) : value.withQuietHours(end: time),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(notificationSettingsProvider);
    final value = settings.value;
    if (value == null) {
      return SettingsPage(
        title: 'Notifications',
        children: [
          SettingsLoadState(
            error: settings.error,
            retrying: settings.isLoading,
            rows: 6,
            title: 'Couldn\'t load your notification settings',
            onRetry: () => ref.invalidate(notificationSettingsProvider),
          ),
        ],
      );
    }
    return SettingsPage(
      title: 'Notifications',
      children: [
        const SettingsHeader('Tell me about'),
        for (final kind in NotificationKind.values)
          ToggleRow(
            title: kind.label,
            subtitle: kind.description,
            value: value.isOn(kind),
            onChanged: (on) => unawaited(_save(context, ref, value.withKind(kind, on: on))),
          ),
        const SettingsNote('Everything is still kept in your inbox, whatever is switched off.'),
        const SettingsHeader('Quiet hours'),
        SettingsLink(
          title: 'Starts',
          icon: AppIcons.moon,
          tone: PastelTone.lavender,
          value: value.quietStart.wire,
          onTap: () => unawaited(_pickTime(context, ref, value, start: true)),
        ),
        SettingsLink(
          title: 'Ends',
          icon: AppIcons.sun,
          tone: PastelTone.lemon,
          value: value.quietEnd.wire,
          onTap: () => unawaited(_pickTime(context, ref, value, start: false)),
        ),
        const SettingsNote(
          'India time. During quiet hours notifications go to your inbox without a sound, '
          'except your own match or tournament round.',
        ),
      ],
    );
  }
}
