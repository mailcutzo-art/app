import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/google_auth.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/auth/sign_in_screen.dart';
import 'package:quiz_app/features/home/home_screen.dart';
import 'package:quiz_app/features/settings/data/fake_settings_repository.dart';
import 'package:quiz_app/features/settings/data/settings_models.dart';
import 'package:quiz_app/features/settings/data/settings_repository.dart';
import 'package:quiz_app/features/settings/delete_account_screen.dart';
import 'package:quiz_app/features/settings/restore_account_screen.dart';
import 'package:quiz_app/features/settings/settings_providers.dart';

import '../../support/fakes.dart';

Finder _field(String label) =>
    find.descendant(of: find.widgetWithText(AppTextField, label), matching: find.byType(TextField));

void main() {
  late FakeSettingsRepository settings;
  late FakeAccountRepository account;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    settings = FakeSettingsRepository();
    account = FakeAccountRepository(fakeUser());
  });

  Future<ProviderContainer> open(
    WidgetTester tester,
    String location, {
    List<Override> overrides = const [],
    SessionController Function()? session,
  }) async {
    usePhoneViewport(tester, height: 2600);
    return pumpApp(
      tester,
      prefs: await testPrefs(),
      settings: settings,
      account: account,
      location: location,
      overrides: overrides,
      sessionController: session,
    );
  }

  group('Edit profile', () {
    testWidgets('Save stays off until something changes, then sends only that', (tester) async {
      final container = await open(tester, Routes.settingsProfile);
      AppButton save() => tester.widget<AppButton>(find.widgetWithText(AppButton, 'Save'));
      expect(save().onPressed, isNull);

      await tester.enterText(_field('Name'), 'Aarav S');
      await tester.pump();
      expect(save().onPressed, isNotNull);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(account.patches, [
        {'display_name': 'Aarav S'},
      ]);
      expect(container.read(meProvider).displayName, 'Aarav S');
      expect(find.text('Profile saved'), findsOneWidget);
    });

    testWidgets('a new username is checked before it can be saved', (tester) async {
      await open(tester, Routes.settingsProfile);
      await tester.enterText(_field('Username'), 'ab');
      await tester.pump();
      expect(find.text('3–20 letters, numbers or _'), findsOneWidget);

      await tester.enterText(_field('Username'), 'aarav_new');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(account.patches.single, {'handle': 'aarav_new'});
    });

    testWidgets('the 30-day rule shows when the next change is allowed', (tester) async {
      account.failures[FakeSettingsOp.updateProfile] = const ConflictFailure(
        'Not yet',
        code: 'HANDLE_CHANGE_TOO_SOON',
        details: {'next_change_at': '2026-10-20T12:00:00Z'},
      );
      await open(tester, Routes.settingsProfile);
      await tester.enterText(_field('Username'), 'aarav_new');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('You can change your username again on 20 Oct 2026'), findsOneWidget);
    });

    testWidgets('changing the goal explains what switches', (tester) async {
      await open(tester, Routes.settingsProfile);
      await tester.tap(find.text('JEE'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Boards, missions and tips switch to JEE'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(account.patches.single, {'goal': 'jee'});
    });

    testWidgets('a new avatar is picked from the presets', (tester) async {
      await open(tester, Routes.settingsProfile);
      await tester.tap(
        find.byWidgetPredicate((w) => w is Pressable && w.semanticLabel == 'sky color'),
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(account.patches.single, {
        'avatar': {'tone': 'sky', 'symbol': 'rocket'},
      });
    });
  });

  group('Privacy', () {
    testWidgets('choices are saved; under 18s can\'t take requests from everyone', (tester) async {
      settings.privacySettings = const PrivacySettings(
        friendRequests: FriendRequestsFrom.playedWith,
      );
      await open(tester, Routes.settingsPrivacy);
      expect(find.text('Not available under 18'), findsOneWidget);
      final everyone = tester.widget<SelectableRow>(
        find.widgetWithText(SelectableRow, 'Everyone').first,
      );
      expect(everyone.enabled, isFalse);

      await tester.tap(find.widgetWithText(SelectableRow, 'Nobody').at(1));
      await tester.pumpAndSettle();
      expect(settings.privacySettings.challenges, ChallengesFrom.nobody);

      await tester.tap(find.text('Show me on public boards'));
      await tester.pumpAndSettle();
      expect(settings.saved.last['public_boards'], isFalse);
    });

    testWidgets('a failed load offers Retry', (tester) async {
      settings.failures[FakeSettingsOp.privacy] = const NetworkFailure();
      await open(tester, Routes.settingsPrivacy);
      expect(find.text('Couldn\'t load your privacy settings'), findsOneWidget);
      settings.failures.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Who can challenge me'), findsOneWidget);
    });
  });

  group('Notifications', () {
    testWidgets('each kind switches on its own; quiet hours show and save', (tester) async {
      await open(tester, Routes.settingsNotifications);
      expect(find.text('22:30'), findsOneWidget);
      expect(find.text('07:00'), findsOneWidget);

      await tester.tap(find.text('Tournaments'));
      await tester.pumpAndSettle();
      expect(settings.notificationSettings.isOn(NotificationKind.tournaments), isFalse);
      expect(settings.notificationSettings.isOn(NotificationKind.invites), isTrue);

      await tester.tap(find.text('Starts'));
      await tester.pumpAndSettle();
      expect(find.text('Quiet hours start'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(settings.saved.last['quiet_hours'], {'start': '22:30', 'end': '07:00'});
    });

    testWidgets('a refused change flips back and says why', (tester) async {
      settings.failures[FakeSettingsOp.saveNotifications] = const NetworkFailure();
      await open(tester, Routes.settingsNotifications);
      await tester.tap(find.text('Missions'));
      await tester.pumpAndSettle();
      final row = tester.widget<ToggleRow>(find.widgetWithText(ToggleRow, 'Missions'));
      expect(row.value, isTrue);
      expect(find.text(const NetworkFailure().message), findsOneWidget);
    });
  });

  group('Devices', () {
    testWidgets('lists devices and signs one out after confirming', (tester) async {
      await open(tester, Routes.settingsDevices);
      expect(find.text('Android · This phone'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out this device?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Sign out').last);
      await tester.pumpAndSettle();

      expect(settings.ended, ['s-tablet']);
      expect(find.text('Android'), findsNothing);
      expect(find.text('Sign out all other devices'), findsNothing);
    });

    testWidgets('signs out every other device at once', (tester) async {
      await open(tester, Routes.settingsDevices);
      await tester.tap(find.text('Sign out all other devices'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out others'));
      await tester.pumpAndSettle();
      expect(settings.endOthersCalls, 1);
      expect(find.text('Other devices signed out'), findsOneWidget);
    });
  });

  group('Feedback', () {
    testWidgets('sends the message with the last error\'s reference', (tester) async {
      await open(
        tester,
        Routes.settingsFeedback,
        overrides: [lastErrorRequestIdProvider.overrideWithValue(() => 'req-77')],
      );
      AppButton send() => tester.widget<AppButton>(find.widgetWithText(AppButton, 'Send'));
      expect(find.text('Reference req-77'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Too short');
      await tester.pump();
      expect(send().onPressed, isNull);

      await tester.tap(find.text('Coins or rewards'));
      await tester.enterText(find.byType(TextField), 'My prize never arrived after the cup.');
      await tester.pump();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      final sent = account.feedback.single;
      expect(sent['kind'], 'coins');
      expect(sent['message'], 'My prize never arrived after the cup.');
      expect(sent['request_id'], 'req-77');
      expect(sent['idempotency_key'], isNotEmpty);
      expect(find.text('Thanks! We got your message.'), findsOneWidget);
    });

    testWidgets('the reference can be left out, and is absent without an error', (tester) async {
      await open(
        tester,
        Routes.settingsFeedback,
        overrides: [lastErrorRequestIdProvider.overrideWithValue(() => 'req-77')],
      );
      await tester.tap(find.text('Attach the last error\'s reference'));
      await tester.enterText(find.byType(TextField), 'An idea for group battles and more.');
      await tester.pump();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(account.feedback.single['request_id'], isNull);
    });
  });

  group('Delete account', () {
    testWidgets('needs DELETE typed, signs in again, deletes and signs out', (tester) async {
      await open(
        tester,
        Routes.settingsDelete,
        overrides: [reauthenticateProvider.overrideWithValue(() async => const SignInProof.dev())],
        session: () => ExpiringSessionController(SignedIn(fakeUser())),
      );
      AppButton delete() =>
          tester.widget<AppButton>(find.widgetWithText(AppButton, 'Delete my account'));
      expect(delete().onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'delete');
      await tester.pump();
      expect(delete().onPressed, isNull, reason: 'it must be typed exactly');

      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();

      expect(account.deletions.single.toJson(), {'provider': 'dev'});
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.text(deletedMessage), findsOneWidget);
    });

    testWidgets('closing the account picker deletes nothing', (tester) async {
      await open(
        tester,
        Routes.settingsDelete,
        overrides: [
          reauthenticateProvider.overrideWithValue(() async => throw const SignInCancelled()),
        ],
      );
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();
      expect(account.deletions, isEmpty);
      expect(find.byType(DeleteAccountScreen), findsOneWidget);
    });

    testWidgets('a refused delete keeps the account and says why', (tester) async {
      account.failures[FakeSettingsOp.delete] = const ForbiddenFailure(
        'Please sign in again.',
        code: 'REAUTH_REQUIRED',
      );
      await open(
        tester,
        Routes.settingsDelete,
        overrides: [reauthenticateProvider.overrideWithValue(() async => const SignInProof.dev())],
      );
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();
      expect(find.text('Please sign in again.'), findsOneWidget);
      expect(find.byType(DeleteAccountScreen), findsOneWidget);
    });
  });

  group('Restore', () {
    final pending = Me.fromJson({
      ...fakeUser().toJson(),
      'status': 'pending_deletion',
      'restore_until': '2026-10-05T10:00:00Z',
    });

    testWidgets('a deleted account can only restore or sign out', (tester) async {
      account.restored = fakeUser();
      final container = await open(
        tester,
        Routes.home,
        session: () => FakeSessionController(PendingDeletion(pending)),
      );
      expect(find.byType(RestoreAccountScreen), findsOneWidget);
      expect(find.text('Welcome back, Aarav'), findsOneWidget);
      expect(find.textContaining('until 5 Oct 2026'), findsOneWidget);

      await tester.tap(find.text('Restore my account'));
      await tester.pumpAndSettle();
      expect(account.restoreCalls, 1);
      expect(container.read(sessionProvider).value, isA<SignedIn>());
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a failed restore stays put and says why; Sign out leaves', (tester) async {
      account.failures[FakeSettingsOp.restore] = const ConflictFailure(
        'The time to restore this account has passed.',
        code: 'RESTORE_EXPIRED',
      );
      await open(
        tester,
        Routes.home,
        session: () => FakeSessionController(PendingDeletion(pending)),
      );
      await tester.tap(find.text('Restore my account'));
      await tester.pumpAndSettle();
      expect(find.text('The time to restore this account has passed.'), findsOneWidget);
      expect(find.byType(RestoreAccountScreen), findsOneWidget);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
    });
  });
}
