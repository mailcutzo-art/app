import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import 'app_icon_button.dart';

/// Top row with avatar, greeting and circular actions (reference 1).
class GreetingHeader extends StatelessWidget {
  const GreetingHeader({
    super.key,
    required this.avatar,
    required this.greeting,
    this.subtitle,
    this.onAvatarTap,
    this.actions = const [],
  });

  final Widget avatar;
  final String greeting;
  final String? subtitle;
  final VoidCallback? onAvatarTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.md, AppSpacing.gutter, 0),
      child: Row(
        children: [
          Semantics(
            button: onAvatarTap != null,
            label: 'Profile',
            child: GestureDetector(onTap: onAvatarTap, child: avatar),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  style: text.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: text.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            actions[i],
          ],
        ],
      ),
    );
  }
}

/// Big bold page title with tight tracking (reference 2).
class LargeTitle extends StatelessWidget {
  const LargeTitle({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.lg, AppSpacing.gutter, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.headlineLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(subtitle!, style: text.bodyMedium),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Top bar for pushed screens: circular back button, optional title and
/// trailing circular actions (reference 3).
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBar({super.key, this.title, this.onBack, this.actions = const []});

  final String? title;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(76);

  @override
  Widget build(BuildContext context) {
    final canPop = onBack != null || Navigator.maybeOf(context)?.canPop() == true;
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: preferredSize.height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: Row(
            children: [
              if (canPop)
                AppIconButton(
                  icon: AppIcons.back,
                  semanticLabel: 'Back',
                  onPressed: onBack ?? () => Navigator.maybePop(context),
                ),
              if (title != null) ...[
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    title!,
                    style: context.text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.sm),
                actions[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
