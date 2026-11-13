import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/brand.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';

/// Shown while the stored session is restored, or when that failed and there
/// is no cached profile to fall back to.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final error = session.error;
    return Scaffold(
      body: Center(
        child: error == null
            ? const _Logo()
            : ErrorState(
                title: 'Couldn\'t reach PrepCue',
                message: error is AppFailure ? error.message : 'Please try again.',
                retrying: session.isLoading,
                onRetry: () => ref.invalidate(sessionProvider),
              ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return const AppLogo(size: 88, semanticLabel: 'Loading PrepCue');
  }
}
