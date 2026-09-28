import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/paging.dart';
import 'data/wallet_models.dart';
import 'data/wallet_repository.dart';

/// `GET /v1/me/wallet`, for the Wallet screen and the Profile entry.
final walletProvider = FutureProvider.autoDispose<WalletSummary>((ref) {
  // Someone else signing in on this phone gets their own coins.
  ref.watch(currentUserIdProvider);
  return ref.watch(walletRepositoryProvider).wallet();
}, retry: (_, _) => null);

/// The coins history, paged.
final walletHistoryProvider =
    AsyncNotifierProvider.autoDispose<WalletHistoryNotifier, Paged<WalletTx>>(
      WalletHistoryNotifier.new,
      retry: (_, _) => null,
    );

class WalletHistoryNotifier extends PagedNotifier<WalletTx> {
  @override
  Future<Paged<WalletTx>> build() {
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<CursorPage<WalletTx>> fetch(String? cursor) =>
      ref.read(walletRepositoryProvider).transactions(cursor: cursor);
}
