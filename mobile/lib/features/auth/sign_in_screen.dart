import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/env.dart';
import '../../app/router.dart';
import '../../core/auth/google_auth.dart';
import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import 'dev_login_sheet.dart';
import 'welcome/arena_hero.dart';
import 'welcome/welcome_widgets.dart';

/// The welcome screen: the Quiz Arena entrance and the one way in, Continue
/// with Google (plus developer login in dev builds).
///
/// It always wears the dark theme, whatever the system setting, since it's a
/// branded entrance; toasts and sheets it opens keep the app's own theme.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  static final _welcomeTheme = AppTheme.dark();

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
    final env = ref.watch(appEnvProvider);
    final expiredMessage = switch (ref.watch(sessionProvider).value) {
      SignedOut(:final message) => message,
      _ => null,
    };

    return Theme(
      data: _welcomeTheme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: QuizArenaWelcomePage(
          notice: expiredMessage,
          actions: _WelcomeActions(
            busy: _busy,
            onGoogle: env.googleSignInConfigured ? _google : null,
            // The screen's own context, outside the dark theme.
            onDevLogin: env.devLoginAvailable ? () => showDevLoginSheet(context) : null,
            onDebug: env.devLoginAvailable ? () => context.push(Routes.debug) : null,
          ),
        ),
      ),
    );
  }
}

/// Lays the welcome out top to bottom: brand, arena, headline and chips, then
/// the sign-in [actions] pinned to the bottom. The arena takes the space left
/// over (shrinking to [minHeroHeight] on small phones before anything else
/// gives), and only when even that doesn't fit, e.g. at very large text
/// sizes, does the page scroll.
class QuizArenaWelcomePage extends StatelessWidget {
  const QuizArenaWelcomePage({super.key, required this.actions, this.notice});

  final Widget actions;

  /// Why the player was signed out, if they didn't ask to be.
  final String? notice;

  /// The smallest the arena gets before the page scrolls instead.
  static const minHeroHeight = 120.0;

  /// Below this much height (inside the safe area) the gaps tighten.
  static const compactHeight = 640.0;

  /// Below this width the side gutters narrow.
  static const narrowWidth = 360.0;

  /// Keeps the arena from ballooning on tablets and tall phones.
  static const maxHeroWidth = 420.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final notice = this.notice;
    return Scaffold(
      backgroundColor: colors.paper,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.paperGradientStart, colors.paper],
            stops: const [0, 0.55],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Short phones tighten the gaps before the arena has to shrink much.
              final compact = constraints.maxHeight < compactHeight;
              final gap = compact ? AppSpacing.sm : AppSpacing.md;
              // Narrow phones trade some gutter for the button label and the chips.
              final gutter = constraints.maxWidth < narrowWidth ? AppSpacing.md : AppSpacing.gutter;
              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: gutter),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        SizedBox(height: compact ? AppSpacing.sm : AppSpacing.lg),
                        const FadeUp(end: 0.6, child: WelcomeBrand()),
                        const SizedBox(height: AppSpacing.sm),
                        // The arena and its pitch; what's left over opens up above the button.
                        Expanded(
                          child: Column(
                            children: [
                              Flexible(
                                child: HeroSlot(
                                  minHeight: minHeroHeight,
                                  aspectRatio: ArenaHero.aspectRatio,
                                  maxWidth: maxHeroWidth,
                                  bleed: gutter,
                                  spareShare: 0.35,
                                  child: const ArenaHero(),
                                ),
                              ),
                              SizedBox(height: gap),
                              const FadeUp(begin: 0.3, child: WelcomeHeadline()),
                              SizedBox(height: gap),
                              const FadeUp(begin: 0.45, child: FeatureChips()),
                            ],
                          ),
                        ),
                        SizedBox(height: compact ? AppSpacing.lg : AppSpacing.xxl),
                        if (notice != null) ...[
                          SessionNotice(message: notice),
                          SizedBox(height: gap),
                        ],
                        actions,
                        const SizedBox(height: AppSpacing.sm),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Continue with Google, the dev-build shortcuts and the legal line.
class _WelcomeActions extends StatelessWidget {
  const _WelcomeActions({
    required this.busy,
    required this.onGoogle,
    required this.onDevLogin,
    required this.onDebug,
  });

  final bool busy;
  final VoidCallback? onGoogle;
  final VoidCallback? onDevLogin;
  final VoidCallback? onDebug;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Column(
      children: [
        // On narrow phones the label stops growing at 1.2× so it never gets cut off.
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: MediaQuery.sizeOf(context).width < QuizArenaWelcomePage.narrowWidth
              ? 1.2
              : double.infinity,
          child: AppButton(
            label: 'Continue with Google',
            leadingIcon: AppIcons.google,
            variant: AppButtonVariant.ink,
            loading: busy,
            onPressed: onGoogle,
          ),
        ),
        if (onDevLogin != null) ...[
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Developer login',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.medium,
            onPressed: busy ? null : onDevLogin,
          ),
        ],
        if (onDebug != null)
          TextButton(
            onPressed: onDebug,
            child: Text('Debug settings', style: text.caption),
          ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'By continuing you agree to our Terms and Privacy Policy.',
          textAlign: TextAlign.center,
          style: text.caption,
        ),
      ],
    );
  }
}
