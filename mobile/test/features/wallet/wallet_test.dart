import 'package:design_system/design_system.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/match/review_screen.dart';
import 'package:quiz_app/features/wallet/data/wallet_models.dart';
import 'package:quiz_app/features/wallet/data/wallet_repository.dart';
import 'package:quiz_app/features/wallet/wallet_screen.dart';

import '../../support/fakes.dart';

Map<String, Object?> _tx({String id = 't1', Object? ref}) => {
  'id': id,
  'delta': -5,
  'balance_after': 240,
  'reason': 'casual_entry',
  'title': 'Casual battle entry',
  'ref': ref,
  'created_at': '2026-09-27T16:00:00Z',
};

void main() {
  group('models', () {
    test('a transaction reads every field', () {
      final tx = WalletTx.fromJson(_tx(ref: {'kind': 'match', 'id': 'm1'}));
      expect(tx.delta, -5);
      expect(tx.balanceAfter, 240);
      expect(tx.title, 'Casual battle entry');
      expect(tx.ref!.kind, TxKind.match);
      expect(tx.createdAt, DateTime.utc(2026, 9, 27, 16));
    });

    test('each source links where a screen exists', () {
      String? link(String kind, [String? id]) => TxRef.fromJson({'kind': kind, 'id': id}).location;
      expect(link('match', 'm1'), Routes.battleReview('m1'));
      expect(link('tournament', 'T 1'), '/arena?t=T+1');
      expect(link('mission'), Routes.home);
      expect(link('streak'), Routes.home);
      expect(link('level'), Routes.profile);
      expect(link('achievement'), Routes.profile);
      expect(link('welcome'), isNull);
      expect(link('hint'), isNull);
      expect(link('something_new', 'x'), isNull);
      expect(link('match'), isNull, reason: 'no id, nothing to open');
    });

    test('the summary reads balance, held and the recent lines', () {
      final wallet = WalletSummary.fromJson({
        'balance': 245,
        'held': 5,
        'recent': [_tx()],
      });
      expect(wallet.balance, 245);
      expect(wallet.held, 5);
      expect(wallet.recent.single.id, 't1');
      expect(() => WalletSummary.fromJson(const {'held': 5}), throwsFormatException);
    });
  });

  test('ApiWalletRepository asks for the wallet and pages the history', () async {
    final adapter = FakeAdapter(
      (options) => switch (options.path) {
        '/v1/me/wallet' => jsonBody({'balance': 10, 'held': 0, 'recent': <Object?>[]}),
        _ => jsonBody({
          'items': [_tx()],
          'next_cursor': null,
        }),
      },
    );
    final repo = ApiWalletRepository(
      ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
    );
    expect((await repo.wallet()).balance, 10);
    final page = await repo.transactions(cursor: 'c1');
    expect(page.items.single.title, 'Casual battle entry');
    expect(page.nextCursor, isNull);
    expect(adapter.requests.map((r) => r.path), ['/v1/me/wallet', '/v1/me/wallet/transactions']);
    expect(adapter.requests.last.queryParameters, {'cursor': 'c1'});
  });

  group('the Wallet screen', () {
    testWidgets('shows skeletons, then the balance and the coins history', (tester) async {
      usePhoneViewport(tester);
      final wallet = FakeWalletRepository.seeded(latency: const Duration(milliseconds: 300));
      await pumpApp(
        tester,
        prefs: await testPrefs(),
        wallet: wallet,
        location: Routes.wallet,
        settle: false,
      );
      expect(find.byType(Shimmer), findsNWidgets(2));

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('245'), findsOneWidget);
      expect(find.text('Held for games'), findsOneWidget);
      expect(find.text('240'), findsOneWidget, reason: 'available: balance minus held');
      expect(find.byType(TransactionRow), findsNWidgets(5));
      expect(find.text('Refund: match cancelled'), findsOneWidget);
      expect(find.text('+5'), findsOneWidget);
      expect(find.text('−5'), findsOneWidget);
    });

    testWidgets('the balance and the history fail and retry separately', (tester) async {
      usePhoneViewport(tester);
      final wallet = FakeWalletRepository.seeded()
        ..failures[FakeWalletOp.wallet] = const NetworkFailure();
      await pumpApp(tester, prefs: await testPrefs(), wallet: wallet, location: Routes.wallet);
      expect(find.text('Couldn\'t load your balance'), findsOneWidget);
      expect(find.byType(TransactionRow), findsNWidgets(5));

      wallet.failures.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('245'), findsOneWidget);
    });

    testWidgets('a history that fails offers Retry; an empty one explains itself', (tester) async {
      usePhoneViewport(tester);
      final wallet = FakeWalletRepository(balance: 100)
        ..failures[FakeWalletOp.transactions] = const NetworkFailure();
      await pumpApp(tester, prefs: await testPrefs(), wallet: wallet, location: Routes.wallet);
      expect(find.text('Couldn\'t load your coins history'), findsOneWidget);

      wallet.failures.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('No coins moved yet'), findsOneWidget);
    });

    testWidgets('a line opens its source', (tester) async {
      usePhoneViewport(tester);
      await pumpApp(
        tester,
        prefs: await testPrefs(),
        wallet: FakeWalletRepository.seeded(),
        location: Routes.wallet,
      );
      await tester.tap(find.text('Casual battle entry'));
      await tester.pumpAndSettle();
      expect(find.byType(ReviewScreen), findsOneWidget);
    });

    testWidgets('scrolling loads the next page of the history', (tester) async {
      usePhoneViewport(tester, height: 800);
      final seeded = FakeWalletRepository.seeded();
      final lines = [
        for (var i = 0; i < 4; i++)
          for (final page in [await seeded.transactions()])
            for (final tx in page.items)
              WalletTx(
                id: '${tx.id}-$i',
                delta: tx.delta,
                title: '${tx.title} $i',
                createdAt: tx.createdAt,
              ),
      ];
      final wallet = FakeWalletRepository(balance: 5, transactions: lines, pageSize: 8);
      await pumpApp(tester, prefs: await testPrefs(), wallet: wallet, location: Routes.wallet);
      await tester.scrollUntilVisible(find.text('Welcome bonus 3'), 400);
      await tester.pumpAndSettle();
      expect(wallet.transactionCalls, [null, '8', '16']);
    });
  });

  testWidgets('Home\'s coins stat opens the wallet', (tester) async {
    usePhoneViewport(tester);
    await pumpApp(tester, prefs: await testPrefs(), wallet: FakeWalletRepository.seeded());
    await tester.tap(find.text('Coins'));
    await tester.pumpAndSettle();
    expect(find.byType(WalletScreen), findsOneWidget);
  });
}
