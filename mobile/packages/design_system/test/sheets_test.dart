import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sheets open on the root navigator, above nested navigators', (tester) async {
    final inner = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          // Stands in for a tab's navigator under a floating nav bar.
          body: Navigator(
            key: inner,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showAppSheet<void>(
                    context,
                    builder: (_) => const SheetScaffold(title: 'Sheet', child: SizedBox()),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Sheet'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(inner), matching: find.byType(BottomSheet)),
      findsNothing,
    );
  });
}
