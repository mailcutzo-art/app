import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/realtime/live_controller.dart';
import 'package:quiz_app/core/realtime/live_providers.dart';
import 'package:quiz_app/features/inbox/data/fake_inbox_repository.dart';
import 'package:quiz_app/features/inbox/data/inbox_models.dart';
import 'package:quiz_app/features/inbox/inbox_bell.dart';
import 'package:quiz_app/features/inbox/inbox_providers.dart';
import 'package:quiz_app/features/inbox/inbox_screen.dart';
import 'package:quiz_app/features/wallet/wallet_screen.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../support/fakes.dart';

InboxItem _item(int i, {bool read = false, AppAction? action}) => InboxItem(
  id: 'n$i',
  kind: 'refund',
  title: 'Notice $i',
  body: 'Body $i',
  action: action,
  createdAt: DateTime.now().subtract(Duration(minutes: i)),
  read: read,
);

NotifyEvent _notify(String id, {int? unread}) => ServerEvent.fromEnvelope(
  Envelope(
    type: 'notify',
    channel: 'u',
    data: {'id': id, 'kind': 'prize', 'title': 'Prize for $id', 'unread': ?unread},
  ),
) as NotifyEvent;

AppIconButton bell(WidgetTester tester) => tester.widget<AppIconButton>(
  find.descendant(of: find.byType(InboxBell), matching: find.byType(AppIconButton)),
);

