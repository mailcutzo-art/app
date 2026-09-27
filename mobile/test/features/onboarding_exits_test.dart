import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/core/auth/session.dart';

import '../support/fakes.dart';

void main() {
  Future<void> pumpOnboarding(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(session: SignedIn(fakeUser(onboarded: false))),
        child: const QuizApp(),
      ),
    );
    await tester.pumpAndSettle();
    // The suggested username is checked after a short pause.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  testWidgets('only the first name is pre-filled, and a wrong account can be switched', (
    tester,
  ) async {
    await pumpOnboarding(tester);
    expect(find.text('Aarav'), findsOneWidget);
    expect(find.text('Signed in as your Google account'), findsOneWidget);

    await tester.tap(find.text('Switch account'));
    await tester.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('a birth year under 10 offers sign out instead of a stuck form', (tester) async {
    await pumpOnboarding(tester);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue')); // avatar
    await tester.pumpAndSettle();
    await tester.tap(find.text('NEET'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText).last, '${DateTime.now().year - 6}');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(find.text('Quiz Arena is for students aged 10 and up'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Finish'), findsNothing);

    await tester.ensureVisible(find.text('I typed the wrong year'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I typed the wrong year'));
    await tester.pumpAndSettle();
    expect(find.text('Finish'), findsOneWidget);
  });
}
