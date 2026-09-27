import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/core/auth/session.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('a signed-out user lands on the sign-in screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(session: const SignedOut()),
        child: const QuizApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('a signed-in user who finished onboarding lands on Home', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(session: SignedIn(fakeUser())),
        child: const QuizApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hi, Aarav!'), findsOneWidget);
  });

  testWidgets('a new user is sent to onboarding', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(session: SignedIn(fakeUser(onboarded: false))),
        child: const QuizApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('What should\nwe call you?'), findsOneWidget);
  });
}