void main() {
  late FakeInboxRepository inbox;

  setUp(() => inbox = FakeInboxRepository.seeded());

  Finder unreadDots() => find.byKey(const ValueKey('unread-dot'));

  group('the inbox screen', () {
    testWidgets('shows skeletons, then items with the unread ones marked', (tester) async {
      usePhoneViewport(tester);
      inbox.latency = const Duration(milliseconds: 300);
      await pumpApp(
        tester,
        prefs: await testPrefs(),
        inbox: inbox,
        location: Routes.inbox,
        settle: false,
      );
      expect(find.byType(Shimmer), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byType(Shimmer), findsNothing);
      expect(find.text('Riya challenged you to a Physics duel'), findsOneWidget);
      expect(find.text('Refund: match cancelled'), findsOneWidget);
      expect(find.byType(InboxRow), findsNWidgets(4));
      expect(unreadDots(), findsNWidgets(2));
      expect(find.text('Mark all read'), findsOneWidget);
    });

    testWidgets('empty inbox explains what lands here', (tester) async {
      usePhoneViewport(tester);
      await pumpApp(
        tester,
        prefs: await testPrefs(),
        inbox: FakeInboxRepository(),
        location: Routes.inbox,
      );
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('Mark all read'), findsNothing);
    });

    testWidgets('a failed load offers Retry', (tester) async {
      usePhoneViewport(tester);
      inbox.failures[FakeInboxOp.list] = const NetworkFailure();
      await pumpApp(tester, prefs: await testPrefs(), inbox: inbox, location: Routes.inbox);
      expect(find.text('Couldn\'t load your inbox'), findsOneWidget);

      inbox.failures.clear();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byType(InboxRow), findsNWidgets(4));
    });

    testWidgets('tapping an item marks it read and opens its destination', (tester) async {
      usePhoneViewport(tester);
      final container = await pumpApp(tester, prefs: await testPrefs(), inbox: inbox);
      unawaited(container.read(routerProvider).push(Routes.inbox));
      await tester.pumpAndSettle();
      expect(container.read(unreadCountProvider), 2);

      await tester.tap(find.text('Refund: match cancelled'));
      await tester.pumpAndSettle();

      expect(inbox.readCalls, [
        ['n-refund'],
      ]);
      expect(find.byType(WalletScreen), findsOneWidget, reason: 'its action is /wallet');
      expect(container.read(unreadCountProvider), 1);

      // Back in the inbox, the item reads as read.
      container.read(routerProvider).pop();
      await tester.pumpAndSettle();
      expect(unreadDots(), findsOneWidget);
    });

    testWidgets('an item pointing at a tab switches to it with the params', (tester) async {
      usePhoneViewport(tester);
      final container = await pumpApp(
        tester,
        prefs: await testPrefs(),
        inbox: inbox,
        location: Routes.inbox,
      );
      await tester.tap(find.text('Riya challenged you to a Physics duel'));
      await tester.pumpAndSettle();
      expect(container.read(routerProvider).state.uri.toString(), '/battle?subject=physics');
    });

    testWidgets('Mark all read clears every dot and the badge', (tester) async {
      usePhoneViewport(tester);
      final container = await pumpApp(
        tester,
        prefs: await testPrefs(),
        inbox: inbox,
        location: Routes.inbox,
      );
      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();
      expect(inbox.markAllCalls, 1);
      expect(unreadDots(), findsNothing);
      expect(find.text('Mark all read'), findsNothing);
      expect(container.read(unreadCountProvider), 0);
    });

    testWidgets('Mark all read that fails puts the dots back and says so', (tester) async {
      usePhoneViewport(tester);
      await pumpApp(tester, prefs: await testPrefs(), inbox: inbox, location: Routes.inbox);
      inbox.failures[FakeInboxOp.markRead] = const NetworkFailure();
      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();
      expect(unreadDots(), findsNWidgets(2));
      expect(find.text(const NetworkFailure().message), findsOneWidget);
    });

    testWidgets('scrolling to the end loads the next page', (tester) async {
      usePhoneViewport(tester, height: 800);
      inbox = FakeInboxRepository(items: [for (var i = 0; i < 12; i++) _item(i)], pageSize: 5);
      await pumpApp(tester, prefs: await testPrefs(), inbox: inbox, location: Routes.inbox);
      expect(inbox.listCalls, [null]);

      await tester.scrollUntilVisible(find.text('Notice 11'), 400);
      await tester.pumpAndSettle();
      expect(inbox.listCalls, [null, '5', '10']);
      expect(find.text('Notice 11'), findsOneWidget);
    });

    testWidgets('a notify while the inbox is open puts the item on top', (tester) async {
      usePhoneViewport(tester);
      final container = await pumpApp(
        tester,
        prefs: await testPrefs(),
        inbox: inbox,
        location: Routes.inbox,
      );
      for (final hook in container.read(liveEventHooksProvider)) {
        hook.onEvent(_notify('n-live', unread: 3));
      }
      await tester.pumpAndSettle();
      expect(find.text('Prize for n-live'), findsOneWidget);
      expect(container.read(unreadCountProvider), 3);
    });
  });

  group('the bell', () {
    testWidgets('shows the unread count and opens the inbox', (tester) async {
      usePhoneViewport(tester);
      await pumpApp(tester, prefs: await testPrefs(), inbox: inbox);
      expect(bell(tester).badgeCount, 2);

      await tester.tap(find.byType(InboxBell));
      await tester.pumpAndSettle();
      expect(find.byType(InboxScreen), findsOneWidget);
    });

    testWidgets('a live notify raises the badge at once and rings the bell', (tester) async {
      usePhoneViewport(tester);
      final container = await pumpApp(tester, prefs: await testPrefs(), inbox: inbox);
      final rings = bell(tester).motionTrigger;

      final hooks = container.read(liveEventHooksProvider);
      expect(hooks.whereType<InboxLiveHook>(), hasLength(1));
      for (final hook in hooks) {
        hook.onEvent(_notify('n-a', unread: 5));
      }
      await tester.pump();
      expect(bell(tester).badgeCount, 5);
      expect(bell(tester).motionTrigger, isNot(rings));

      // Without a count in the event, it's one more.
      for (final hook in hooks) {
        hook.onEvent(_notify('n-b'));
      }
      await tester.pump();
      expect(bell(tester).badgeCount, 6);
      await tester.pumpAndSettle();
    });

    testWidgets('polls every 20 s in the foreground and again on resume', (tester) async {
      usePhoneViewport(tester);
      final container = await pumpApp(tester, prefs: await testPrefs(), inbox: inbox);
      final atStart = inbox.unreadCalls;
      expect(atStart, greaterThanOrEqualTo(1));

      inbox.add(_item(99));
      await tester.pump(UnreadCount.pollEvery);
      await tester.pump();
      expect(inbox.unreadCalls, atStart + 1);
      expect(bell(tester).badgeCount, 3);

      // In the background nothing is asked.
      container.read(appForegroundProvider.notifier).set(false);
      await tester.pump(UnreadCount.pollEvery * 3);
      expect(inbox.unreadCalls, atStart + 1);

      container.read(appForegroundProvider.notifier).set(true);
      await tester.pump();
      await tester.pump();
      // The resume asks at once (the reconnect's welcome may ask again).
      expect(inbox.unreadCalls, greaterThanOrEqualTo(atStart + 2));
    });

    testWidgets('a failed poll keeps the last count', (tester) async {
      usePhoneViewport(tester);
      await pumpApp(tester, prefs: await testPrefs(), inbox: inbox);
      inbox.failures[FakeInboxOp.unreadCount] = const NetworkFailure();
      await tester.pump(UnreadCount.pollEvery);
      await tester.pump();
      expect(bell(tester).badgeCount, 2);
    });
  });

  testWidgets('every (re)connect asks for the count again', (tester) async {
    usePhoneViewport(tester);
    final container = await pumpApp(tester, prefs: await testPrefs(), inbox: inbox);
    final before = inbox.unreadCalls;
    inbox.add(_item(42));

    final welcome = ServerEvent.fromEnvelope(
      const Envelope(type: 'welcome', data: {'user_id': 'u1', 'server_ms': 0}),
    ) as WelcomeEvent;
    for (final hook in container.read(liveEventHooksProvider)) {
      hook.onWelcome(welcome);
    }
    await tester.pump();
    await tester.pump();
    expect(inbox.unreadCalls, before + 1);
    expect(bell(tester).badgeCount, 3);
  });
}
