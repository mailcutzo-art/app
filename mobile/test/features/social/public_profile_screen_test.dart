import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';
import 'package:quiz_app/features/social/data/social_models.dart';

import '../../support/fakes.dart';

void main() {
  late FakeSocialRepository social;

  setUp(() => social = FakeSocialRepository.seeded());

  Future<void> open(WidgetTester tester, String handle, {bool settle = true}) async {
    usePhoneViewport(tester, height: 1400);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      social: social,
      location: Routes.userProfile(handle),
      settle: settle,
    );
  }

  String path(WidgetTester tester) =>
      currentPath(GoRouter.of(tester.element(find.byType(Scaffold).first)));

  testWidgets('a friend\'s profile: card, record, form, ratings and Challenge', (tester) async {
    social.latency = const Duration(milliseconds: 300);
    await open(tester, 'rahul_07', settle: false);
    expect(find.byType(Shimmer), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('@rahul_07'), findsWidgets);
    expect(find.text('LEVEL 7'), findsOneWidget);
    expect(find.text('FRIENDS'), findsOneWidget);
    expect(find.text('Your record'), findsOneWidget);
    expect(find.text('You lead 3–1'), findsOneWidget);
    expect(find.text('Recent form'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Recent form: Win, Loss')), findsOneWidget);
    expect(find.text('Physics'), findsOneWidget);
    expect(find.text('1523'), findsOneWidget);
    expect(find.text('Rank #1477'), findsOneWidget);
    expect(find.text('Remove friend'), findsOneWidget);

    await tester.tap(find.text('Challenge'));
    await tester.pumpAndSettle();
    expect(path(tester), '${Routes.battle}/room/new');
    // The set-up reads the friends list, which is slow here.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  });

  testWidgets('a minor who isn\'t a friend shows only name, avatar and level', (tester) async {
    await open(tester, 'riya_s');
    expect(find.text('Riya'), findsOneWidget);
    expect(find.text('LEVEL 3'), findsOneWidget);
    expect(find.text('Some details are private'), findsOneWidget);
    expect(find.text('Your record'), findsNothing);
    expect(find.text('Ratings'), findsNothing);
    expect(find.text('Recent form'), findsNothing);
    expect(find.text('Challenge'), findsNothing);

    await tester.tap(find.text('Add friend'));
    await tester.pumpAndSettle();
    expect(find.text('Riya only accepts requests from people they\'ve played.'), findsOneWidget);
    expect(find.text('Add friend'), findsOneWidget);
  });

  testWidgets('Add friend, then Cancel request', (tester) async {
    await open(tester, 'arjun_22');
    await tester.tap(find.text('Add friend'));
    await tester.pumpAndSettle();
    expect(find.text('Friend request sent to Arjun'), findsOneWidget);
    expect(find.text('Cancel request'), findsOneWidget);

    await tester.tap(find.text('Cancel request'));
    await tester.pumpAndSettle();
    expect(find.text('Request to Arjun cancelled'), findsOneWidget);
    expect(find.text('Add friend'), findsOneWidget);
    expect(social.outgoingRequests.values, isNot(contains('u-arjun')));
  });

  testWidgets('someone who asked first can be accepted from their profile', (tester) async {
    await open(tester, 'zoya_z');
    expect(find.text('Accept request'), findsOneWidget);
    await tester.tap(find.text('Accept request'));
    await tester.pumpAndSettle();
    expect(find.text('You and Zoya are now friends'), findsOneWidget);
    expect(find.text('Remove friend'), findsOneWidget);
  });

  testWidgets('removing a friend asks first', (tester) async {
    await open(tester, 'rahul_07');
    await tester.tap(find.text('Remove friend'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(social.friendIds, contains('u-rahul'));

    await tester.tap(find.text('Remove friend'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(AppButton, 'Remove friend'),
      ),
    );
    await tester.pumpAndSettle();
    expect(social.friendIds, isNot(contains('u-rahul')));
    expect(find.text('Add friend'), findsOneWidget);
  });

  testWidgets('block from the menu, then unblock', (tester) async {
    await open(tester, 'kabir_k');
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    expect(find.text('Block Kabir?'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Block'));
    await tester.pumpAndSettle();

    expect(find.text('Kabir is blocked'), findsOneWidget);
    expect(find.text('You blocked Kabir'), findsOneWidget);
    expect(find.text('Your record'), findsNothing);
    expect(social.blockedIds, contains('u-kabir'));

    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(find.text('Kabir is unblocked'), findsOneWidget);
    expect(find.text('Add friend'), findsOneWidget);
    expect(social.blockedIds, isNot(contains('u-kabir')));
  });

  testWidgets('a failed block is rolled back', (tester) async {
    await open(tester, 'kabir_k');
    social.failures[FakeSocialOp.block] = const NetworkFailure();
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Block'));
    await tester.pumpAndSettle();

    expect(find.text(const NetworkFailure().message), findsOneWidget);
    expect(find.text('You blocked Kabir'), findsNothing);
    expect(find.text('Remove friend'), findsOneWidget);
  });

  testWidgets('report with a reason, and block too', (tester) async {
    await open(tester, 'arjun_22');
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();

    final send = find.widgetWithText(AppButton, 'Send report');
    expect(tester.widget<AppButton>(send).onPressed, isNull, reason: 'a reason is needed');
    await tester.tap(find.text('Offensive name'));
    await tester.tap(find.text('Also block Arjun'));
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(find.text('Thanks. Our team will review your report.'), findsOneWidget);
    expect(social.reports.single.reason, ReportReason.offensiveName);
    expect(social.blockedIds, contains('u-arjun'));
    expect(find.text('You blocked Arjun'), findsOneWidget);
  });

  testWidgets('a failed report keeps the sheet open', (tester) async {
    await open(tester, 'arjun_22');
    social.failures[FakeSocialOp.report] = const ServerFailure();
    await tester.tap(find.bySemanticsLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cheating'));
    await tester.pump();
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();

    expect(find.text(const ServerFailure().message), findsOneWidget);
    expect(find.text('Report Arjun'), findsOneWidget);
  });

  testWidgets('an unknown or blocked player is a friendly dead end', (tester) async {
    await open(tester, 'sam_x');
    expect(find.text('Player not found'), findsOneWidget);
    await tester.tap(find.text('Back to Social'));
    await tester.pumpAndSettle();
    expect(path(tester), Routes.social);
  });

  testWidgets('other errors offer a retry', (tester) async {
    social.failures[FakeSocialOp.profile] = const NetworkFailure();
    await open(tester, 'rahul_07');
    expect(find.text('Couldn\'t load this profile'), findsOneWidget);
    social.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Your record'), findsOneWidget);
  });
}
