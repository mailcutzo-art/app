import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/profile/data/fake_profile_repository.dart';
import 'package:quiz_app/features/share/share_card.dart';
import 'package:quiz_app/features/share/share_models.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';
import 'package:quiz_app/features/social/data/social_models.dart';
import 'package:quiz_app/features/social/social_screen.dart';

import '../../support/fakes.dart';
import '../../support/share_samples.dart';

void main() {
  late FakeSocialRepository social;

  setUp(() => social = FakeSocialRepository.seeded());

  String location(WidgetTester tester) {
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    return router.routerDelegate.currentConfiguration.uri.toString();
  }

  Future<void> open(WidgetTester tester, {bool settle = true}) async {
    usePhoneViewport(tester, height: 2600);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      social: social,
      location: Routes.social,
      settle: settle,
    );
  }

  testWidgets('shows skeletons, then requests, friends, rivals, opponents and activity', (
    tester,
  ) async {
    social.latency = const Duration(milliseconds: 300);
    await open(tester, settle: false);

    expect(find.text('Social'), findsWidgets);
    expect(find.byType(Shimmer), findsNWidgets(5));

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.byType(Shimmer), findsNothing);
    // Requests: two incoming (with a badge) and one sent.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Zoya'), findsWidgets);
    expect(find.bySemanticsLabel('Accept Zoya'), findsOneWidget);
    expect(find.textContaining('Request sent'), findsOneWidget);
    // Friends with presence, online first.
    expect(find.text('3 online'), findsOneWidget);
    final online = tester.getTopLeft(find.text('Online · Level 7')).dy;
    final tournament = tester.getTopLeft(find.text('In a tournament · Level 11')).dy;
    final battle = tester.getTopLeft(find.text('In a battle · Level 9')).dy;
    final offline = tester.getTopLeft(find.text('Offline · Level 5')).dy;
    expect(online < tournament && tournament < battle && battle < offline, isTrue);
    expect(find.text('Challenge'), findsWidgets);
    // Rivals and opponents with their records.
    expect(find.text('You lead 3–1 · 3W · 1L · 0D'), findsOneWidget);
    expect(find.text('You lead 4–3 · 4W · 3L · 0D'), findsOneWidget);
    expect(find.text('Add friend'), findsWidgets, reason: 'recent opponents');
    // Activity.
    expect(find.textContaining('reached level 9'), findsOneWidget);
    expect(find.textContaining('finished #2 in Physics Sunday Cup'), findsOneWidget);
  });

  testWidgets('accepting a request makes a friend right away', (tester) async {
    await open(tester);
    await tester.tap(find.bySemanticsLabel('Accept Zoya'));
    await tester.pumpAndSettle();

    expect(find.text('You and Zoya are now friends'), findsOneWidget);
    expect(find.bySemanticsLabel('Accept Zoya'), findsNothing);
    expect(find.text('Offline · Level 6'), findsOneWidget, reason: 'Zoya in friends');
    expect(find.text('1'), findsOneWidget, reason: 'one request left');
    expect(social.friendIds, contains('u-zoya'));
  });

  testWidgets('a failed accept puts the request back and says why', (tester) async {
    await open(tester);
    social.failures[FakeSocialOp.accept] = const NetworkFailure();
    await tester.tap(find.bySemanticsLabel('Accept Zoya'));
    await tester.pumpAndSettle();

    expect(find.text(const NetworkFailure().message), findsOneWidget);
    expect(find.bySemanticsLabel('Accept Zoya'), findsOneWidget);
    expect(find.text('Offline · Level 6'), findsNothing);
  });

  testWidgets('declining and cancelling requests', (tester) async {
    await open(tester);
    await tester.tap(find.bySemanticsLabel('Decline Dev'));
    await tester.pumpAndSettle();
    expect(find.text('Request from Dev declined'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Request to Ananya cancelled'), findsOneWidget);
    expect(social.outgoingRequests, isEmpty);
  });

  group('search', () {
    testWidgets('waits for 3 characters, debounces and shows relationships', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'ra');
      await tester.pump();
      expect(find.text('Keep typing'), findsOneWidget);
      expect(find.text('Rivals'), findsNothing, reason: 'results replace the sections');

      await tester.enterText(find.byType(TextField), 'ana');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), '@RAH');
      await tester.pump(const Duration(milliseconds: 100));
      expect(social.searchQueries, isEmpty, reason: 'still typing');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(social.searchQueries, ['rah']);
      expect(find.text('Rahul'), findsOneWidget);
      expect(find.text('Friends'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ana');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Requested'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('No players found'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Rivals'), findsOneWidget);
    });

    testWidgets('Add friend turns into Requested, or explains a refusal', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'riy');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add friend'));
      await tester.pumpAndSettle();
      expect(find.text('Riya only accepts requests from people they\'ve played.'), findsOneWidget);
      expect(find.text('Add friend'), findsOneWidget, reason: 'rolled back');

      await tester.enterText(find.byType(TextField), 'arj');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add friend'));
      await tester.pumpAndSettle();
      expect(find.text('Friend request sent to Arjun'), findsOneWidget);
      expect(find.text('Requested'), findsOneWidget);
    });

    testWidgets('a failed search offers a retry', (tester) async {
      await open(tester);
      social.failures[FakeSocialOp.search] = const ServerFailure();
      await tester.enterText(find.byType(TextField), 'rah');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Search didn\'t work'), findsOneWidget);

      social.failures.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Rahul'), findsOneWidget);
    });
  });

  testWidgets('Challenge opens the Battle tab for that friend', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Challenge').first);
    await tester.pumpAndSettle();
    expect(location(tester), Routes.battleWithFriend('u-rahul'));
  });

  testWidgets('tapping a friend opens their profile', (tester) async {
    await open(tester);
    await tester.tap(find.text('Online · Level 7'));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    expect(currentPath(router), '/u/rahul_07');
    expect(find.text('Your record'), findsOneWidget);
  });

  testWidgets('removing and blocking a friend from the menu', (tester) async {
    await open(tester);
    await tester.tap(find.bySemanticsLabel('More for Kabir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove friend'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Kabir?'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Remove friend'));
    await tester.pumpAndSettle();
    expect(find.text('Kabir was removed from your friends'), findsOneWidget);
    expect(find.text('Offline · Level 5'), findsNothing);
    expect(social.friendIds, isNot(contains('u-kabir')));

    await tester.tap(find.bySemanticsLabel('More for Meera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Block'));
    await tester.pumpAndSettle();
    expect(find.text('Meera is blocked'), findsOneWidget);
    expect(find.text('In a battle · Level 9'), findsNothing);
    expect(find.textContaining('reached level 9'), findsNothing, reason: 'gone from activity');
    expect(social.blockedIds, contains('u-meera'));
  });

  testWidgets('reporting a friend sends the reason and note', (tester) async {
    await open(tester);
    await tester.tap(find.bySemanticsLabel('More for Kabir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    expect(find.text('Report Kabir'), findsOneWidget);

    await tester.tap(find.text('Harassment'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Keeps inviting me');
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();

    expect(find.text('Thanks. Our team will review your report.'), findsOneWidget);
    expect(social.reports.single.userId, 'u-kabir');
    expect(social.reports.single.reason, ReportReason.harassment);
    expect(social.reports.single.note, 'Keeps inviting me');
    expect(social.blockedIds, isNot(contains('u-kabir')));
  });

  testWidgets('empty sections explain themselves and point somewhere', (tester) async {
    social = FakeSocialRepository();
    await open(tester);

    expect(find.text('No friends yet'), findsOneWidget);
    expect(find.text('Add friends by username or share your invite link.'), findsOneWidget);
    expect(find.text('No requests'), findsOneWidget);
    expect(find.text('No rivals yet'), findsOneWidget);
    expect(find.text('Play more battles to find rivals.'), findsOneWidget);
    expect(find.text('No opponents yet'), findsOneWidget);
    expect(find.text('Quiet week'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Find friends').first);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.tap(find.widgetWithText(AppButton, 'Play').first);
    await tester.pumpAndSettle();
    expect(location(tester), Routes.battle);
  });

  testWidgets('a section that fails shows a retry, and the others still load', (tester) async {
    social.failures[FakeSocialOp.friends] = const ServerFailure();
    await open(tester);

    expect(find.text('Couldn\'t load your friends'), findsOneWidget);
    expect(find.text('You lead 3–1 · 3W · 1L · 0D'), findsOneWidget);

    social.failures.clear();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t load your friends'), findsNothing);
    expect(find.text('3 online'), findsOneWidget);
  });

  testWidgets('presence is polled every 30 s while the tab is showing', (tester) async {
    await open(tester);
    expect(social.calls[FakeSocialOp.friends], 1);

    social.setPresence('u-kabir', FriendPresence.online);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(social.calls[FakeSocialOp.friends], 2);
    expect(find.text('Online · Level 5'), findsOneWidget);
    expect(find.text('4 online'), findsOneWidget);

    // On another tab nothing is polled.
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(Routes.home);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 90));
    expect(social.calls[FakeSocialOp.friends], 2);

    // Coming back after a while polls right away.
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(Routes.social);
    await tester.pumpAndSettle();
    expect(social.calls[FakeSocialOp.friends], 3);
  });

  group('posting', () {
    late ShareRecorder recorder;

    setUp(() => recorder = ShareRecorder());

    Future<void> openWithStats(WidgetTester tester) async {
      usePhoneViewport(tester, height: 3200);
      await pumpApp(
        tester,
        prefs: await testPrefs(),
        social: social,
        profile: FakeProfileRepository.seeded(),
        location: Routes.social,
        overrides: recorder.overrides,
      );
    }

    testWidgets('shared wins and progress show as small cards in the feed', (tester) async {
      await open(tester);

      expect(find.byType(ShareCard), findsNWidgets(2));
      expect(find.textContaining('shared a win'), findsOneWidget);
      expect(find.text('Victory! · Biology · Human Physiology'), findsOneWidget);
      expect(find.text('910 – 640 vs Kabir'), findsOneWidget);
      expect(find.textContaining('shared their progress'), findsOneWidget);
      expect(find.text('Level 7'), findsOneWidget);
      expect(find.text('12-day streak'), findsOneWidget);
      final compact = tester.widgetList<ShareCard>(find.byType(ShareCard));
      expect(compact.every((card) => card.compact), isTrue);
    });

    testWidgets('messages and photos are turned off and read as disabled', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);

      expect(find.byType(PostBox), findsOneWidget);
      expect(find.text(PostBox.offMessage), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Message')),
        isSemantics(
          isTextField: true,
          hasEnabledState: true,
          isEnabled: false,
          isReadOnly: true,
          hint: PostBox.offMessage,
        ),
      );
      for (final label in ['Send a message (turned off)', 'Add a photo (turned off)']) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
          reason: label,
        );
        final button = tester.widget<AppIconButton>(
          find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label),
        );
        expect(button.onPressed, isNull);
      }
      await tester.tap(find.text(PostBox.offMessage));
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsOneWidget, reason: 'only the search field');
      expect(find.text('Share a win from any battle result'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('Share progress opens the sheet; a post shows in the user\'s own feed', (
      tester,
    ) async {
      await openWithStats(tester);
      await tester.tap(find.widgetWithText(AppButton, 'Share progress'));
      await tester.pumpAndSettle();
      expect(find.text('Share your progress'), findsOneWidget);

      await tester.tap(find.text('Post to friends'));
      await tester.pumpAndSettle();

      expect(social.posted, [const ProgressShareTarget()]);
      expect(find.text('Posted to your friends'), findsOneWidget);
      expect(find.byType(ShareCard), findsNWidgets(3), reason: 'the feed reloaded');
      expect(find.text('Level 6'), findsOneWidget, reason: 'the user\'s own progress');
    });

    testWidgets('Share progress to other apps uses the profile\'s stats', (tester) async {
      await openWithStats(tester);
      await tester.tap(find.widgetWithText(AppButton, 'Share progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share to other apps'));
      await tester.pumpAndSettle();

      final card = recorder.captured.single as ProgressShareData;
      expect(card.level, 4);
      expect(card.player.displayName, 'Aarav Sharma');
      expect(recorder.shared, hasLength(1));
    });
  });
}
