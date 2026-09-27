import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';

/// Shown while the service is in maintenance. Checks again every 30 seconds,
/// and the router moves on by itself once the server says it's over.
class MaintenanceScreen extends ConsumerStatefulWidget {
  const MaintenanceScreen({super.key});

  static const recheckEvery = Duration(seconds: 30);

  @override
  ConsumerState<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends ConsumerState<MaintenanceScreen> {
  Timer? _timer;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(MaintenanceScreen.recheckEvery, (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await ref.read(configProvider.notifier).recheck();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = ref.watch(configProvider).value?.maintenanceMessage;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: EmptyState(
              icon: AppIcons.settings,
              tone: PastelTone.lemon,
              title: 'Quick maintenance',
              message:
                  message ??
                  'We\'re making Quiz Arena better. This usually takes a few minutes. '
                      'Your progress is safe.',
              actionLabel: _checking ? 'Checking…' : 'Try again',
              onAction: _checking ? null : _check,
            ),
          ),
        ),
      ),
    );
  }
}
