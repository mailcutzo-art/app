import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/env.dart';
import '../../core/device/device_info.dart';
import '../../core/storage/prefs.dart';
import '../learn/data/learn_repository.dart';

// It used to be defined here; kept importable from here.
export '../../core/storage/prefs.dart' show sharedPrefsProvider;

/// Keys for debug-only preferences.
abstract final class DebugPrefs {
  static const apiBaseUrl = 'debug.api_base_url';
}

/// Dev-build tools: point the app at another server (e.g. a laptop on the
/// same Wi-Fi) and see build details. Changes apply after a restart.
class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});

  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  late final TextEditingController _url = TextEditingController(
    text:
        ref.read(sharedPrefsProvider).getString(DebugPrefs.apiBaseUrl) ??
        ref.read(appEnvProvider).apiBaseUrl,
  );

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _url.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      showAppToast(context, 'Enter a full URL like http://192.168.1.20:8000');
      return;
    }
    await ref.read(sharedPrefsProvider).setString(DebugPrefs.apiBaseUrl, value);
    if (mounted) showAppToast(context, 'Saved. Restart the app to use it.', icon: AppIcons.check);
  }

  Future<void> _setDemoData({required bool enabled}) async {
    await ref.read(demoDataProvider.notifier).set(enabled: enabled);
    if (!mounted) return;
    showAppToast(
      context,
      enabled ? 'Learn now uses sample questions.' : 'Learn now uses the server.',
      icon: AppIcons.check,
    );
  }

  Future<void> _reset() async {
    await ref.read(sharedPrefsProvider).remove(DebugPrefs.apiBaseUrl);
    _url.text = AppEnv.fromDefines().apiBaseUrl;
    if (mounted) showAppToast(context, 'Reset. Restart the app to apply.');
  }

  @override
  Widget build(BuildContext context) {
    final env = ref.watch(appEnvProvider);
    final device = ref.watch(deviceInfoProvider).value;
    final text = context.text;
    return Scaffold(
      appBar: const AppTopBar(title: 'Debug settings'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          if (!env.isDev)
            const EmptyState(icon: AppIcons.lock, title: 'Not available in this build')
          else ...[
            AppTextField(
              label: 'API base URL',
              controller: _url,
              keyboardType: TextInputType.url,
              helper: 'Current: ${env.apiBaseUrl}',
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(label: 'Save', onPressed: _save),
            const SizedBox(height: AppSpacing.sm),
            AppButton(label: 'Reset', variant: AppButtonVariant.ghost, onPressed: _reset),
            const SizedBox(height: AppSpacing.xl),
            ToggleRow(
              title: 'Demo data',
              subtitle: 'Sample questions for Learn and practice, no server needed',
              icon: AppIcons.sparkles,
              value: ref.watch(demoDataProvider),
              margin: EdgeInsets.zero,
              onChanged: (on) => unawaited(_setDemoData(enabled: on)),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text('Build', style: text.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text('Flavor: ${env.flavor.name}', style: text.bodyMedium),
            Text(
              'Google sign-in: ${env.googleSignInConfigured ? 'configured' : 'not configured'}',
              style: text.bodyMedium,
            ),
            if (device != null) ...[
              Text('Version: ${device.appVersion} (${device.build})', style: text.bodyMedium),
              Text('Install id: ${device.installId.substring(0, 8)}…', style: text.bodyMedium),
            ],
          ],
        ],
      ),
    );
  }
}
