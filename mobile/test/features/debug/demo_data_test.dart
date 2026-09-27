import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/features/debug/debug_screen.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';

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
