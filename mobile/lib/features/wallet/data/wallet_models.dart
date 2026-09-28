import 'package:flutter/foundation.dart';

import '../../../app/router.dart';
import '../../../core/network/json.dart';

/// What a coin transaction came from (`ref.kind`).
enum TxKind {
  match,
  tournament,
  mission,
  streak,
  achievement,
  hint,
  welcome,
  level,
  unknown;

  static TxKind parse(Object? value) =>
      values.where((k) => k != unknown && k.name == value).firstOrNull ?? unknown;
}

/// The source of a transaction: `{"kind", "id"}`.
@immutable
class TxRef {
  const TxRef({required this.kind, this.id});

  factory TxRef.fromJson(Object? json) {
    final r = JsonReader(json, 'transaction ref');
    return TxRef(kind: TxKind.parse(r['kind']), id: r.optString('id'));
  }

  final TxKind kind;
  final String? id;

  /// Where tapping the transaction goes, or null when its source has no screen.
  String? get location => switch ((kind, id)) {
    (TxKind.match, final id?) => Routes.battleReview(id),
    (TxKind.tournament, final id?) => Uri(
      path: Routes.arena,
      queryParameters: {'t': id},
    ).toString(),
    (TxKind.mission || TxKind.streak, _) => Routes.home,
    (TxKind.level || TxKind.achievement, _) => Routes.profile,
    _ => null,
  };
}

/// One line of the coins history (`GET /v1/me/wallet/transactions`).
@immutable
class WalletTx {
  const WalletTx({
    required this.id,
    required this.delta,
    required this.title,
    required this.createdAt,
    this.balanceAfter,
    this.reason,
    this.ref,
  });

  factory WalletTx.fromJson(Object? json) {
    final r = JsonReader(json, 'transaction');
    return WalletTx(
      id: r.string('id'),
      delta: r.integer('delta'),
      balanceAfter: r.optInt('balance_after'),
      reason: r.optString('reason'),
      title: r.string('title'),
      ref: switch (r['ref']) {
        null => null,
        final ref => TxRef.fromJson(ref),
      },
      createdAt: r.dateTime('created_at'),
    );
  }

  final String id;

  /// Coins in (positive) or out (negative).
  final int delta;
  final int? balanceAfter;

  /// Machine-readable reason, e.g. `casual_entry`.
  final String? reason;

  /// What people read: "Casual battle won", "Refund: match cancelled".
  final String title;
  final TxRef? ref;
  final DateTime createdAt;
}

/// `GET /v1/me/wallet`: the balance, coins held for games in progress, and the latest lines.
@immutable
class WalletSummary {
  const WalletSummary({required this.balance, this.held = 0, this.recent = const []});

  factory WalletSummary.fromJson(Object? json) {
    final r = JsonReader(json, 'wallet');
    return WalletSummary(
      balance: r.integer('balance'),
      held: r.optInt('held') ?? 0,
      recent: r.optList('recent', WalletTx.fromJson),
    );
  }

  final int balance;

  /// Entry fees held until a game or tournament settles.
  final int held;
  final List<WalletTx> recent;
}
