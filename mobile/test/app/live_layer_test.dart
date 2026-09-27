import 'package:design_system/design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/app/live/live_hub.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';

import '../support/fakes.dart';

void main() {
  late DateTime now;

  setUp(() => now = DateTime.utc(2026, 9, 27, 16));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...testOverrides(session: SignedIn(fakeUser())),
          liveClockProvider.overrideWithValue(() => now),
        ],
        child: const QuizApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(QuizApp)));
  }

  String location(ProviderContainer container) =>
      container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

  /// Advances the fake clock and the frame clock together, one second at a time.
  Future<void> elapse(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a banner shows on any screen and its button opens the destination', (tester) async {
    final container = await pumpApp(tester);
    container
        .read(liveHubProvider.notifier)
        .show(
          const LiveAlert(
            id: 'invite-1',
            title: 'Rahul invited you',
            message: 'Physics · 7 questions',
            primary: LiveAction('Accept', route: '/battle?invite=1'),
            secondary: LiveAction('Decline'),
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('Rahul invited you'), findsOneWidget);
    expect(find.text('Physics · 7 questions'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(location(container), '/battle?invite=1');
    expect(find.text('Rahul invited you'), findsNothing);
    expect(container.read(liveHubProvider).alerts, isEmpty);
  });

  testWidgets('a secondary action runs without navigating; close dismisses', (tester) async {
    final container = await pumpApp(tester);
    var declined = 0;
    container
        .read(liveHubProvider.notifier)
        .show(
          LiveAlert(
            id: 'invite-2',
            title: 'Neha invited you',
            primary: const LiveAction('Accept', route: '/battle'),
            secondary: LiveAction('Decline', run: () async => declined++),
          ),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(declined, 1);
    expect(location(container), Routes.home);
    expect(find.text('Neha invited you'), findsNothing);

    container.read(liveHubProvider.notifier).show(const LiveAlert(id: 'n', title: 'Refunded'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == 'Dismiss'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Refunded'), findsNothing);
  });

  testWidgets('an expiring banner counts down and disappears on time', (tester) async {
    final container = await pumpApp(tester);
    container
        .read(liveHubProvider.notifier)
        .show(
          LiveAlert(
            id: 'x',
            title: 'Aman invited you',
            expiresAt: now.add(const Duration(seconds: 5)),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('Expires in 0:05'), findsOneWidget);

    await elapse(tester, 2);
    expect(find.text('Expires in 0:03'), findsOneWidget);

    await elapse(tester, 3);
    expect(find.text('Aman invited you'), findsNothing);
    expect(container.read(liveHubProvider).alerts, isEmpty);
  });

  testWidgets('a takeover beats banners and opens the game by itself', (tester) async {
    final container = await pumpApp(tester);
    final hub = container.read(liveHubProvider.notifier)
      ..show(const LiveAlert(id: 'b', title: 'A banner'))
      ..show(
        const LiveAlert(
          id: 'match-1',
          title: 'Match found!',
          message: 'You vs Rahul',
          style: AlertStyle.takeover,
          autoRunAfter: Duration(seconds: 3),
          primary: LiveAction('Play now', route: '/battle?match=1'),
        ),
      );
    await tester.pumpAndSettle();
    expect(find.text('Match found!'), findsOneWidget);
    expect(find.text('A banner'), findsNothing);

    await elapse(tester, 3);
    expect(location(container), '/battle?match=1');
    expect(find.text('Match found!'), findsNothing);
    // The banner that waited behind it shows next.
    expect(find.text('A banner'), findsOneWidget);
    hub.dismiss('b');
    await tester.pumpAndSettle();
  });

  testWidgets('the status pill counts up and takes the user back', (tester) async {
    final container = await pumpApp(tester);
    container
        .read(liveHubProvider.notifier)
        .setStatus(LiveStatus(label: 'Searching', since: now, route: '/battle?searching=1'));
    await tester.pumpAndSettle();
    expect(find.text('Searching · 0:00'), findsOneWidget);

    await elapse(tester, 32);
    expect(find.text('Searching · 0:32'), findsOneWidget);

    await tester.tap(find.text('Searching · 0:32'));
    await tester.pumpAndSettle();
    expect(location(container), '/battle?searching=1');

    container.read(liveHubProvider.notifier).setStatus(null);
    await tester.pumpAndSettle();
    expect(find.textContaining('Searching'), findsNothing);
  });

  test('showing an alert with the same id replaces it instead of stacking', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(liveHubProvider.notifier)
      ..show(const LiveAlert(id: 'a', title: 'one'))
      ..show(const LiveAlert(id: 'a', title: 'two'));
    expect(container.read(liveHubProvider).alerts.single.title, 'two');
  });
}
