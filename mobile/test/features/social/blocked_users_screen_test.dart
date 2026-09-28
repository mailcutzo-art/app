import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/social/blocked_users_screen.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';

import '../../support/fakes.dart';

void main() {
  late FakeSocialRepository social;

  setUp(() {
    social = FakeSocialRepository.seeded();
    // A second blocked player, to see the list.
    return social.block('u-dev');
  });

  Future<void> open(WidgetTester tester) async {
    usePhoneViewport(tester);
    await pumpApp(tester, prefs: await testPrefs(), social: social, location: Routes.blockedUsers);
  }

  testWidgets('lists blocked players; Unblock takes them off right away', (tester) async {
    await open(tester);
    expect(find.text('Blocked players'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Dev'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Unblock').first);
    await tester.pumpAndSettle();
    expect(find.text('Sam is unblocked'), findsOneWidget);
    expect(find.text('Sam'), findsNothing);
    expect(social.blockedIds, {'u-dev'});
  });

  testWidgets('a failed unblock puts the player back', (tester) async {
    await open(tester);
    social.failures[FakeSocialOp.unblock] = const ServerFailure();
    await tester.tap(find.widgetWithText(AppButton, 'Unblock').first);
    await tester.pumpAndSettle();
    expect(find.text(const ServerFailure().message), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
  });

  testWidgets('empty and error states', (tester) async {
    social = FakeSocialRepository()..failures[FakeSocialOp.blocks] = const NetworkFailure();
    await open(tester);
    expect(find.text('Couldn\'t load blocked players'), findsOneWidget);

    social.failures.clear();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Nobody is blocked'), findsOneWidget);
    await tester.tap(find.text('Go to Social'));
    await tester.pumpAndSettle();
    expect(currentPath(GoRouter.of(tester.element(find.byType(Scaffold).first))), Routes.social);
  });

  testWidgets('the Settings entry shows the count and opens the list', (tester) async {
    usePhoneViewport(tester);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: BlockedUsersEntry()),
        ),
        GoRoute(path: Routes.blockedUsers, builder: (_, _) => const BlockedUsersScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          session: SignedIn(fakeUser()),
          prefs: await testPrefs(),
          social: social,
        ),
        child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 players'), findsOneWidget);

    await tester.tap(find.text('Blocked players'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppButton, 'Unblock'), findsNWidgets(2));
  });
}
