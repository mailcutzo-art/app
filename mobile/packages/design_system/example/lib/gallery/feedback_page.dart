import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'gallery_scaffold.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  bool _offline = true;
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    return GalleryScaffold(
      title: 'Feedback',
      children: [
        DemoBlock(
          title: 'Offline banner',
          child: Column(
            children: [
              OfflineBanner(visible: _offline),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: _offline ? 'Go online' : 'Go offline',
                size: AppButtonSize.small,
                variant: AppButtonVariant.secondary,
                onPressed: () => setState(() => _offline = !_offline),
              ),
            ],
          ),
        ),
        const DemoBlock(
          title: 'Loading skeleton',
          child: Shimmer(
            child: Column(
              children: [
                Row(
                  children: [
                    SkeletonBox(height: 48, circle: true),
                    SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBox(width: 160, height: 14),
                          SizedBox(height: AppSpacing.sm),
                          SkeletonBox(width: 100, height: 12),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: AppSpacing.lg),
                SkeletonBox(height: 150, radius: AppRadii.xxl),
                SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(child: SkeletonBox(height: 120, radius: AppRadii.xxl)),
                    SizedBox(width: AppSpacing.md),
                    Expanded(child: SkeletonBox(height: 120, radius: AppRadii.xxl)),
                  ],
                ),
              ],
            ),
          ),
        ),
        DemoBlock(
          title: 'Section error (compact)',
          child: ErrorState(
            compact: true,
            title: 'Couldn\'t load chapters',
            message: 'We\'ll retry when you\'re back online.',
            retrying: _retrying,
            onRetry: _retry,
          ),
        ),
        DemoBlock(
          title: 'Screen error',
          child: SurfaceCard(
            child: ErrorState(onRetry: _retry, retrying: _retrying),
          ),
        ),
        const DemoBlock(
          title: 'Empty state',
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.bookmark,
              title: 'No bookmarks yet',
              message: 'Tap the bookmark on any question to save it for revision.',
              actionLabel: 'Start practice',
            ),
          ),
        ),
        DemoBlock(
          title: 'Toast and sheet',
          child: Spaced(
            children: [
              AppButton(
                label: 'Show toast',
                variant: AppButtonVariant.secondary,
                onPressed: () => showAppToast(context, 'Bookmark saved', icon: AppIcons.bookmark),
              ),
              AppButton(
                label: 'Open sheet',
                variant: AppButtonVariant.secondary,
                onPressed: () => showAppSheet<void>(
                  context,
                  builder: (context) => SheetScaffold(
                    title: 'Leave the match?',
                    subtitle: 'You\'ll lose this game and your rating will drop.',
                    footer: Column(
                      children: [
                        AppButton(label: 'Keep playing', onPressed: () => Navigator.pop(context)),
                        const SizedBox(height: AppSpacing.sm),
                        AppButton(
                          label: 'Leave',
                          variant: AppButtonVariant.danger,
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    child: const SizedBox(height: AppSpacing.sm),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
