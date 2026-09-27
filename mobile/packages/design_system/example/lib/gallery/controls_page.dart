import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'gallery_scaffold.dart';

class ControlsPage extends StatefulWidget {
  const ControlsPage({super.key});

  @override
  State<ControlsPage> createState() => _ControlsPageState();
}

class _ControlsPageState extends State<ControlsPage> {
  String _mode = 'rated';
  final _filters = <String>{'Open'};
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GalleryScaffold(
      title: 'Controls',
      children: [
        DemoBlock(
          title: 'Buttons · large 60dp',
          child: Spaced(
            children: [
              AppButton(label: 'Find opponent', trailingIcon: AppIcons.search, onPressed: () {}),
              AppButton(label: 'Join tournament', variant: AppButtonVariant.ink, onPressed: () {}),
              AppButton(
                label: 'Practice weak spots',
                variant: AppButtonVariant.secondary,
                onPressed: () {},
              ),
              AppButton(
                label: 'Loading state',
                loading: _loading,
                onPressed: () async {
                  setState(() => _loading = true);
                  await Future<void>.delayed(const Duration(seconds: 2));
                  if (mounted) setState(() => _loading = false);
                },
              ),
              const AppButton(label: 'Disabled', onPressed: null),
            ],
          ),
        ),
        DemoBlock(
          title: 'Buttons · medium & small',
          child: Spaced(
            horizontal: true,
            gap: AppSpacing.sm,
            children: [
              AppButton(
                label: 'Resume',
                size: AppButtonSize.medium,
                expand: false,
                variant: AppButtonVariant.ink,
                onPressed: () {},
              ),
              AppButton(
                label: 'Tonal',
                size: AppButtonSize.medium,
                expand: false,
                variant: AppButtonVariant.tonal,
                tone: PastelTone.sky,
                onPressed: () {},
              ),
              AppButton(
                label: 'Leave',
                size: AppButtonSize.medium,
                expand: false,
                variant: AppButtonVariant.danger,
                onPressed: () {},
              ),
              AppButton(
                label: 'Ghost',
                size: AppButtonSize.small,
                expand: false,
                variant: AppButtonVariant.ghost,
                onPressed: () {},
              ),
              AppButton(
                label: 'Retry',
                size: AppButtonSize.small,
                expand: false,
                variant: AppButtonVariant.secondary,
                leadingIcon: AppIcons.refresh,
                onPressed: () {},
              ),
            ],
          ),
        ),
        DemoBlock(
          title: 'Icon buttons',
          child: Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: [
              AppIconButton(icon: AppIcons.back, semanticLabel: 'Back', onPressed: () {}),
              AppIconButton(
                icon: AppIcons.notification,
                semanticLabel: 'Notifications',
                badgeCount: 5,
                motion: IconMotions.bell,
                onPressed: () {},
              ),
              AppIconButton(
                icon: AppIcons.filter,
                semanticLabel: 'Filter',
                showDot: true,
                onPressed: () {},
              ),
              AppIconButton(
                icon: AppIcons.bookmark,
                semanticLabel: 'Bookmark',
                variant: AppIconButtonVariant.tonal,
                motion: IconMotions.bookmark,
                onPressed: () {},
              ),
              AppIconButton(
                icon: AppIcons.add,
                semanticLabel: 'Add',
                variant: AppIconButtonVariant.ink,
                onPressed: () {},
              ),
              const AppIconButton(
                icon: AppIcons.share,
                semanticLabel: 'Share (disabled)',
                onPressed: null,
              ),
            ],
          ),
        ),
        DemoBlock(
          title: 'Segmented control',
          child: AppSegmentedControl<String>(
            segments: const [
              AppSegment(value: 'rated', label: 'Rated', icon: AppIcons.flash),
              AppSegment(value: 'casual', label: 'Casual', icon: AppIcons.smile),
            ],
            selected: _mode,
            onChanged: (v) => setState(() => _mode = v),
          ),
        ),
        DemoBlock(
          title: 'Chips',
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final f in ['All', 'Open', 'Live', 'Upcoming'])
                AppChip(
                  label: f,
                  selected: _filters.contains(f),
                  onSelected: (on) => setState(() => on ? _filters.add(f) : _filters.remove(f)),
                ),
              AppChip(
                label: 'Physics',
                dotColor: colors.sky.onContainer,
                selected: false,
                onSelected: (_) {},
              ),
              AppChip(
                label: 'Free entry',
                icon: AppIcons.coins,
                selected: false,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Badges and info chips',
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OverlineBadge(label: 'Registration open', icon: AppIcons.clock, solid: true),
              OverlineBadge(label: 'Biology', tone: PastelTone.mint),
              OverlineBadge(label: '+25 XP', tone: PastelTone.lemon),
              LiveBadge(),
              InfoChip(icon: AppIcons.checklist, label: '6 rounds'),
              InfoChip(icon: AppIcons.award, label: '2,500'),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Inputs',
          child: Spaced(
            children: [
              AppSearchField(hint: 'Search questions or chapters'),
              AppTextField(
                label: 'Username',
                hint: 'e.g. aarav_27',
                helper: '3–20 letters, numbers or _',
              ),
              AppTextField(
                label: 'Username',
                hint: 'e.g. aarav_27',
                error: 'That username is taken',
              ),
              CodeInput(autofocus: false),
            ],
          ),
        ),
      ],
    );
  }
}
