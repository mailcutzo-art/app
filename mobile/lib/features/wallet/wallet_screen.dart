import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/paging.dart';
import '../../core/utils/time_text.dart';
import '../common/paged_list.dart';
import '../learn/widgets/learn_widgets.dart' show CardSkeleton, RowsSkeleton, failureMessage;
import 'data/wallet_models.dart';
import 'wallet_providers.dart';

/// The balance, coins held for games in progress, and every credit and debit with its reason
/// and a link to its source (`/wallet`). The balance and the history load independently.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    ref.invalidate(walletProvider);
    var failed = false;
    try {
      await ref.read(walletHistoryProvider.notifier).refresh();
    } on Object {
      failed = true;
    }
    await settle(ref.read(walletProvider.future));
    failed = failed || ref.read(walletProvider).hasError;
    if (failed && context.mounted) {
      showAppToast(context, 'Couldn\'t refresh everything. Try again in a moment.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(walletHistoryProvider);
    return Scaffold(
      appBar: const AppTopBar(title: 'Wallet'),
      body: LoadMoreListener(
        onNearEnd: () => unawaited(ref.read(walletHistoryProvider.notifier).autoLoadMore()),
        child: RefreshIndicator(
          onRefresh: () => _refresh(context, ref),
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
            children: [
              const _Balance(),
              const SectionHeader(
                title: 'Coins history',
                padding: EdgeInsets.fromLTRB(0, AppSpacing.xxl, 0, AppSpacing.md),
              ),
              ...switch (history) {
                AsyncValue(:final value?) when value.items.isEmpty => [
                  const SurfaceCard(
                    child: EmptyState(
                      icon: AppIcons.coins,
                      tone: PastelTone.lemon,
                      title: 'No coins moved yet',
                      message: 'Entry fees, prizes, rewards and refunds will show up here.',
                    ),
                  ),
                ],
                AsyncValue(:final value?) => [
                  for (final tx in value.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: TransactionRow(tx: tx),
                    ),
                  PagedFooter(
                    paged: value,
                    onLoadMore: () =>
                        unawaited(ref.read(walletHistoryProvider.notifier).loadMore()),
                  ),
                ],
                AsyncValue(:final error?) => [
                  ErrorState(
                    compact: true,
                    title: 'Couldn\'t load your coins history',
                    message: failureMessage(error),
                    retrying: history.isLoading,
                    onRetry: () => ref.invalidate(walletHistoryProvider),
                  ),
                ],
                _ => [const RowsSkeleton(rows: 5)],
              },
            ],
          ),
        ),
      ),
    );
  }
}

class _Balance extends ConsumerWidget {
  const _Balance();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallet = ref.watch(walletProvider);
    return switch (wallet) {
      AsyncValue(:final value?) => HeroStatCard(
        label: 'Balance',
        value: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HugeIcon(AppIcons.coins, size: 30, color: context.colors.ink),
            const SizedBox(width: AppSpacing.sm),
            Text(formatCount(value.balance), semanticsLabel: '${value.balance} coins'),
          ],
        ),
        caption: 'Coins for casual battles, tournaments and streak freezes',
        stats: [
          HeroStat(label: 'Held for games', value: formatCount(value.held)),
          HeroStat(
            label: 'Available',
            value: formatCount((value.balance - value.held).clamp(0, value.balance)),
          ),
        ],
      ),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load your balance',
        message: failureMessage(error),
        retrying: wallet.isLoading,
        onRetry: () => ref.invalidate(walletProvider),
      ),
      _ => const CardSkeleton(height: 190),
    };
  }
}

/// One credit or debit: what it was, when, how many coins, and a link to its source.
class TransactionRow extends StatelessWidget {
  const TransactionRow({super.key, required this.tx});

  final WalletTx tx;

  @override
  Widget build(BuildContext context) {
    final location = tx.ref?.location;
    final credit = tx.delta >= 0;
    return ListRowCard(
      title: tx.title,
      subtitle: [
        relativeTime(tx.createdAt),
        if (tx.balanceAfter case final after?) 'Balance ${formatCount(after)}',
      ].join(' · '),
      leading: RowIcon(
        icon: credit ? AppIcons.add : AppIcons.minus,
        tone: credit ? PastelTone.mint : PastelTone.peach,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CoinAmount(amount: tx.delta, signed: true),
          if (location != null) ...[
            const SizedBox(width: AppSpacing.xs),
            HugeIcon(AppIcons.chevronRight, size: 18, color: context.colors.inkMuted),
          ],
        ],
      ),
      onTap: location == null ? null : () => unawaited(context.push(location)),
    );
  }
}
