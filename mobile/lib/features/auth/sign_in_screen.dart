import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/env.dart';
import '../../app/router.dart';
import '../../core/auth/google_auth.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import 'dev_login_sheet.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;

  Future<void> _google() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).signInWithGoogle();
    } on SignInCancelled {
      // The user closed the account picker.
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final env = ref.watch(appEnvProvider);
    final expiredMessage = switch (ref.watch(sessionProvider).value) {
      SignedOut(:final message) => message,
      _ => null,
    };

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.paperGradientStart, colors.paperGradientEnd, colors.paper],
            stops: const [0, 0.35, 0.7],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: AppSpacing.xxl),
                      Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
                            alignment: Alignment.center,
                            child: HugeIcon(AppIcons.rocket, size: 24, color: colors.onAccent),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Text('Quiz Arena', style: text.titleLarge),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.huge),
                      Text('Battle your way\nto NEET & JEE\nsuccess.', style: text.display),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Live 1v1 quizzes, weekly tournaments and smart practice — all in one place.',
                        style: text.bodyLarge.copyWith(color: colors.inkMuted),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      const _FeatureTiles(),
                      const Spacer(),
                      if (expiredMessage != null) ...[
                        InfoChip(
                          icon: AppIcons.info,
                          label: expiredMessage,
                          background: colors.lemon.container,
                          foreground: colors.lemon.onContainer,
                        ),
                        const SizedBox(height: AppSpacing.md),
                      ],
                      AppButton(
                        label: 'Continue with Google',
                        leadingIcon: AppIcons.google,
                        variant: AppButtonVariant.ink,
                        loading: _busy,
                        onPressed: env.googleSignInConfigured ? _google : null,
                      ),
                      if (env.devLoginAvailable) ...[
                        const SizedBox(height: AppSpacing.sm),
                        AppButton(
                          label: 'Developer login',
                          variant: AppButtonVariant.ghost,
                          size: AppButtonSize.medium,
                          onPressed: _busy ? null : () => showDevLoginSheet(context),
                        ),
                        Center(
                          child: TextButton(
                            onPressed: () => context.push(Routes.debug),
                            child: Text('Debug settings', style: text.caption),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'By continuing you agree to our Terms and Privacy Policy.',
                        textAlign: TextAlign.center,
                        style: text.caption,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureTiles extends StatelessWidget {
  const _FeatureTiles();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(
          child: PastelTile(
            tone: PastelTone.sky,
            icon: AppIcons.battle,
            title: 'Live 1v1',
            height: 128,
            iconMotion: IconMotions.gamepad,
          ),
        ),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: PastelTile(
            tone: PastelTone.lemon,
            icon: AppIcons.arena,
            title: 'Tournaments',
            height: 128,
            iconMotion: IconMotions.trophy,
          ),
        ),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: PastelTile(
            tone: PastelTone.mint,
            icon: AppIcons.learn,
            title: 'Practice',
            height: 128,
            iconMotion: IconMotions.book,
          ),
        ),
      ],
    );
  }
}
