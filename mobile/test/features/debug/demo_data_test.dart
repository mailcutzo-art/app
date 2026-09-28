import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/features/debug/debug_screen.dart';
import 'package:quiz_app/features/inbox/data/fake_inbox_repository.dart';
import 'package:quiz_app/features/inbox/data/inbox_repository.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';
import 'package:quiz_app/features/profile/data/fake_profile_repository.dart';
import 'package:quiz_app/features/profile/data/profile_repository.dart';
import 'package:quiz_app/features/settings/data/fake_settings_repository.dart';
import 'package:quiz_app/features/settings/data/settings_repository.dart';
import 'package:quiz_app/features/wallet/data/wallet_repository.dart';

import '../../support/fakes.dart';

void main() {
  test('the saved switch serves Learn from the sample data', () async {
    final container = ProviderContainer(
      overrides: [
        appEnvProvider.overrideWithValue(testEnv),
        sharedPrefsProvider.overrideWithValue(await testPrefs({DemoDataSetting.prefKey: true})),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(learnRepositoryProvider), isA<FakeLearnRepository>());
  });

  test('the inbox, wallet, profile and settings use their sample data too', () async {
    final container = ProviderContainer(
      overrides: [
        appEnvProvider.overrideWithValue(testEnv),
        sharedPrefsProvider.overrideWithValue(await testPrefs({DemoDataSetting.prefKey: true})),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(inboxRepositoryProvider), isA<FakeInboxRepository>());
    expect(container.read(walletRepositoryProvider), isA<FakeWalletRepository>());
    expect(container.read(profileRepositoryProvider), isA<FakeProfileRepository>());
    expect(container.read(settingsRepositoryProvider), isA<FakeSettingsRepository>());
  });

  test('prod builds ignore it', () async {
    final container = ProviderContainer(
      overrides: [
        appEnvProvider.overrideWithValue(
          const AppEnv(
            flavor: Flavor.prod,
            apiBaseUrl: 'https://api.test',
            googleServerClientId: '',
          ),
        ),
        sharedPrefsProvider.overrideWithValue(await testPrefs({DemoDataSetting.prefKey: true})),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(demoDataProvider), isFalse);
    expect(container.read(learnRepositoryProvider), isA<ApiLearnRepository>());
  });

  testWidgets('the debug screen switches demo data on and off', (tester) async {
    final prefs = await testPrefs();
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appEnvProvider.overrideWithValue(testEnv),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(theme: AppTheme.light(), home: const DebugScreen());
          },
        ),
      ),
    );

    expect(container.read(learnRepositoryProvider), isA<ApiLearnRepository>());
    await tester.tap(find.text('Demo data'));
    await tester.pumpAndSettle();

    expect(prefs.getBool(DemoDataSetting.prefKey), isTrue);
    expect(container.read(learnRepositoryProvider), isA<FakeLearnRepository>());
    expect(find.text('Learn now uses sample questions.'), findsOneWidget);
  });
}
