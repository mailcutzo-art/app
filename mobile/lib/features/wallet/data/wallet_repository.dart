import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../../core/network/paging.dart';
import '../../battle/data/battle_repository.dart' show parseResponse;
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import 'wallet_models.dart';

/// The wallet REST contract (`docs/api-play.md`, "Wallet and XP").
abstract interface class WalletRepository {
  /// `GET /v1/me/wallet`.
  Future<WalletSummary> wallet();

  /// `GET /v1/me/wallet/transactions?cursor=`, newest first.
  Future<CursorPage<WalletTx>> transactions({String? cursor});
}

class ApiWalletRepository implements WalletRepository {
  ApiWalletRepository(this._api);

  final ApiClient _api;

  @override
  Future<WalletSummary> wallet() async {
    final data = await _api.get('/v1/me/wallet');
    return parseResponse(() => WalletSummary.fromJson(data));
  }

  @override
  Future<CursorPage<WalletTx>> transactions({String? cursor}) async {
    final data = await _api.get('/v1/me/wallet/transactions', query: {'cursor': ?cursor});
    return parseResponse(() => CursorPage.fromJson(data, WalletTx.fromJson, what: 'transactions'));
  }
}

/// Calls of [FakeWalletRepository] that tests can make fail.
enum FakeWalletOp { wallet, transactions }

/// In-memory wallet for tests and the debug "Demo data" mode.
class FakeWalletRepository implements WalletRepository {
  FakeWalletRepository({
    this.balance = 0,
    this.held = 0,
    List<WalletTx> transactions = const [],
    this.pageSize = 20,
    this.latency = Duration.zero,
  }) : _transactions = [...transactions];

  /// A welcome bonus, some battles and a refund.
  factory FakeWalletRepository.seeded({Duration latency = Duration.zero, DateTime? now}) {
    final at = now ?? DateTime.now();
    return FakeWalletRepository(
      balance: 245,
      held: 5,
      latency: latency,
      transactions: [
        WalletTx(
          id: 'tx-5',
          delta: 5,
          balanceAfter: 245,
          reason: 'refund',
          title: 'Refund: match cancelled',
          ref: const TxRef(kind: TxKind.match, id: 'demo-m2'),
          createdAt: at.subtract(const Duration(hours: 2)),
        ),
        WalletTx(
          id: 'tx-4',
          delta: -5,
          balanceAfter: 240,
          reason: 'casual_entry',
          title: 'Casual battle entry',
          ref: const TxRef(kind: TxKind.match, id: 'demo-m2'),
          createdAt: at.subtract(const Duration(hours: 3)),
        ),
        WalletTx(
          id: 'tx-3',
          delta: 25,
          balanceAfter: 245,
          reason: 'missions_bonus',
          title: 'Daily missions bonus',
          ref: const TxRef(kind: TxKind.mission),
          createdAt: at.subtract(const Duration(days: 1)),
        ),
        WalletTx(
          id: 'tx-2',
          delta: 120,
          balanceAfter: 220,
          reason: 'prize',
          title: 'Tournament prize: #3 in Physics Sunday Cup',
          ref: const TxRef(kind: TxKind.tournament, id: 'demo-t1'),
          createdAt: at.subtract(const Duration(days: 4)),
        ),
        WalletTx(
          id: 'tx-1',
          delta: 100,
          balanceAfter: 100,
          reason: 'welcome',
          title: 'Welcome bonus',
          ref: const TxRef(kind: TxKind.welcome),
          createdAt: at.subtract(const Duration(days: 9)),
        ),
      ],
    );
  }

  int balance;
  int held;
  final List<WalletTx> _transactions;
  final int pageSize;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Calls that fail until removed from the map.
  final Map<FakeWalletOp, AppFailure> failures = {};

  /// Cursors asked for by `transactions`, in order.
  final List<String?> transactionCalls = [];

  /// Adds a line to the history (newest first) and moves the balance by its delta (the demo's
  /// tournament entries and prizes).
  void post(WalletTx tx) {
    balance += tx.delta;
    _transactions.insert(0, tx);
  }

  @override
  Future<WalletSummary> wallet() async {
    await _wait(FakeWalletOp.wallet);
    return WalletSummary(balance: balance, held: held, recent: _transactions.take(5).toList());
  }

  @override
  Future<CursorPage<WalletTx>> transactions({String? cursor}) async {
    transactionCalls.add(cursor);
    await _wait(FakeWalletOp.transactions);
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + pageSize).clamp(0, _transactions.length);
    return CursorPage(
      List.unmodifiable(_transactions.sublist(start, end)),
      nextCursor: end < _transactions.length ? '$end' : null,
    );
  }

  Future<void> _wait(FakeWalletOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }
}

/// The wallet in the debug "Demo data" mode.
final demoWalletRepositoryProvider = Provider<FakeWalletRepository>(
  (ref) => FakeWalletRepository.seeded(latency: const Duration(milliseconds: 300)),
);

final walletRepositoryProvider = Provider<WalletRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoWalletRepositoryProvider);
  return ApiWalletRepository(ref.watch(apiClientProvider));
});
