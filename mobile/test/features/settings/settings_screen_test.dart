import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/debug/debug_screen.dart';
import 'package:quiz_app/features/settings/data/fake_settings_repository.dart';
import 'package:quiz_app/features/settings/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';

void main() {
  late FakeSettingsRepository settings;
  late SharedPreferences prefs;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    settings = FakeSettingsRepository();
    prefs = await testPrefs();
  });

  Future<void> open(WidgetTester tester) async {
    usePhoneViewport(tester, height: 2600);
    await pumpApp(tester, prefs: prefs, settings: settings, location: Routes.settings);
  }

  testWidgets('lists every group, the version and the debug entry in dev', (tester) async {
    await open(tester);
    for (final label in [
      'Edit profile',
      'Privacy',
      'Notifications',
      'Devices',
      'Sounds',
      'Haptics',
      'Usage analytics',
      'Send feedback',
      'Open-source licences',
      'Debug settings',
      'Sign out',
      'Delete account',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Version 1.0.0 (1)'), findsOneWidget);
    expect(find.text('Aarav Sharma · @aarav'), findsOneWidget);

    await tester.tap(find.text('Debug settings'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugScreen), findsOneWidget);
  });

  testWidgets('the theme is saved on this phone and applied at once', (tester) async {
    await open(tester);
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.system);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.dark);
    expect(prefs.getString(SettingsPrefs.theme), 'dark');

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.light);
  });

  testWidgets('a saved theme is used from the start', (tester) async {
    prefs = await testPrefs({SettingsPrefs.theme: 'dark'});
    await open(tester);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
  });

  testWidgets('sound and haptics are saved and reach every button', (tester) async {
    await open(tester);
    TouchFeedback touch() => tester.widget<TouchFeedback>(find.byType(TouchFeedback));
    expect((touch().haptics, touch().sounds), (true, false));

    await tester.tap(find.text('Haptics'));
    await tester.tap(find.text('Sounds'));
    await tester.pumpAndSettle();
    expect((touch().haptics, touch().sounds), (false, true));
    expect(prefs.getBool(SettingsPrefs.haptics), isFalse);
    expect(prefs.getBool(SettingsPrefs.sounds), isTrue);
  });

  testWidgets('the analytics switch is saved on the server', (tester) async {
    await open(tester);
    await tester.tap(find.text('Usage analytics'));
    await tester.pumpAndSettle();
    expect(settings.saved, [
      {'analytics': false},
    ]);
    expect(settings.appSettings.analytics, isFalse);
  });

  testWidgets('a refused analytics change flips back and says why', (tester) async {
    settings.failures[FakeSettingsOp.saveApp] = const NetworkFailure();
    await open(tester);
    await tester.tap(find.text('Usage analytics'));
    await tester.pumpAndSettle();
    final toggle = tester.widget<ToggleRow>(
      find.ancestor(of: find.text('Usage analytics'), matching: find.byType(ToggleRow)),
    );
    expect(toggle.value, isTrue);
    expect(find.text(const NetworkFailure().message), findsOneWidget);
  });

  testWidgets('the analytics setting loads on its own and can be retried', (tester) async {
    settings.failures[FakeSettingsOp.app] = const NetworkFailure();
    await open(tester);
    expect(find.text('Couldn\'t load the analytics setting'), findsOneWidget);
    expect(find.text('Edit profile'), findsOneWidget, reason: 'the rest of Settings is there');

    settings.failures.clear();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Usage analytics'), findsOneWidget);
  });

  testWidgets('licences open the licence page', (tester) async {
    await open(tester);
    await tester.tap(find.text('Open-source licences'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
