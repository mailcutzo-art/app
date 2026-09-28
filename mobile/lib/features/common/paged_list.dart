import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../../core/network/paging.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;

/// Asks for the next page when the list scrolls near its end.
class LoadMoreListener extends StatelessWidget {
  const LoadMoreListener({super.key, required this.onNearEnd, required this.child});

  final VoidCallback onNearEnd;
  final Widget child;

  /// How close to the end (in pixels) the next page is asked for.
  static const threshold = 400.0;

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
    onNotification: (notification) {
      final metrics = notification.metrics;
      if (metrics.axis == Axis.vertical && metrics.extentAfter < threshold) onNearEnd();
      return false;
    },
    child: child,
  );
}

/// The row under a paged list: a spinner while the next page loads, a retry when it failed,
/// "Show more" when [manual] (inside a longer screen), and nothing on the last page.
class PagedFooter extends StatelessWidget {
  const PagedFooter({
    super.key,
    required this.paged,
    required this.onLoadMore,
    this.manual = false,
  });

  final Paged<Object?> paged;
  final VoidCallback onLoadMore;

  /// Offer a "Show more" button instead of loading on scroll.
  final bool manual;

  @override
  Widget build(BuildContext context) {
    if (paged.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Center(
          child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (paged.moreError case final error?) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: ErrorState(
          compact: true,
          title: 'Couldn\'t load more',
          message: failureMessage(error),
          onRetry: onLoadMore,
        ),
      );
    }
    if (manual && paged.hasMore) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: AppButton(
          label: 'Show more',
          variant: AppButtonVariant.ghost,
          size: AppButtonSize.medium,
          onPressed: onLoadMore,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// A tinted circle with an icon, the leading visual of list rows.
class RowIcon extends StatelessWidget {
  const RowIcon({super.key, required this.icon, this.tone = PastelTone.neutral, this.size = 44});

  final HugeIconData icon;
  final PastelTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final pair = context.colors.pastel(tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: HugeIcon(icon, size: size / 2, color: pair.onContainer),
    );
  }
}
