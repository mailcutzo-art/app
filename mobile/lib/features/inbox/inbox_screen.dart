import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/app_failure.dart';
import '../../core/utils/time_text.dart';
import '../common/open_action.dart';
import '../common/paged_list.dart';
import '../learn/widgets/learn_widgets.dart' show RowsSkeleton, failureMessage;
import 'data/inbox_models.dart';
import 'inbox_providers.dart';

/// Everything the app told the user, newest first (`/inbox`): unread until tapped, and each
/// opens its destination.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(inboxProvider.notifier).refresh();
      await ref.read(unreadCountProvider.notifier).refresh();
    } on AppFailure catch (failure) {
      if (context.mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    }
  }

  Future<void> _markAllRead(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(inboxProvider.notifier).markAllRead();
    } on AppFailure catch (failure) {
      if (context.mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    }
  }

  void _open(BuildContext context, WidgetRef ref, InboxItem item) {
    unawaited(ref.read(inboxProvider.notifier).markRead(item));
    if (item.action case final action?) openAppAction(context, action);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxProvider);
    final anyUnread = inbox.value?.items.any((item) => !item.read) ?? false;
    return Scaffold(
      appBar: AppTopBar(
        title: 'Inbox',
        actions: [
          if (anyUnread)
            TextButton(
              onPressed: () => _markAllRead(context, ref),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: switch (inbox) {
        AsyncValue(:final value?) when value.items.isEmpty => _Refreshable(
          onRefresh: () => _refresh(context, ref),
          children: const [
            EmptyState(
              icon: AppIcons.inbox,

              title: 'Nothing here yet',
              message: 'Invites, tournament updates, rewards and refunds will all be kept here.',
            ),
          ],
        ),
        AsyncValue(:final value?) => LoadMoreListener(
          onNearEnd: () => unawaited(ref.read(inboxProvider.notifier).autoLoadMore()),
          child: _Refreshable(
            onRefresh: () => _refresh(context, ref),
            children: [
              for (final item in value.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: InboxRow(item: item, onTap: () => _open(context, ref, item)),
                ),
              PagedFooter(
                paged: value,
                onLoadMore: () => unawaited(ref.read(inboxProvider.notifier).loadMore()),
              ),
            ],
          ),
        ),
        AsyncValue(:final error?) => Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: ErrorState(
            title: 'Couldn\'t load your inbox',
            message: failureMessage(error),
            retrying: inbox.isLoading,
            onRetry: () => ref.invalidate(inboxProvider),
          ),
        ),
        _ => const Padding(
          padding: EdgeInsets.all(AppSpacing.gutter),
          child: RowsSkeleton(rows: 6),
        ),
      },
    );
  }
}

class _Refreshable extends StatelessWidget {
  const _Refreshable({required this.onRefresh, required this.children});

  final Future<void> Function() onRefresh;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    color: context.colors.ink,
    backgroundColor: context.colors.surface,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.sm,
        AppSpacing.gutter,
        AppSpacing.xxxl,
      ),
      children: children,
    ),
  );
}

/// One inbox item: its icon, title and body, when it came, and a dot while unread.
class InboxRow extends StatelessWidget {
  const InboxRow({super.key, required this.item, required this.onTap});

  final InboxItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final (icon, tone) = item.look;
    return SurfaceCard(
      onTap: onTap,
      color: item.read ? null : colors.pastel(tone).container.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
      semanticLabel: item.read ? item.title : 'Unread: ${item.title}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RowIcon(icon: icon, tone: tone),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: text.titleMedium.copyWith(
                    fontWeight: item.read ? FontWeight.w600 : FontWeight.w800,
                  ),
                ),
                if (item.body case final body?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(body, style: text.bodySmall),
                  ),
                const SizedBox(height: 4),
                Text(relativeTime(item.createdAt), style: text.caption),
              ],
            ),
          ),
          if (!item.read) ...[
            const SizedBox(width: AppSpacing.sm),
            Container(
              key: const ValueKey('unread-dot'),
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(color: colors.error, shape: BoxShape.circle),
            ),
          ],
        ],
      ),
    );
  }
}
