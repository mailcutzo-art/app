import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../common/paged_list.dart' show RowIcon;
import '../../learn/widgets/learn_widgets.dart' show failureMessage;

/// A settings page: a top bar and rows that bring their own side margins.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
    this.onBack,
  });

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppTopBar(
      title: title,
      actions: actions,
      onBack: onBack ?? () => context.canPop() ? context.pop() : context.go(Routes.settings),
    ),
    body: ListView(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xxxl),
      children: children,
    ),
  );
}

/// A group title inside a settings page.
class SettingsHeader extends StatelessWidget {
  const SettingsHeader(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => SectionHeader(
    title: title,
    subtitle: subtitle,
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.gutter,
      AppSpacing.xl,
      AppSpacing.gutter,
      AppSpacing.sm,
    ),
  );
}

/// A row that opens another settings page (or an outside page).
class SettingsLink extends StatelessWidget {
  const SettingsLink({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.value,
    this.tone = PastelTone.neutral,
  });

  final String title;
  final String? subtitle;

  /// The current value, shown before the chevron (e.g. a time).
  final String? value;
  final HugeIconData icon;
  final PastelTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 4),
    child: ListRowCard(
      title: title,
      subtitle: subtitle,
      leading: RowIcon(icon: icon, tone: tone),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value case final value?) ...[
            Text(value, style: context.text.numericMedium),
            const SizedBox(width: AppSpacing.sm),
          ],
          HugeIcon(AppIcons.chevronRight, size: 20, color: context.colors.inkMuted),
        ],
      ),
      onTap: onTap,
    ),
  );
}

/// A short explanation under a group of settings.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.gutter + 4, AppSpacing.sm, AppSpacing.gutter, 0),
    child: Text(text, style: context.text.caption),
  );
}

/// Loading and error states for a settings group that comes from the server.
class SettingsLoadState extends StatelessWidget {
  const SettingsLoadState({
    super.key,
    required this.error,
    required this.retrying,
    required this.onRetry,
    this.title = 'Couldn\'t load these settings',
    this.rows = 3,
  });

  /// Null while loading.
  final Object? error;
  final bool retrying;
  final VoidCallback onRetry;
  final String title;
  final int rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 4),
    child: error == null
        ? Shimmer(
            child: Column(
              children: [
                for (var i = 0; i < rows; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpacing.sm),
                    child: const SkeletonBox(height: 64, radius: AppRadii.lg),
                  ),
              ],
            ),
          )
        : ErrorState(
            compact: true,
            title: title,
            message: failureMessage(error!),
            retrying: retrying,
            onRetry: onRetry,
          ),
  );
}
